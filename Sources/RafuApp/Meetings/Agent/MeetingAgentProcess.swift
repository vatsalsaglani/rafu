import AppKit
import Darwin
import Foundation
import RafuCore
import Synchronization

/// How to start one hidden agent process: an executable and an argument
/// array, never a shell string. `environment` replaces the parent
/// environment. `standardInput` nil means `/dev/null`.
nonisolated struct MeetingAgentProcessSpec: Sendable, Equatable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectoryURL: URL
    var standardInput: Data?
}

/// How a hidden agent process ended.
nonisolated enum MeetingAgentTermination: Sendable, Equatable {
    case exited(Int32)
    case signalled(Int32)

    var exitCode: Int32 {
        switch self {
        case .exited(let code): code
        case .signalled(let signal): 128 + signal
        }
    }
}

/// One running hidden agent process.
nonisolated protocol MeetingAgentProcessHandle: AnyObject, Sendable {
    /// Bytes from standard output; the stream ends when the process closes it.
    var output: AsyncStream<Data> { get }
    /// SIGTERM now, SIGKILL after 2 s when the process still runs. Safe to
    /// call more than once and after the end.
    func terminate()
    /// Waits until the process has ended.
    func termination() async -> MeetingAgentTermination
}

/// The seam that starts processes. Tests inject a fake and never start a CLI.
nonisolated protocol MeetingAgentProcessRunning: Sendable {
    func start(_ spec: MeetingAgentProcessSpec) throws -> any MeetingAgentProcessHandle
}

/// Every running hidden agent process, so Rafu ends them all when it quits
/// (`NSApplication.willTerminateNotification` runs synchronously).
nonisolated final class MeetingAgentProcessRegistry: Sendable {
    static let shared = MeetingAgentProcessRegistry()

    private let handles = Mutex([ObjectIdentifier: any MeetingAgentProcessHandle]())
    private let observing = Mutex(false)

    func add(_ handle: any MeetingAgentProcessHandle) {
        handles.withLock { $0[ObjectIdentifier(handle)] = handle }
    }

    func remove(_ handle: any MeetingAgentProcessHandle) {
        _ = handles.withLock { $0.removeValue(forKey: ObjectIdentifier(handle)) }
    }

    var count: Int { handles.withLock { $0.count } }

    func terminateAll() {
        let all = handles.withLock { Array($0.values) }
        for handle in all { handle.terminate() }
    }

    /// Ends each process at quit. Installed one time.
    func observeQuit() {
        let first = observing.withLock { observing -> Bool in
            defer { observing = true }
            return !observing
        }
        guard first else { return }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [self] _ in
            terminateAll()
        }
    }
}

/// Starts the real CLI with `Process`.
nonisolated struct MeetingAgentSystemProcessRunner: MeetingAgentProcessRunning {
    let registry: MeetingAgentProcessRegistry

    init(registry: MeetingAgentProcessRegistry = .shared) {
        self.registry = registry
    }

    func start(_ spec: MeetingAgentProcessSpec) throws -> any MeetingAgentProcessHandle {
        registry.observeQuit()
        return try MeetingAgentSystemProcess(spec: spec, registry: registry)
    }
}

/// A hidden agent process with pipes. Standard error goes to the null
/// device, so a CLI that writes much there can never block. The packet is
/// written on a private queue, so a full pipe never blocks a caller; a
/// write after the process ended returns an error, not SIGPIPE.
nonisolated final class MeetingAgentSystemProcess: MeetingAgentProcessHandle {
    static let killDelay: DispatchTimeInterval = .seconds(2)

    /// The end of the process, shared with the termination handler.
    private final class ExitBox: Sendable {
        private struct State {
            var termination: MeetingAgentTermination?
            var waiters: [CheckedContinuation<MeetingAgentTermination, Never>] = []
            var onEnd: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        var isRunning: Bool { state.withLock { $0.termination == nil } }

        func resolve(_ termination: MeetingAgentTermination) {
            let (waiters, onEnd) = state.withLock { state in
                state.termination = termination
                let waiting = state.waiters
                let onEnd = state.onEnd
                state.waiters = []
                state.onEnd = nil
                return (waiting, onEnd)
            }
            // The registry forgets the process before a waiter resumes.
            onEnd?()
            for waiter in waiters { waiter.resume(returning: termination) }
        }

        /// Calls `action` one time when the process ends (now, when it has).
        func whenEnded(_ action: @escaping @Sendable () -> Void) {
            let ended = state.withLock { state -> Bool in
                guard state.termination == nil else { return true }
                state.onEnd = action
                return false
            }
            if ended { action() }
        }

        func wait() async -> MeetingAgentTermination {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state -> MeetingAgentTermination? in
                    if let termination = state.termination { return termination }
                    state.waiters.append(continuation)
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
        }
    }

    let output: AsyncStream<Data>
    private let pid: pid_t
    private let exitBox: ExitBox
    /// Keeps the `Process` object for the life of the handle.
    private let process: Mutex<Process?>

    init(spec: MeetingAgentProcessSpec, registry: MeetingAgentProcessRegistry) throws {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.currentDirectoryURL
        process.standardError = FileHandle.nullDevice

        let inputPipe: Pipe? = spec.standardInput == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        output = stream
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        let exitBox = ExitBox()
        self.exitBox = exitBox
        process.terminationHandler = { finished in
            exitBox.resolve(
                finished.terminationReason == .uncaughtSignal
                    ? .signalled(finished.terminationStatus) : .exited(finished.terminationStatus))
        }
        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        pid = process.processIdentifier
        self.process = Mutex(process)
        // The child has its own copies of these pipe ends.
        try? outputPipe.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()

        registry.add(self)
        exitBox.whenEnded { [self] in registry.remove(self) }

        if let inputPipe, let packet = spec.standardInput {
            Self.write(packet, to: inputPipe.fileHandleForWriting)
        }
    }

    /// Writes the packet, then closes standard input (end of file). Runs on
    /// a private queue; an error (the process ended) only closes the pipe.
    private static func write(_ packet: Data, to handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue(label: "dev.vatsalsaglani.rafu.meetings.agent-input").async {
            packet.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    remaining -= written
                    pointer += written
                }
            }
            try? handle.close()
        }
    }

    func terminate() {
        guard exitBox.isRunning else { return }
        kill(pid, SIGTERM)
        let pid = pid
        let exitBox = exitBox
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killDelay) {
            if exitBox.isRunning { kill(pid, SIGKILL) }
        }
    }

    func termination() async -> MeetingAgentTermination {
        await exitBox.wait()
    }
}
