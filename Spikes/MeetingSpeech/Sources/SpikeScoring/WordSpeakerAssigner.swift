// Gives each word the speaker with the most time overlap. This is the
// candidate for Rafu's own "word to speaker by most time overlap" function
// (plan section 5.3). Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.

public enum WordSpeakerAssigner {
    /// Assigns each word the speaker label of the segment it overlaps the
    /// most, by duration. A word with zero duration (start == end) is
    /// treated as a point and matched against any segment containing that
    /// point. A word with no overlapping segment keeps its existing
    /// `speaker` value (unchanged).
    public static func assign(words: [TimedWord], segments: [DiarSegment]) -> [TimedWord] {
        guard !segments.isEmpty else { return words }
        return words.map { word in
            var byspeaker: [String: Double] = [:]
            for segment in segments {
                let overlap = overlapSeconds(wordStart: word.start, wordEnd: word.end, segment: segment)
                if overlap > 0 {
                    byspeaker[segment.speaker, default: 0] += overlap
                }
            }
            guard let best = byspeaker.max(by: { $0.value < $1.value }) else {
                return word
            }
            var updated = word
            updated.speaker = best.key
            return updated
        }
    }

    private static func overlapSeconds(wordStart: Double, wordEnd: Double, segment: DiarSegment) -> Double {
        if wordStart == wordEnd {
            return (segment.start <= wordStart && wordStart <= segment.end) ? 1 : 0
        }
        let start = max(wordStart, segment.start)
        let end = min(wordEnd, segment.end)
        return max(0, end - start)
    }
}
