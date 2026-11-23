import Foundation

/// Gives each word of the "Them" track a speaker label from the speaker
/// segments of a speaker engine.
public enum MeetingWordSpeakerAssigner {
    /// The label of one word: the speaker whose segment overlaps the word
    /// most; with no overlap, the nearest segment at any distance (a tie
    /// goes to the earlier segment). Only with no valid segments (no speaker
    /// model) is a word `.them`, so a stray word never makes a "Them"
    /// speaker beside the real ones.
    public static func label(
        for word: MeetingWord, segments: [MeetingSpeakerSegment]
    ) -> MeetingSpeakerLabel {
        label(for: word, validSegments: validSegments(segments))
    }

    /// Labels every word of the "Them" track. Words keep their input order.
    public static func assign(
        themWords: [MeetingWord], segments: [MeetingSpeakerSegment]
    ) -> [MeetingAttributedWord] {
        let valid = validSegments(segments)
        return themWords.map { word in
            MeetingAttributedWord(
                word: word, track: .them, speaker: label(for: word, validSegments: valid))
        }
    }

    private static func validSegments(_ segments: [MeetingSpeakerSegment])
        -> [MeetingSpeakerSegment]
    {
        segments.filter {
            $0.speaker >= 0 && $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
        }
    }

    private static func label(
        for word: MeetingWord, validSegments: [MeetingSpeakerSegment]
    ) -> MeetingSpeakerLabel {
        guard word.start.isFinite, word.end.isFinite else { return .them }
        let wordEnd = max(word.start, word.end)

        var bestOverlap: TimeInterval = 0
        var overlapWinner: MeetingSpeakerSegment?
        var nearestGap = TimeInterval.infinity
        var nearest: MeetingSpeakerSegment?

        for segment in validSegments {
            let overlap = min(wordEnd, segment.end) - max(word.start, segment.start)
            if overlap > 0 {
                if let winner = overlapWinner {
                    if overlap > bestOverlap
                        || (overlap == bestOverlap && isEarlier(segment, than: winner))
                    {
                        bestOverlap = overlap
                        overlapWinner = segment
                    }
                } else {
                    bestOverlap = overlap
                    overlapWinner = segment
                }
            }
            // Distance between the two spans; 0 when they touch or overlap.
            let gap = max(0, max(segment.start - wordEnd, word.start - segment.end))
            if let current = nearest {
                if gap < nearestGap || (gap == nearestGap && isEarlier(segment, than: current)) {
                    nearestGap = gap
                    nearest = segment
                }
            } else {
                nearestGap = gap
                nearest = segment
            }
        }

        if let overlapWinner { return .speaker(overlapWinner.speaker) }
        if let nearest { return .speaker(nearest.speaker) }
        return .them
    }

    private static func isEarlier(_ lhs: MeetingSpeakerSegment, than rhs: MeetingSpeakerSegment)
        -> Bool
    {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.speaker < rhs.speaker
    }
}
