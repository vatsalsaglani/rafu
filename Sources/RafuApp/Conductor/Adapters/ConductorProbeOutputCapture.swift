import Darwin
import Dispatch
import Foundation
import Synchronization

/// Counts and retains a bounded probe child's output, and stops the child the
/// moment the byte count passes the cap.
///
/// The cap is enforced by the reader, not by a poller: the reader runs on a
/// private GCD queue, so it keeps working when the cooperative pool is
/// saturated. When it passes the cap it calls `onOverflow` exactly once with
/// the installed pid. Production sends `SIGKILL`; tests observe the call
/// without a process.
///
/// `onOverflow` runs while the lock is held. That is deliberate: `clear()`
/// takes the same lock, so once `clear()` returns no late reader can signal a
/// pid that the runner is about to reap (and the system could recycle). The
/// production closure is one `kill(2)` syscall.
nonisolated final class ConductorProbeOutputCollector: Sendable {
    nonisolated enum Stream: Hashable, Sendable {
        case standardOutput
        case standardError
    }

    nonisolated struct Snapshot: Sendable {
        let standardOutput: Data
        let standardError: Data
        let receivedBytes: Int
        let overflowed: Bool
    }

    private struct State: Sendable {
        var standardOutput = Data()
        var standardError = Data()
        var receivedBytes = 0
        var processIdentifier: pid_t?
        var overflowed = false
    }

    private let limit: Int
    private let onOverflow: @Sendable (pid_t) -> Void
    private let state = Mutex(State())

    init(
        limit: Int,
        onOverflow: @escaping @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGKILL) }
    ) {
        self.limit = max(0, limit)
        self.onOverflow = onOverflow
    }

    var overflowed: Bool {
        state.withLock { $0.overflowed }
    }

    /// Counts every received byte, retains at most `limit` bytes in total
    /// across both streams, and signals the child once when the count first
    /// passes the cap.
    func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }
        let limit = limit
        let onOverflow = onOverflow
        state.withLock { state in
            state.receivedBytes += data.count
            let stored = state.standardOutput.count + state.standardError.count
            let room = max(0, limit - stored)
            if room > 0 {
                switch stream {
                case .standardOutput:
                    state.standardOutput.append(data.prefix(room))
                case .standardError:
                    state.standardError.append(data.prefix(room))
                }
            }
            guard state.receivedBytes > limit, !state.overflowed else { return }
            state.overflowed = true
            if let processIdentifier = state.processIdentifier {
                onOverflow(processIdentifier)
            }
        }
    }

    /// Records the running child. If output already passed the cap, the child
    /// is signalled now.
    func install(pid processIdentifier: pid_t) {
        let onOverflow = onOverflow
        state.withLock { state in
            state.processIdentifier = processIdentifier
            if state.overflowed {
                onOverflow(processIdentifier)
            }
        }
    }

    /// Forgets the pid. Call before the runner reaps the child, so a late
    /// reader never signals a recycled pid.
    func clear() {
        state.withLock { $0.processIdentifier = nil }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(
                standardOutput: state.standardOutput,
                standardError: state.standardError,
                receivedBytes: state.receivedBytes,
                overflowed: state.overflowed)
        }
    }
}

/// Sends `SIGTERM` to a probe child as soon as the owning task is cancelled,
/// instead of waiting for the poll loop to run again.
///
/// The signal is sent while the lock is held so that, after `clear()`
/// returns, no cancellation can signal a pid the runner is reaping.
nonisolated final class ConductorProbeCancellation: Sendable {
    private struct State: Sendable {
        var processIdentifier: pid_t?
        var cancelled = false
    }

    private let state = Mutex(State())

    func install(pid processIdentifier: pid_t) {
        state.withLock { state in
            state.processIdentifier = processIdentifier
            if state.cancelled {
                _ = Darwin.kill(processIdentifier, SIGTERM)
            }
        }
    }

    func clear() {
        state.withLock { $0.processIdentifier = nil }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            if let processIdentifier = state.processIdentifier {
                _ = Darwin.kill(processIdentifier, SIGTERM)
            }
        }
    }
}

