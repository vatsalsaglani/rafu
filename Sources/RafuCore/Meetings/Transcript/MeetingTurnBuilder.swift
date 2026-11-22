import Foundation

/// Builds the turns of a meeting from the two word streams and the speaker
/// segments of the "Them" track.
///
/// A new turn starts at a speaker change or at a pause of
/// `MeetingTurnRules.pauseSeconds` inside one track. Turns never merge across
/// tracks: two people who talk at the same time give two turns. Words are
/// grouped per track first and the turns are then ordered by start time, so
/// overlapped speech does not cut a long sentence into one-word turns.
///
/// Ids are numbers from `firstTurnNumber` in the order of the turns. The order
/// is a total order of the input, so a second build of the same input gives the
/// same ids. An edit, a rename or an echo mark works on the built turns and
/// never changes an id.
public enum MeetingTurnBuilder {
    public static func build(
        meWords: [MeetingWord],
        themWords: [MeetingWord],
        segments: [MeetingSpeakerSegment],
        firstTurnNumber: Int = 1
    ) -> [MeetingTurn] {
        let me = meWords.filter(\.isUsable).map {
            MeetingAttributedWord(word: $0, track: .me, speaker: .me)
        }
        let them = MeetingWordSpeakerAssigner.assign(
            themWords: themWords.filter(\.isUsable), segments: segments)

        var drafts = draftTurns(from: me)
        drafts += draftTurns(from: them)
        drafts.sort(by: Draft.order)

        return drafts.enumerated().map { index, draft in
            MeetingTurn(
                id: MeetingTurnID(firstTurnNumber + index),
                track: draft.track,
                speaker: draft.speaker,
                start: draft.start,
                end: draft.end,
                text: draft.texts.joined(separator: " "))
        }
    }

    private struct Draft {
        var track: MeetingTrack
        var speaker: MeetingSpeakerLabel
        var start: TimeInterval
        var end: TimeInterval
        var texts: [String]

        static func order(_ lhs: Draft, _ rhs: Draft) -> Bool {
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.track != rhs.track { return lhs.track == .me }
            if lhs.speaker.storageKey != rhs.speaker.storageKey {
                return lhs.speaker.storageKey < rhs.speaker.storageKey
            }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.texts.joined(separator: " ") < rhs.texts.joined(separator: " ")
        }
    }

    /// Cuts the words of one track into turns.
    private static func draftTurns(from words: [MeetingAttributedWord]) -> [Draft] {
        let sorted = words.sorted { MeetingWord.clockOrder($0.word, $1.word) }
        var drafts: [Draft] = []
        for item in sorted {
            let text = item.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if var current = drafts.last,
                current.speaker == item.speaker,
                !MeetingTurnRules.isPause(gap: item.word.start - current.end)
            {
                current.end = max(current.end, item.word.end)
                current.texts.append(text)
                drafts[drafts.count - 1] = current
            } else {
                drafts.append(
                    Draft(
                        track: item.track, speaker: item.speaker, start: item.word.start,
                        end: max(item.word.start, item.word.end), texts: [text]))
            }
        }
        return drafts
    }
}
