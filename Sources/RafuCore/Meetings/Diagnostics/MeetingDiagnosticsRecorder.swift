import Foundation
import Synchronization

/// The real `MeetingDiagnosticsRecording`. `record` puts the event on a
/// bounded queue and returns at once; one task drains the queue into the
/// file writer and the `Logger` mirror.
///
/// - The queue holds 1,024 events (`AsyncStream` with `.bufferingNewest`).
///   When it is full the oldest event is dropped and counted; the next line
///   that is written reports the count as `dropped`.
/// - `clock` on a line is the seconds since the first event of that meeting
///   in this process (the capture package records its permission and device
///   facts at Start, so this is close to the meeting clock).
/// - Events that mark an end or an error (`recordingStopped`,
///   `helperExited`, `engineError`, `userFacingError`) flush the writer at
///   once, so the last lines survive a crash that follows.
public final class MeetingDiagnosticsRecorder: MeetingDiagnosticsRecording, Sendable {
    public static let defaultQueueCapacity = 1024

    fileprivate enum Item: Sendable {
        case entry(MeetingDiagnosticsEntry)
        case flush(FlushToken)
    }

    /// Resumes its continuation exactly once.
    fileprivate final class FlushToken: Sendable {
        private let continuation: Mutex<CheckedContinuation<Void, Never>?>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume() {
            let taken = continuation.withLock { value -> CheckedContinuation<Void, Never>? in
                defer { value = nil }
                return value
            }
            taken?.resume()
        }
    }

    /// A count that the producer side adds to and the drain task takes.
    fileprivate final class Counter: Sendable {
        private let value = Mutex(0)

        func add(_ amount: Int = 1) { value.withLock { $0 += amount } }
        func take() -> Int {
            value.withLock { current in
                defer { current = 0 }
                return current
            }
        }
        var total: Int { value.withLock { $0 } }
    }

    private let continuation: AsyncStream<Item>.Continuation
    private let drain: Mutex<Task<Void, Never>?>
    private let stream: Mutex<AsyncStream<Item>?>
    private let dropCount = Counter()
    private let totalDropped = Counter()
    private let writer: MeetingDiagnosticsFileWriter
    private let logSink: (any MeetingDiagnosticsLogSink)?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - autostart: false keeps the drain task stopped until `start()`.
    ///     Tests use it to fill the queue without a race.
    public convenience init(
        writer: MeetingDiagnosticsFileWriter, logSink: (any MeetingDiagnosticsLogSink)? = nil,
        queueCapacity: Int = MeetingDiagnosticsRecorder.defaultQueueCapacity
    ) {
        self.init(
            writer: writer, logSink: logSink, queueCapacity: queueCapacity, autostart: true,
            now: { Date() })
    }

    init(
        writer: MeetingDiagnosticsFileWriter, logSink: (any MeetingDiagnosticsLogSink)?,
        queueCapacity: Int, autostart: Bool, now: @escaping @Sendable () -> Date
    ) {
        let (stream, continuation) = AsyncStream<Item>.makeStream(
            of: Item.self, bufferingPolicy: .bufferingNewest(max(1, queueCapacity)))
        self.continuation = continuation
        self.stream = Mutex(stream)
        self.drain = Mutex(nil)
        self.writer = writer
        self.logSink = logSink
        self.now = now
        if autostart { start() }
    }

    deinit {
        continuation.finish()
    }

    /// Starts the drain task (once).
    func start() {
        guard
            let stream = stream.withLock({ value -> AsyncStream<Item>? in
                defer { value = nil }
                return value
            })
        else { return }
        let writer = writer
        let sink = logSink
        let drops = dropCount
        let task = Task(name: "Meeting diagnostics drain") {
            var origins: [MeetingID: Date] = [:]
            for await item in stream {
                switch item {
                case .entry(let entry):
                    var clock: Double?
                    if let meeting = entry.meeting {
                        let origin = origins[meeting] ?? entry.time
                        origins[meeting] = origin
                        clock = max(0, entry.time.timeIntervalSince(origin))
                    }
                    let stamped = MeetingDiagnosticsEntry(
                        meeting: entry.meeting, event: entry.event, time: entry.time, clock: clock)
                    let lost = drops.take()
                    await writer.append(stamped, queueDropped: lost)
                    sink?.log(entry.event.diagnosticDescription, meeting: entry.meeting)
                    if entry.event.flushesImmediately { await writer.flush() }
                case .flush(let token):
                    await writer.flush()
                    token.resume()
                }
            }
        }
        drain.withLock { $0 = task }
    }

    // MARK: MeetingDiagnosticsRecording

    /// Puts the event on the queue and returns at once. Safe from each
    /// thread except an audio callback.
    public func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        let entry = MeetingDiagnosticsEntry(
            meeting: meeting, event: event, time: now(), clock: nil)
        switch continuation.yield(.entry(entry)) {
        case .dropped(let item):
            noteDropped(item)
        case .enqueued, .terminated:
            break
        @unknown default:
            break
        }
    }

    private func noteDropped(_ item: Item) {
        switch item {
        case .entry:
            dropCount.add()
            totalDropped.add()
        case .flush(let token):
            token.resume()
        }
    }

    /// How many events the queue dropped since this recorder was made.
    public var droppedEventCount: Int { totalDropped.total }

    // MARK: Flush and stop

    /// Returns when each event recorded before this call is written to disk.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let token = FlushToken(continuation)
            switch self.continuation.yield(.flush(token)) {
            case .dropped(let item):
                noteDropped(item)
            case .terminated:
                token.resume()
            case .enqueued:
                break
            @unknown default:
                break
            }
        }
    }

    /// Ends the queue, waits until the drain task has written each queued
    /// event, and flushes the writer. Later `record` calls do nothing.
    public func stop() async {
        continuation.finish()
        let task = drain.withLock { $0 }
        await task?.value
        await writer.stop()
    }

    /// Deletes the diagnostics file of a deleted meeting. Lines that are
    /// still queued are written first, so none of them recreates the file.
    public func deleteDiagnostics(for meeting: MeetingID) async {
        await flush()
        await writer.delete(meeting: meeting)
    }
}

extension MeetingDiagnosticEvent {
    /// True for an event that marks an end or an error.
    fileprivate var flushesImmediately: Bool {
        switch self {
        case .recordingStopped, .helperExited, .engineError, .userFacingError: true
        default: false
        }
    }
}
