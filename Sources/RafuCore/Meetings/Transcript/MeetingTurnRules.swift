import Foundation

/// The numbers that decide where a turn ends. One place, so the final
/// transcript and the live preview cut turns the same way.
public enum MeetingTurnRules {
    /// A silence of this many seconds inside one track starts a new turn.
    /// Measured in the speech spike: 0.8 s and 1.0 s give close results.
    public static let pauseSeconds: TimeInterval = 1.0

    /// A Them word with no overlapping speaker segment takes the nearest
    /// segment when it is at most this many seconds away.
    public static let nearestSegmentSeconds: TimeInterval = 0.5

    /// True when `gap` (seconds between the end of the turn so far and the
    /// start of the next word) is a pause. A tiny tolerance keeps a gap of
    /// exactly 1.0 s a pause when the clock values carry rounding error.
    static func isPause(gap: TimeInterval) -> Bool {
        gap >= pauseSeconds - 1e-9
    }
}

/// A recognised word with the track and speaker label it belongs to.
public struct MeetingAttributedWord: Hashable, Sendable {
    public var word: MeetingWord
    public var track: MeetingTrack
    public var speaker: MeetingSpeakerLabel

    public init(word: MeetingWord, track: MeetingTrack, speaker: MeetingSpeakerLabel) {
        self.word = word
        self.track = track
        self.speaker = speaker
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
