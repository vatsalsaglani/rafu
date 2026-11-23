import Foundation

/// The numbers that decide where a turn ends. One place, so the final
/// transcript and the live preview cut turns the same way.
public enum MeetingTurnRules {
    /// A silence of this many seconds inside one track starts a new turn.
    /// Measured in the speech spike: 0.8 s and 1.0 s give close results.
    public static let pauseSeconds: TimeInterval = 1.0

    /// A word counts as at most this many seconds of speech. Some engines
    /// (Nemotron) end each word at the start of the next word, so a silence
    /// becomes part of the word before it. Without this cap a gap is never
    /// seen and a 6-minute call becomes 2 turns.
    public static let maximumWordSeconds: TimeInterval = 0.8

    /// A turn of at least this many seconds ends at the next sentence end
    /// (`.`, `?`, `!`) or at the next gap of `shortGapSeconds`.
    public static let softTurnSeconds: TimeInterval = 20

    /// A turn is never longer than this many seconds.
    public static let hardTurnSeconds: TimeInterval = 60

    /// The gap that ends a turn that is already `softTurnSeconds` long.
    public static let shortGapSeconds: TimeInterval = 0.5

    /// A tiny tolerance, so a value exactly on a threshold stays on it when
    /// the clock values carry rounding error.
    static let tolerance: TimeInterval = 1e-9

    /// True when `gap` (seconds between the end of the turn so far and the
    /// start of the next word) is a pause.
    static func isPause(gap: TimeInterval) -> Bool {
        gap >= pauseSeconds - tolerance
    }

    /// The end of a word for the turn rules: the engine end, but at most
    /// `maximumWordSeconds` after the start, and never before the start.
    static func effectiveEnd(of word: MeetingWord) -> TimeInterval {
        min(max(word.start, word.end), word.start + maximumWordSeconds)
    }

    /// The seconds of speech that one word counts for.
    static func speechSeconds(of word: MeetingWord) -> TimeInterval {
        min(max(0, word.end - word.start), maximumWordSeconds)
    }

    /// True when `text` ends a sentence (`.`, `?` or `!`, closing quotes and
    /// brackets ignored).
    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'\u{201D}\u{2019})]")))
        guard let last = trimmed.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// True when a new turn starts before `next`. The caller checks a
    /// speaker change and an echo change first; this function holds the
    /// time rules that the final builder and the live view share.
    /// - Parameters:
    ///   - turnStart: the start of the turn so far.
    ///   - turnEnd: the effective end of the turn so far.
    ///   - lastText: the text of the last word of the turn so far.
    ///   - nextStart: the start of the next word.
    ///   - nextEnd: the effective end of the next word.
    static func startsNewTurn(
        turnStart: TimeInterval, turnEnd: TimeInterval, lastText: String,
        nextStart: TimeInterval, nextEnd: TimeInterval
    ) -> Bool {
        let gap = nextStart - turnEnd
        if isPause(gap: gap) { return true }
        if max(turnEnd, nextEnd) - turnStart > hardTurnSeconds + tolerance { return true }
        if turnEnd - turnStart >= softTurnSeconds - tolerance {
            return endsSentence(lastText) || gap >= shortGapSeconds - tolerance
        }
        return false
    }
}

/// A recognised word with the track and speaker label it belongs to.
public struct MeetingAttributedWord: Hashable, Sendable {
    public var word: MeetingWord
    public var track: MeetingTrack
    public var speaker: MeetingSpeakerLabel
    /// True when this "Me" word is the far side heard again through the
    /// microphone (see `MeetingEchoWordMarker`).
    public var isEcho: Bool

    public init(
        word: MeetingWord, track: MeetingTrack, speaker: MeetingSpeakerLabel,
        isEcho: Bool = false
    ) {
        self.word = word
        self.track = track
        self.speaker = speaker
        self.isEcho = isEcho
    }
}

extension MeetingWord {
    /// Words in clock order. The tie-breaks make the order total, so one
    /// input always gives one order (and so the same turn ids).
    static func clockOrder(_ lhs: MeetingWord, _ rhs: MeetingWord) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.text < rhs.text
    }

    /// False for a blank word or a word with a time that is not a number.
    var isUsable: Bool {
        start.isFinite && end.isFinite
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
