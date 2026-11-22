import Foundation

/// One sub-word token with its time, as Nemotron gives it through
/// `finishWithTokenTimings()` / `getTokenTimings()`.
public struct MeetingWorkerToken: Equatable, Sendable {
    public var text: String
    /// Seconds from the start of the audio fed to the engine.
    public var time: Double
    public var isWordStart: Bool

    public init(text: String, time: Double, isWordStart: Bool) {
        self.text = text
        self.time = time
        self.isWordStart = isWordStart
    }

    /// A token from SentencePiece text: a leading "▁" (U+2581) or space
    /// marks the start of a word.
    public init(piece: String, time: Double) {
        self.init(
            text: piece, time: time,
            isWordStart: piece.hasPrefix("\u{2581}") || piece.hasPrefix(" "))
    }
}

/// Groups sub-word tokens into words (the speech spike's tested
/// `TokenWordGrouper`, with the word-start marks removed from the text).
public enum MeetingTokenWordGrouper {
    /// A word starts at its first (word-start) token and ends at the start
    /// of the next word, or at `fallbackEnd` for the last word. A leading
    /// run of tokens with no word-start mark starts the first word. Words
    /// with no text after the marks are removed are dropped.
    public static func words(from tokens: [MeetingWorkerToken], fallbackEnd: Double)
        -> [MeetingWord]
    {
        let groups = group(tokens)
        var words: [MeetingWord] = []
        words.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let start = group[0].time
            let end = index + 1 < groups.count ? groups[index + 1][0].time : fallbackEnd
            let text = cleanText(group)
            guard !text.isEmpty else { continue }
            words.append(MeetingWord(text: text, start: start, end: max(end, start)))
        }
        return words
    }

    static func group(_ tokens: [MeetingWorkerToken]) -> [[MeetingWorkerToken]] {
        var groups: [[MeetingWorkerToken]] = []
        for token in tokens {
            if token.isWordStart || groups.isEmpty {
                groups.append([token])
            } else {
                groups[groups.count - 1].append(token)
            }
        }
        return groups
    }

    static func cleanText(_ group: [MeetingWorkerToken]) -> String {
        group.map(\.text).joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Turns a growing token list into final words as soon as the next word
/// starts, and gives the last, unfinished word as volatile text. The token
/// list of a streaming engine only grows; tokens never change.
public struct MeetingLiveWordAccumulator: Sendable {
    /// Tokens already turned into final words.
    public private(set) var consumedTokenCount = 0

    public init() {}

    public struct Update: Equatable, Sendable {
        public var finalWords: [MeetingWord]
        /// The unfinished last word, if any: its text and start time.
        public var volatileText: String?
        public var volatileStart: Double?
    }

    /// `tokens` is the whole list so far (it must start with the tokens of
    /// the last call).
    public mutating func update(allTokens tokens: [MeetingWorkerToken]) -> Update {
        guard consumedTokenCount < tokens.count else {
            return Update(finalWords: [], volatileText: nil, volatileStart: nil)
        }
        let fresh = Array(tokens[consumedTokenCount...])
        // The index (in `fresh`) of the last word start; the words before
        // it are complete.
        let lastStart = fresh.lastIndex(where: \.isWordStart) ?? 0
        var finalWords: [MeetingWord] = []
        if lastStart > 0 {
            let complete = Array(fresh[..<lastStart])
            finalWords = MeetingTokenWordGrouper.words(
                from: complete, fallbackEnd: fresh[lastStart].time)
        }
        consumedTokenCount += lastStart
        let tail = Array(fresh[lastStart...])
        let text = MeetingTokenWordGrouper.cleanText(tail)
        return Update(
            finalWords: finalWords, volatileText: text.isEmpty ? nil : text,
            volatileStart: tail.first?.time)
    }

    /// The last words at the end of the stream. `fallbackEnd` is the end of
    /// the audio fed, in the same seconds as the token times.
    public mutating func finish(allTokens tokens: [MeetingWorkerToken], fallbackEnd: Double)
        -> [MeetingWord]
    {
        guard consumedTokenCount < tokens.count else { return [] }
        let rest = Array(tokens[consumedTokenCount...])
        consumedTokenCount = tokens.count
        return MeetingTokenWordGrouper.words(from: rest, fallbackEnd: fallbackEnd)
    }
}

/// Maps "seconds of audio fed to the engine" to the meeting clock for one
/// track. A pause or a gap in the frames adds an anchor; contiguous frames
/// add none, so the list stays small.
public struct MeetingLiveClockMap: Sendable {
    private struct Anchor: Sendable {
        var fedSamples: Int
        var meetingTime: Double
    }

    private var anchors: [Anchor] = []
    public private(set) var fedSamples = 0
    /// Frames that start this close to the expected time count as contiguous.
    public static let tolerance: Double = 0.02

    public init() {}

    public var anchorCount: Int { anchors.count }

    /// Records one frame of `sampleCount` samples that starts at `startTime`
    /// on the meeting clock.
    public mutating func record(startTime: Double, sampleCount: Int) {
        if let last = anchors.last {
            let expected =
                last.meetingTime + Double(fedSamples - last.fedSamples)
                / MeetingAudioFormat.sampleRate
            if abs(expected - startTime) > Self.tolerance {
                anchors.append(Anchor(fedSamples: fedSamples, meetingTime: startTime))
            }
        } else {
            anchors.append(Anchor(fedSamples: fedSamples, meetingTime: startTime))
        }
        fedSamples += sampleCount
    }

    /// The meeting-clock time of `seconds` of fed audio.
    public func meetingTime(forFedSeconds seconds: Double) -> Double {
        let sample = Int((seconds * MeetingAudioFormat.sampleRate).rounded())
        guard !anchors.isEmpty else { return seconds }
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if anchors[mid].fedSamples <= sample { low = mid } else { high = mid - 1 }
        }
        let anchor = anchors[low]
        return anchor.meetingTime
            + Double(sample - anchor.fedSamples) / MeetingAudioFormat.sampleRate
    }

    /// The same words on the meeting clock.
    public func mapped(_ words: [MeetingWord]) -> [MeetingWord] {
        words.map {
            MeetingWord(
                text: $0.text, start: meetingTime(forFedSeconds: $0.start),
                end: meetingTime(forFedSeconds: $0.end))
        }
    }
}

/// Percentiles of chunk processing times, in milliseconds.
public enum MeetingWorkerPercentile {
    /// The value at `fraction` (0...1) of the sorted values (nearest rank,
    /// as the speech spike measured), or nil for no values.
    public static func value(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * fraction))
        return sorted[index]
    }
}
