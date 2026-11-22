// Groups sub-word tokens (SentencePiece, word-start marked) into words with
// start/end times. Nemotron emits one time for each token; FluidAudio's
// `finishWithTokenTimings()` gives a word-start mark per the plan's
// "Current behaviour" section. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.

public struct Token: Sendable, Equatable {
    public var text: String
    public var time: Double
    public var isWordStart: Bool

    public init(text: String, time: Double, isWordStart: Bool) {
        self.text = text
        self.time = time
        self.isWordStart = isWordStart
    }
}

public enum TokenWordGrouper {
    /// A word's start time is the time of its first (word-start) token.
    /// Its end time is the start time of the next word-start token, or
    /// `fallbackEnd` for the last word. A leading run of tokens with
    /// `isWordStart == false` (should not normally happen) is treated as
    /// the start of the first word.
    public static func words(from tokens: [Token], fallbackEnd: Double) -> [TimedWord] {
        guard !tokens.isEmpty else { return [] }

        var groups: [[Token]] = []
        for token in tokens {
            if token.isWordStart || groups.isEmpty {
                groups.append([token])
            } else {
                groups[groups.count - 1].append(token)
            }
        }

        var words: [TimedWord] = []
        for (index, group) in groups.enumerated() {
            let text = group.map(\.text).joined()
            let start = group[0].time
            let end = index + 1 < groups.count ? groups[index + 1][0].time : fallbackEnd
            words.append(TimedWord(text: text, start: start, end: max(end, start)))
        }
        return words
    }
}
