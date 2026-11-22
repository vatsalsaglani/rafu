import Darwin
import Foundation
import RafuCore
import Synchronization

/// How to start one helper process: an executable and an argument array,
/// never a shell string. `environment` holds `PATH`, `HOME` and `TMPDIR`
/// only.
nonisolated struct MeetingWorkerLaunchSpec: Sendable, Equatable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
}

/// How a helper process ended.
nonisolated enum MeetingWorkerTermination: Sendable, Equatable {
    case exited(Int32)
    case signalled(Int32)
}

/// One running helper. The client writes standard input through `send`
/// and reads standard output from `output`. Standard error is discarded.
nonisolated protocol MeetingWorkerConnection: AnyObject, Sendable {
    /// Bytes from standard output; the stream ends when the helper closes it.
    var output: AsyncStream<Data> { get }
    /// Queues bytes for standard input and never blocks. A `droppable`
    /// write (a live audio frame) can be dropped, oldest first, when the
    /// pipe stays full; a request line never is.
    func send(_ data: Data, droppable: Bool)
    /// Closes standard input after the queued bytes.
    func closeInput()
    /// SIGTERM now, SIGKILL after 2 s when the helper still runs.
    func terminate()
    /// Waits until the helper has ended.
    func termination() async -> MeetingWorkerTermination
    /// Live audio frames dropped because the pipe stayed full.
    var droppedFrameCount: Int { get }
}

/// Starts helpers. Tests inject a fake that plays recorded line sequences.
nonisolated protocol MeetingWorkerLaunching: Sendable {
    func launch(_ spec: MeetingWorkerLaunchSpec) throws -> any MeetingWorkerConnection
}

/// Starts the real helper with `Process`.
nonisolated struct MeetingWorkerProcessLauncher: MeetingWorkerLaunching {
    func launch(_ spec: MeetingWorkerLaunchSpec) throws -> any MeetingWorkerConnection {
        try MeetingWorkerProcessConnection(spec: spec)
    }
}

/// A helper process with pipes. Writes go through one serial queue, so a
/// full pipe never blocks a caller or the cooperative thread pool; reads
/// come from a readability handler.
nonisolated final class MeetingWorkerProcessConnection: MeetingWorkerConnection {
    /// Live frames that may wait for the pipe before the oldest is dropped
    /// (about 4 s of audio for two tracks).
    static let maximumPendingFrames = 8
    static let killDelay: DispatchTimeInterval = .seconds(2)

    private enum Pending {
        case bytes(Data, droppable: Bool)
        case close
    }

    private struct WriterState {
        var pending: [Pending] = []
        var draining = false
        var broken = false
        var closed = false
        var dropped = 0
    }

    /// The end of the process, shared with the termination handler.
    private final class ExitBox: Sendable {
        private struct State {
            var termination: MeetingWorkerTermination?
            var waiters: [CheckedContinuation<MeetingWorkerTermination, Never>] = []
        }

        private let state = Mutex(State())

        var isRunning: Bool { state.withLock { $0.termination == nil } }

        func resolve(_ termination: MeetingWorkerTermination) {
            let waiters = state.withLock { state in
                state.termination = termination
                let waiting = state.waiters
                state.waiters = []
                return waiting
            }
            for waiter in waiters { waiter.resume(returning: termination) }
        }

        func wait() async -> MeetingWorkerTermination {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state -> MeetingWorkerTermination? in
                    if let termination = state.termination { return termination }
                    state.waiters.append(continuation)
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
        }
    }

    let output: AsyncStream<Data>
    private let process: Mutex<Process?>
    private let pid: pid_t
    private let inputDescriptor: Int32
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let writer = Mutex(WriterState())
    private let exitBox: ExitBox
    private let writeQueue = DispatchQueue(label: "dev.vatsalsaglani.rafu.meetings.worker-input")

    init(spec: MeetingWorkerLaunchSpec) throws {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        output = stream
        outputHandle = outputPipe.fileHandleForReading
        inputHandle = inputPipe.fileHandleForWriting
        inputDescriptor = inputHandle.fileDescriptor
        // A write after the helper has gone returns EPIPE, not SIGPIPE.
        _ = fcntl(inputDescriptor, F_SETNOSIGPIPE, 1)

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
        // The child has its own copies of the pipe ends.
        try? outputPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()
    }

    var droppedFrameCount: Int { writer.withLock { $0.dropped } }

    func send(_ data: Data, droppable: Bool) {
        let startDrain = writer.withLock { state -> Bool in
            guard !state.broken, !state.closed else { return false }
            if droppable {
                let waiting = state.pending.filter {
                    if case .bytes(_, true) = $0 { return true }
                    return false
                }.count
                if waiting >= Self.maximumPendingFrames,
                    let oldest = state.pending.firstIndex(where: {
                        if case .bytes(_, true) = $0 { return true }
                        return false
                    })
                {
                    state.pending.remove(at: oldest)
                    state.dropped += 1
                }
            }
            state.pending.append(.bytes(data, droppable: droppable))
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        if startDrain { writeQueue.async { self.drain() } }
    }

    func closeInput() {
        let startDrain = writer.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.closed = true
            state.pending.append(.close)
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        if startDrain { writeQueue.async { self.drain() } }
    }

    /// Runs on `writeQueue` only.
    private func drain() {
        while true {
            let next = writer.withLock { state -> Pending? in
                guard !state.pending.isEmpty else {
                    state.draining = false
                    return nil
                }
                return state.pending.removeFirst()
            }
            guard let next else { return }
            switch next {
            case .bytes(let data, _):
                if !writeAll(data) {
                    writer.withLock { state in
                        state.broken = true
                        state.pending = []
                        state.draining = false
                    }
                    try? inputHandle.close()
                    return
                }
            case .close:
                try? inputHandle.close()
            }
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(inputDescriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
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

    func termination() async -> MeetingWorkerTermination {
        await exitBox.wait()
    }
}
