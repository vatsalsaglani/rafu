// Standard input, standard output, memory footprint and the parent watch of
// the helper. No file is written here: results go to standard output only.
import Darwin
import Dispatch
import Foundation
import RafuCore
import Synchronization

/// Ends the process now with a protocol exit code.
func exitWorker(_ code: MeetingWorkerExitCode) -> Never {
    exit(code.rawValue)
}

/// Writes JSON lines to standard output. Safe from each thread (library
/// callbacks write progress lines). A failed write means the app is gone:
/// the helper exits with "cancelled".
final class WorkerOutput: Sendable {
    private let lock = Mutex(())
    private let finished = Atomic<Bool>(false)

    /// True once the `done` line is on its way: the end of input no longer
    /// means "cancel".
    var isFinished: Bool { finished.load(ordering: .acquiring) }

    init() {
        // A write to a closed pipe returns EPIPE instead of a signal.
        signal(SIGPIPE, SIG_IGN)
    }

    func send(_ event: MeetingWorkerEvent) {
        if case .done = event { finished.store(true, ordering: .releasing) }
        for part in event.batched() {
            write(part)
        }
    }

    private func write(_ event: MeetingWorkerEvent) {
        let line: Data
        do {
            line = try event.encodedLine()
        } catch {
            // Too long for one line: halve the list, or drop a word that is
            // too long by itself (never seen with Nemotron or WhisperKit).
            switch event {
            case .final(let track, let words) where words.count > 1:
                let half = words.count / 2
                write(.final(track: track, words: Array(words[..<half])))
                write(.final(track: track, words: Array(words[half...])))
            case .segments(let segments) where segments.count > 1:
                let half = segments.count / 2
                write(.segments(Array(segments[..<half])))
                write(.segments(Array(segments[half...])))
            default:
                break
            }
            return
        }
        lock.withLock { _ in
            line.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = Darwin.write(STDOUT_FILENO, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        exitWorker(.cancelled)
                    }
                    remaining -= written
                    pointer += written
                }
            }
        }
    }

    /// Sends an error line and exits.
    func fail(_ domain: MeetingWorkerErrorDomain, code: Int, exit exitCode: MeetingWorkerExitCode)
        -> Never
    {
        send(.error(domain: domain, code: code))
        exitWorker(exitCode)
    }
}

/// Reads the first line of standard input (the request) synchronously,
/// before any job starts. Returns the line and the bytes after it.
func readRequestLine() -> (line: Data, rest: Data)? {
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        if let newline = collected.firstIndex(of: 0x0A) {
            let line = Data(collected[..<newline])
            let rest = Data(collected[collected.index(after: newline)...])
            return (line, rest)
        }
        guard collected.count <= MeetingWorkerProtocol.maximumRequestBytes else { return nil }
        let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return nil }
        collected.append(contentsOf: buffer[0..<count])
    }
}

/// Reads standard input on its own thread and hands blocks to an async
/// consumer, with back pressure: the thread reads the next block only
/// when fewer than `depth` blocks wait. So a slow engine fills the pipe,
/// and the app (not the helper) decides what to drop.
final class WorkerInputPump: Sendable {
    let blocks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let slots: DispatchSemaphore

    init(depth: Int = 4) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.blocks = stream
        self.continuation = continuation
        // Made with 0 and signalled `depth` times: libdispatch traps when
        // a semaphore is freed with a value below the one it was made with.
        self.slots = DispatchSemaphore(value: 0)
        for _ in 0..<depth { slots.signal() }
    }

    /// Starts the reader thread. `onEnd` runs on that thread at the end
    /// of input.
    func start(onEnd: @escaping @Sendable () -> Void = {}) {
        let continuation = continuation
        let slots = slots
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                slots.wait()
                let count = buffer.withUnsafeMutableBytes {
                    read(STDIN_FILENO, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR {
                    slots.signal()
                    continue
                }
                guard count > 0 else {
                    continuation.finish()
                    onEnd()
                    return
                }
                continuation.yield(Data(buffer[0..<count]))
            }
        }
        thread.name = "input"
        thread.start()
    }

    /// The consumer calls this after it has used one block.
    func blockUsed() {
        slots.signal()
    }
}

/// In the file modes, the end of standard input means "cancel".
func exitWhenInputCloses(_ output: WorkerOutput) {
    let pump = WorkerInputPump(depth: 1)
    pump.start(onEnd: {
        if !output.isFinished { exitWorker(.cancelled) }
    })
    Task.detached {
        for await _ in pump.blocks {
            pump.blockUsed()
        }
    }
}

/// Ends the helper when the app that started it ends.
func exitWhenParentEnds() -> any DispatchSourceProcess {
    let parent = getppid()
    let source = DispatchSource.makeProcessSource(
        identifier: parent, eventMask: .exit, queue: .global())
    source.setEventHandler { exitWorker(.cancelled) }
    source.resume()
    // The parent may have ended before the source was made.
    if getppid() != parent || parent == 1 { exitWorker(.cancelled) }
    return source
}

/// The process memory footprint: now, and the peak since launch (the
/// same "peak memory footprint" that `/usr/bin/time -l` prints).
func memoryFootprint() -> (current: Int64, peak: Int64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    let current = Int64(info.phys_footprint)
    return (current, max(current, Int64(info.ledger_phys_footprint_peak)))
}

/// Milliseconds of a `ContinuousClock` duration.
func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}
