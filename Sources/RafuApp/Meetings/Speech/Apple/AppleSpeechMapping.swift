import Foundation
import RafuCore

/// Maps the analyzer's clock (seconds of audio given to one analyzer) to the
/// meeting clock. Each chunk carries the meeting time of its first sample; a
/// new segment starts only when a chunk does not follow the one before it, so
/// the table stays small.
nonisolated struct AppleSpeechClockMap: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var analyzerStart: TimeInterval
        var meetingStart: TimeInterval
    }

    /// A gap below this is rounding, not a new segment.
    static let tolerance: TimeInterval = 0.001
    static let maximumSegments = 1024

    private(set) var segments: [Segment] = []
    /// Seconds of audio given to the analyzer so far.
    private(set) var analyzerEnd: TimeInterval = 0

    init() {}

    /// Notes one chunk: `meetingStart` on the meeting clock, `duration` seconds.
    mutating func append(meetingStart: TimeInterval, duration: TimeInterval) {
        if segments.isEmpty
            || abs(meetingTime(forAnalyzerTime: analyzerEnd) - meetingStart) > Self.tolerance
        {
            segments.append(Segment(analyzerStart: analyzerEnd, meetingStart: meetingStart))
            if segments.count > Self.maximumSegments {
                segments.removeFirst(segments.count - Self.maximumSegments)
            }
        }
        analyzerEnd += max(0, duration)
    }

    /// The meeting time of a time on the analyzer's clock.
    func meetingTime(forAnalyzerTime time: TimeInterval) -> TimeInterval {
        guard var segment = segments.first else { return time }
        for candidate in segments.reversed() where candidate.analyzerStart <= time {
            segment = candidate
            break
        }
        return segment.meetingStart + (time - segment.analyzerStart)
    }

    func meetingRange(_ range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        let start = meetingTime(forAnalyzerTime: range.lowerBound)
        let end = meetingTime(forAnalyzerTime: range.upperBound)
        return min(start, end)...max(start, end)
    }
}

/// Turns result runs into words with times.
nonisolated enum AppleSpeechWords {
    /// Splits each run at white space. A run with several words shares its
    /// time by character count. Punctuation with no letter or digit joins the
    /// word before it, and a run that does not start with white space after a
    /// run that did not end with white space continues the word before it.
    /// `fallback` is used for a run with no time. `map` moves a time from the
    /// analyzer's clock to the meeting clock.
    static func words(
        from runs: [AppleSpeechRun], fallback: ClosedRange<TimeInterval>,
        map: (TimeInterval) -> TimeInterval
    ) -> [MeetingWord] {
        var words: [MeetingWord] = []
        var previousEndedInsideWord = false
        for run in runs {
            let text = run.text
            let range = run.range ?? fallback
            let pieces = text.split(whereSeparator: \.isWhitespace)
            guard !pieces.isEmpty else {
                previousEndedInsideWord = false
                continue
            }
            let startsWithSpace = text.first?.isWhitespace ?? true
            let totalCharacters = max(1, pieces.reduce(0) { $0 + $1.count })
            let duration = max(0, range.upperBound - range.lowerBound)
            var cursor = range.lowerBound
            for (index, piece) in pieces.enumerated() {
                let share = duration * Double(piece.count) / Double(totalCharacters)
                let start = cursor
                let end = cursor + share
                cursor = end
                let isPunctuation = !piece.contains { $0.isLetter || $0.isNumber }
                let continues = index == 0 && !startsWithSpace && previousEndedInsideWord
                if !words.isEmpty, isPunctuation || continues {
                    words[words.count - 1].text += piece
                    words[words.count - 1].end = max(words[words.count - 1].end, map(end))
                } else {
                    words.append(MeetingWord(text: String(piece), start: map(start), end: map(end)))
                }
            }
            previousEndedInsideWord = !(text.last?.isWhitespace ?? true)
        }
        return words
    }
}

/// The live-delay and word counters of one live session, for one 60 s
/// window at a time.
nonisolated struct AppleSpeechLiveStats: Sendable {
    struct Window: Sendable, Equatable {
        var delayMedianMilliseconds: Int
        var delayP95Milliseconds: Int
        var words: Int
    }

    static let windowSeconds: TimeInterval = 60
    static let maximumAppends = 4096

    /// (analyzer end time after the append, wall time of the append).
    private var appends: [(analyzerEnd: TimeInterval, wall: TimeInterval)] = []
    private var delays: [TimeInterval] = []
    private var words = 0
    private var windowStart: TimeInterval?

    init() {}

    mutating func noteAppend(analyzerEnd: TimeInterval, wall: TimeInterval) {
        if windowStart == nil { windowStart = wall }
        appends.append((analyzerEnd, wall))
        if appends.count > Self.maximumAppends {
            appends.removeFirst(appends.count - Self.maximumAppends)
        }
    }

    /// Notes a final result whose audio ends at `analyzerEnd`. Returns a
    /// window when 60 s of wall time have passed since the window started.
    mutating func noteFinal(
        analyzerEnd: TimeInterval, words count: Int, wall: TimeInterval
    ) -> Window? {
        if let index = appends.firstIndex(where: {
            $0.analyzerEnd + AppleSpeechClockMap.tolerance >= analyzerEnd
        }) {
            delays.append(max(0, wall - appends[index].wall))
            appends.removeFirst(index)
        }
        words += count
        guard let start = windowStart, wall - start >= Self.windowSeconds else { return nil }
        return closeWindow(at: wall)
    }

    /// Closes the window now (at the end of the session), when it has data.
    mutating func flush(at wall: TimeInterval) -> Window? {
        guard !delays.isEmpty || words > 0 else { return nil }
        return closeWindow(at: wall)
    }

    private mutating func closeWindow(at wall: TimeInterval) -> Window {
        let window = Window(
            delayMedianMilliseconds: Self.milliseconds(Self.percentile(delays, 0.5)),
            delayP95Milliseconds: Self.milliseconds(Self.percentile(delays, 0.95)),
            words: words)
        delays.removeAll(keepingCapacity: true)
        words = 0
        windowStart = wall
        return window
    }

    /// The nearest-rank percentile; 0 for no values.
    static func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}

/// The diagnostics fields of an error: its domain and code, never its text.
nonisolated enum AppleSpeechErrorFacts {
    static func event(for error: any Error) -> MeetingDiagnosticEvent {
        let facts = error as NSError
        return .engineError(
            engine: .text(.appleSpeech), domain: MeetingDiagnosticString(facts.domain),
            code: facts.code)
    }
}