/// The two pipes a capturing probe child writes to, and their readers.
///
/// A pipe, not a file: a pipe is a bounded kernel buffer. If the reader is
/// starved the child blocks in `write(2)`; if the parent dies the child gets
/// `SIGPIPE`. Nothing reaches the disk. (A regular file gave neither, and one
/// probe wrote 107 GB in 8 minutes on 2026-11-06.)
///
/// Both readers are `DispatchSourceRead`s on one private serial queue, so the
/// final drain and every event handler are serialized, and each read end is
/// closed only in its source's cancel handler, after the last event handler.
nonisolated final class ConductorProbePipeCapture: Sendable {
    let collector: ConductorProbeOutputCollector
    let standardOutput = Pipe()
    let standardError = Pipe()

    private static let readChunkBytes = 64 * 1_024

    private struct ReaderState {
        var sources: [any DispatchSourceRead] = []
        /// Read descriptors captured before any close, keyed by stream.
        var descriptors: [ConductorProbeOutputCollector.Stream: Int32] = [:]
        /// Streams whose read end a cancel handler already closed. Changed
        /// only on `queue`, so the drain (also on `queue`) never reads a
        /// closed, possibly reused, descriptor number.
        var closedStreams: Set<ConductorProbeOutputCollector.Stream> = []
    }

    private let queue = DispatchQueue(label: "rafu.probe-output")
    private let readers = Mutex(ReaderState())

    init(collector: ConductorProbeOutputCollector) {
        self.collector = collector
    }

    /// Call once, after the child launched. Installs the pid in the collector
    /// and starts both readers.
    ///
    /// Sources are created here, not in `init`: releasing a dispatch source
    /// that was never activated crashes, and a failed launch never gets here.
    func start(pid processIdentifier: pid_t) {
        collector.install(pid: processIdentifier)
        let sources = [
            makeSource(for: standardOutput.fileHandleForReading, stream: .standardOutput),
            makeSource(for: standardError.fileHandleForReading, stream: .standardError),
        ]
        readers.withLock { $0.sources = sources }
        for source in sources {
            source.activate()
        }
    }

    /// Call once, after the child was reaped. Reads what is left in each pipe
    /// without blocking, then stops both readers. Each cancel handler closes
    /// its read end; that also breaks the source-to-self reference cycle.
    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let (sources, descriptors, closed) = self.readers.withLock { state in
                    let sources = state.sources
                    state.sources.removeAll()
                    return (sources, state.descriptors, state.closedStreams)
                }
                for (stream, descriptor) in descriptors where !closed.contains(stream) {
                    Self.drain(descriptor, stream: stream, into: self.collector)
                }
                for source in sources {
                    source.cancel()
                }
                continuation.resume()
            }
        }
    }

    private func makeSource(
        for handle: FileHandle,
        stream: ConductorProbeOutputCollector.Stream
    ) -> any DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        readers.withLock { $0.descriptors[stream] = descriptor }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            switch Self.readChunk(from: descriptor) {
            case .data(let data):
                self.collector.append(data, to: stream)
            case .endOfFile:
                // A readable EOF fires forever; stop this reader. The read end
                // stays open until the cancel handler below closes it.
                source.cancel()
            case .wouldBlock:
                break
            }
        }
        source.setCancelHandler {
            self.readers.withLock { _ = $0.closedStreams.insert(stream) }
            try? handle.close()
        }
        return source
    }

    private enum ReadResult {
        case data(Data)
        case endOfFile
        case wouldBlock
    }

    private static func readChunk(from descriptor: Int32) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: readChunkBytes)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            return .data(Data(buffer[0..<count]))
        }
        if count == 0 {
            return .endOfFile
        }
        // EAGAIN, EINTR, or a real error: the source fires again if needed,
        // and the final drain stops on the same result.
        return .wouldBlock
    }

    /// Non-blocking drain. Stops at EOF, at "would block" (a grandchild may
    /// still hold the write end), or once the collector passed its cap — so
    /// it is bounded even if something keeps writing.
    private static func drain(
        _ descriptor: Int32,
        stream: ConductorProbeOutputCollector.Stream,
        into collector: ConductorProbeOutputCollector
    ) {
        while !collector.overflowed {
            guard case .data(let data) = readChunk(from: descriptor) else { return }
            collector.append(data, to: stream)
        }
    }
}
