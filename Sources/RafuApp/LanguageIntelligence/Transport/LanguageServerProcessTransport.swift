import Foundation
import Synchronization

/// Everything needed to spawn a language server: executable, argv, and an
/// optional environment/working directory override. Never a shell string —
/// `LanguageServerProcessTransport` spawns `executableURL` with `arguments`
/// as an argv array, the same shape as `GitCommandRunner`.
nonisolated struct LanguageServerLaunchSpecification: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let currentDirectoryURL: URL?
}

/// How a spawned language server process ended.
nonisolated struct ProcessExitStatus: Sendable, Equatable {
    nonisolated enum Reason: Sendable, Equatable {
        case exit
        case uncaughtSignal
    }

    let code: Int32
    let reason: Reason
}

/// Thrown by `LanguageServerProcessTransport.send(_:)` when the process
/// hasn't been started, or has already exited/closed.
nonisolated enum LanguageServerProcessTransportError: Error, Equatable {
    case notRunning
}

/// A fixed-capacity byte buffer for captured stderr, appended to
/// synchronously from a `Pipe` readability handler (an arbitrary background
/// queue, never the actor). `Mutex`-guarded rather than actor-isolated so
/// the handler doesn't need to hop onto the transport actor just to record
/// bytes nobody has asked for yet. Exposed only via `snapshot()` — never
/// logged, never emitted automatically.
nonisolated final class BoundedByteRingBuffer: Sendable {
    private let capacityBytes: Int
    private let storage: Mutex<Data>

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
        self.storage = Mutex(Data())
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.withLock { buffer in
            buffer.append(data)
            if buffer.count > capacityBytes {
                buffer.removeFirst(buffer.count - capacityBytes)
            }
        }
    }

    func snapshot() -> Data {
        storage.withLock { $0 }
    }
}

/// The only file in lane 2 that touches `Process`. Speaks
/// `LanguageServerTransport` over a spawned language server's stdio, with
/// stderr captured into a bounded ring buffer instead of surfaced anywhere
/// that could log it.
actor LanguageServerProcessTransport: LanguageServerTransport {
    private let specification: LanguageServerLaunchSpecification
    private let stderrRingBuffer: BoundedByteRingBuffer
    private let process = Process()
    private let stdoutStream: AsyncThrowingStream<Data, any Error>
    private var stdoutContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var stdinHandle: FileHandle?
    private var stdoutReadHandle: FileHandle?
    private var stderrReadHandle: FileHandle?
    private var hasStarted = false
    private var isClosed = false
    private var recordedExitStatus: ProcessExitStatus?
    private var exitWaiters: [CheckedContinuation<ProcessExitStatus, Never>] = []

    init(specification: LanguageServerLaunchSpecification, stderrCapacityBytes: Int = 64 * 1_024) {
        self.specification = specification
        self.stderrRingBuffer = BoundedByteRingBuffer(capacityBytes: stderrCapacityBytes)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.stdoutStream = stream
        self.stdoutContinuation = continuation
    }

    /// The live pid while the process is running, `nil` before launch and
    /// after exit.
    var processIdentifier: pid_t? {
        process.isRunning ? process.processIdentifier : nil
    }

    /// Spawns the process. Idempotent: a second call is a no-op.
    func startProcess() throws {
        guard !hasStarted else { return }
        hasStarted = true

        process.executableURL = specification.executableURL
        process.arguments = specification.arguments
        if let environment = specification.environment {
            process.environment = environment
        }
        if let currentDirectoryURL = specification.currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutReadHandle = stdoutPipe.fileHandleForReading
        stderrReadHandle = stderrPipe.fileHandleForReading

        // Captured locally (rather than read from `self` inside the
        // handler) so the handler — which Foundation invokes on an
        // arbitrary background queue, never the actor's executor — only
        // ever touches `Sendable` values, never actor-isolated state.
        let stdoutContinuation = stdoutContinuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation?.finish()
            } else {
                stdoutContinuation?.yield(data)
            }
        }

        let stderrRingBuffer = stderrRingBuffer
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrRingBuffer.append(data)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            let reason: ProcessExitStatus.Reason =
                terminatedProcess.terminationReason == .uncaughtSignal ? .uncaughtSignal : .exit
            let status = ProcessExitStatus(
                code: terminatedProcess.terminationStatus, reason: reason)
            Task { await self?.markExited(status) }
        }

        try process.run()
    }

    /// Suspends until the process has exited, returning immediately if it
    /// already has.
    func exitStatus() async -> ProcessExitStatus {
        if let recordedExitStatus {
            return recordedExitStatus
        }
        return await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    /// A copy of the captured stderr bytes, most-recent `stderrCapacityBytes`
    /// only. Never logged — callers surface this in diagnostic UI only.
    func stderrSnapshot() -> Data {
        stderrRingBuffer.snapshot()
    }

    func send(_ data: Data) async throws {
        guard !isClosed, let stdinHandle else {
            throw LanguageServerProcessTransportError.notRunning
        }
        try stdinHandle.write(contentsOf: data)
    }

    func receive() async -> AsyncThrowingStream<Data, any Error> {
        stdoutStream
    }

    /// Idempotent: clears both readability handlers, closes stdin (so a
    /// well-behaved server sees EOF and exits on its own), terminates the
    /// process if it's still running, then closes the remaining handles.
    func close() async {
        guard !isClosed else { return }
        isClosed = true

        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil

        try? stdinHandle?.close()
        stdinHandle = nil

        if process.isRunning {
            await waitBrieflyForVoluntaryExit()
            if process.isRunning {
                process.terminate()
            }
        }

        try? stdoutReadHandle?.close()
        try? stderrReadHandle?.close()
        stdoutReadHandle = nil
        stderrReadHandle = nil

        stdoutContinuation?.finish()
        stdoutContinuation = nil
    }

    /// Polls (rather than escalating to `terminate()` immediately) for up to
    /// 200ms after stdin EOF, matching `GitCommandRunner`'s existing
    /// process-completion poll style. A well-behaved server exits on its
    /// own once it sees stdin close; escalating to SIGTERM before it gets
    /// that chance would turn every clean exit into a signal-terminated one.
    private func waitBrieflyForVoluntaryExit() async {
        var elapsedMilliseconds = 0
        while process.isRunning && elapsedMilliseconds < 200 {
            try? await Task.sleep(for: .milliseconds(10))
            elapsedMilliseconds += 10
        }
    }

    private func markExited(_ status: ProcessExitStatus) {
        guard recordedExitStatus == nil else { return }
        recordedExitStatus = status

        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: status)
        }

        // Finishes the stream if the reader hasn't already seen EOF via
        // the readability handler's empty read.
        stdoutContinuation?.finish()
        stdoutContinuation = nil
    }
}
