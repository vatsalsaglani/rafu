// TurnBuilder: rules 1, 2, 4, 5 of plan section 5.2 (parent plan
// .rafu/plans/meeting-notetaker-combined.md, "5.2 Turn detection"). Rules 3
// (split a long turn), 6 (gap marker) and 7 (live/final replace) are not
// needed for the spike's boundary-accuracy and speaker-attributed word
// error measurements and are not implemented here. Throw-away spike code;
// see .rafu/plans/meeting-speech-spike.md.

public struct Turn: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var words: [TimedWord]
    public var isBackchannel: Bool
    public var isOverlap: Bool

    public var text: String { words.map(\.text).joined(separator: " ") }
}

public struct TurnBuilderOptions: Sendable {
    /// Rule 2: a new turn starts after a pause of this many seconds or
    /// more in the same speaker (plan range 0.5 to 2.0 s, default 0.8 s).
    public var pauseSeconds: Double
    /// Rule 4: a short piece inside another speaker's turn becomes its own
    /// turn flagged `backchannel`.
    public var backchannelMaxDuration: Double
    public var backchannelMaxWords: Int

    public init(
        pauseSeconds: Double = 0.8,
        backchannelMaxDuration: Double = 1.0,
        backchannelMaxWords: Int = 3
    ) {
        self.pauseSeconds = pauseSeconds
        self.backchannelMaxDuration = backchannelMaxDuration
        self.backchannelMaxWords = backchannelMaxWords
    }
}

public enum TurnBuilder {
    /// Builds turns from words that already carry a speaker label (see
    /// `WordSpeakerAssigner`, or the two fixed "Me"/"Them" track labels).
    /// Words without a speaker are dropped.
    public static func build(words: [TimedWord], options: TurnBuilderOptions = .init()) -> [Turn] {
        let labeled = words.filter { $0.speaker != nil }.sorted { $0.start < $1.start }
        guard !labeled.isEmpty else { return [] }

        // Rule 1 (speaker change) + rule 2 (pause): one open draft turn per
        // speaker; a word extends its speaker's open turn unless the pause
        // since that speaker's last word is too long, in which case the
        // open turn closes and a new one starts.
        var open: [String: Turn] = [:]
        var closed: [Turn] = []

        for word in labeled {
            guard let speaker = word.speaker else { continue }
            if var current = open[speaker] {
                if word.start - current.end < options.pauseSeconds {
                    current.end = max(current.end, word.end)
                    current.words.append(word)
                    open[speaker] = current
                    continue
                }
                closed.append(current)
                open[speaker] = Turn(
                    speaker: speaker, start: word.start, end: word.end,
                    words: [word], isBackchannel: false, isOverlap: false
                )
            } else {
                open[speaker] = Turn(
                    speaker: speaker, start: word.start, end: word.end,
                    words: [word], isBackchannel: false, isOverlap: false
                )
            }
        }
        closed.append(contentsOf: open.values)

        var turns = closed.sorted { $0.start < $1.start }

        // Rule 5: two different speakers active at the same time both get
        // the `overlap` flag.
        for i in 0..<turns.count {
            for j in (i + 1)..<turns.count {
                guard turns[i].speaker != turns[j].speaker else { continue }
                if turns[i].start < turns[j].end && turns[j].start < turns[i].end {
                    turns[i].isOverlap = true
                    turns[j].isOverlap = true
                }
            }
        }

        // Rule 4: a short turn fully inside another speaker's turn is a
        // backchannel, not an overlap. (It stays its own turn either way;
        // the containing turn is never cut.)
        for i in 0..<turns.count {
            let duration = turns[i].end - turns[i].start
            guard duration < options.backchannelMaxDuration, turns[i].words.count <= options.backchannelMaxWords else {
                continue
            }
            let isContained = turns.contains { other in
                other.speaker != turns[i].speaker
                    && other.start <= turns[i].start
                    && turns[i].end <= other.end
            }
            if isContained {
                turns[i].isBackchannel = true
                turns[i].isOverlap = false
            }
        }

        return turns.sorted { $0.start < $1.start }
    }
}
