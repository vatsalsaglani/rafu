import Darwin
import Foundation

/// The ratio that turns host-time ticks into nanoseconds
/// (`mach_timebase_info`). On Apple silicon it is 125/3; on Intel 1/1.
public struct MeetingHostTimebase: Hashable, Codable, Sendable {
    public var numerator: UInt32
    public var denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = max(denominator, 1)
    }

    /// The timebase of this Mac.
    public static let current: MeetingHostTimebase = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MeetingHostTimebase(numerator: info.numer, denominator: info.denom)
    }()

    /// Nanoseconds as one tick count, for tests and for fake sources.
    public static let nanoseconds = MeetingHostTimebase(numerator: 1, denominator: 1)

    public func seconds(ticks: Int64) -> TimeInterval {
        Double(ticks) * Double(numerator) / Double(denominator) / 1_000_000_000
    }

    public func ticks(seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1_000_000_000 * Double(denominator) / Double(numerator)).rounded())
    }
}

/// The meeting clock: seconds since the host time of Start. Each chunk has
/// the clock time of its first sample, taken from the host time of the
/// buffer, so the two tracks line up even when one starts late (the
/// call-audio tap gives no buffer until sound plays). Never align by file
/// start. A pause does not stop the clock; paused spans are recorded as
/// spans (`MeetingRecordingSpan`).
public struct MeetingClock: Hashable, Codable, Sendable {
    public var startHostTime: UInt64
    public var timebase: MeetingHostTimebase

    public init(startHostTime: UInt64, timebase: MeetingHostTimebase = .current) {
        self.startHostTime = startHostTime
        self.timebase = timebase
    }

    /// Seconds on the meeting clock of a host time. A host time before Start
    /// gives a negative value.
    public func seconds(atHostTime hostTime: UInt64) -> TimeInterval {
        let delta =
            hostTime >= startHostTime
            ? Int64(clamping: hostTime - startHostTime)
            : -Int64(clamping: startHostTime - hostTime)
        return timebase.seconds(ticks: delta)
    }

    /// The host time of a meeting-clock time.
    public func hostTime(atSeconds seconds: TimeInterval) -> UInt64 {
        let ticks = timebase.ticks(seconds: seconds)
        if ticks >= 0 { return startHostTime &+ UInt64(ticks) }
        let back = UInt64(-ticks)
        return back > startHostTime ? 0 : startHostTime - back
    }
}

/// A time range of the recording with no audio on purpose or by accident.
public struct MeetingRecordingSpan: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        /// The user paused; no track was recorded.
        case paused
        /// One track was rebuilt after a device change or loss.
        case gap(MeetingTrack)
    }

    public var kind: Kind
    /// Meeting-clock seconds.
    public var start: TimeInterval
    /// Nil while the span is open.
    public var end: TimeInterval?

    public init(kind: Kind, start: TimeInterval, end: TimeInterval? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// The facts of one recording that later steps need: whether the "Them"
/// sound came out of the built-in speakers (the turn builder marks echo
/// then), and the spans with no audio. Written to `recording.json` in the
/// meeting's audio folder.
public struct MeetingRecordingFacts: Hashable, Codable, Sendable {
    public static let fileName = "recording.json"

    public var meeting: MeetingID
    public var startDate: Date
    public var outputWasSpeakers: Bool
    public var spans: [MeetingRecordingSpan]
    /// Meeting-clock seconds at Stop; nil while recording.
    public var endTime: TimeInterval?

    public init(
        meeting: MeetingID, startDate: Date, outputWasSpeakers: Bool,
        spans: [MeetingRecordingSpan] = [], endTime: TimeInterval? = nil
    ) {
        self.meeting = meeting
        self.startDate = startDate
        self.outputWasSpeakers = outputWasSpeakers
        self.spans = spans
        self.endTime = endTime
    }

    /// Recorded seconds without the paused spans.
    public var recordedSeconds: TimeInterval {
        guard let endTime else { return 0 }
        let paused = spans.reduce(0.0) { total, span in
            guard span.kind == .paused else { return total }
            return total + max(0, (span.end ?? endTime) - span.start)
        }
        return max(0, endTime - paused)
    }
}
