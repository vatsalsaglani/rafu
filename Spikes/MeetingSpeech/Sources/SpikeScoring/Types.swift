// Shared value types for the scoring library. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md in the primary checkout.

/// One word with its time span and, once assigned, its speaker label.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: String?

    public init(text: String, start: Double, end: Double, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// One speaker-active time span, as produced by a diarizer or read from RTTM.
public struct DiarSegment: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}
