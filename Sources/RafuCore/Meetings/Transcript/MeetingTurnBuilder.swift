import Foundation

/// Builds the turns of a meeting from the two word streams and the speaker
/// segments of the "Them" track.
///
/// A new turn starts at a speaker change, at a change between echo and real
/// "Me" words, or at a time rule of `MeetingTurnRules.startsNewTurn` (a
/// pause, a long turn at a sentence end or short gap, the longest turn).
/// Turns never merge across tracks: two people who talk at the same time give
/// two turns. Words are grouped per track first and the turns are then
/// ordered by start time, so overlapped speech does not cut a long sentence
/// into one-word turns.
///
/// Ids are numbers from `firstTurnNumber` in the order of the turns. The order
/// is a total order of the input, so a second build of the same input gives the
/// same ids. An edit or a rename works on the built turns and never changes an
/// id.
public enum MeetingTurnBuilder {
    /// - Parameter outputWasSpeakers: true when the call played on the
    ///   built-in speakers; then "Me" words that repeat "Them" words are
    ///   echo (`MeetingEchoWordMarker`). False marks no echo.
    public static func build(
        meWords: [MeetingWord],
        themWords: [MeetingWord],
        segments: [MeetingSpeakerSegment],
        firstTurnNumber: Int = 1,
        outputWasSpeakers: Bool = false
    ) -> [MeetingTurn] {
        let usableMe = meWords.filter(\.isUsable)
        let usableThem = themWords.filter(\.isUsable)
        let echo = MeetingEchoWordMarker.mark(
            meWords: usableMe, themWords: usableThem, outputWasSpeakers: outputWasSpeakers)
        let me = zip(usableMe, echo).map {
            MeetingAttributedWord(word: $0, track: .me, speaker: .me, isEcho: $1)
        }
        let them = MeetingWordSpeakerAssigner.assign(themWords: usableThem, segments: segments)

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
                text: draft.texts.joined(separator: " "),
                isEcho: draft.isEcho,
                speechSeconds: draft.speechSeconds)
        }
    }

    private struct Draft {
        var track: MeetingTrack
        var speaker: MeetingSpeakerLabel
        var isEcho: Bool
        var start: TimeInterval
        /// The effective end (`MeetingTurnRules.effectiveEnd`) of the last word.
        var end: TimeInterval
        var speechSeconds: TimeInterval
        var texts: [String]

        static func order(_ lhs: Draft, _ rhs: Draft) -> Bool {
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.track != rhs.track { return lhs.track == .me }
            if lhs.speaker.storageKey != rhs.speaker.storageKey {
                return lhs.speaker.storageKey < rhs.speaker.storageKey
            }
            if lhs.isEcho != rhs.isEcho { return !lhs.isEcho }
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
            let wordEnd = MeetingTurnRules.effectiveEnd(of: item.word)
            let wordSpeech = MeetingTurnRules.speechSeconds(of: item.word)
            if var current = drafts.last,
                current.speaker == item.speaker,
                current.isEcho == item.isEcho,
                !MeetingTurnRules.startsNewTurn(
                    turnStart: current.start, turnEnd: current.end,
                    lastText: current.texts.last ?? "", nextStart: item.word.start,
                    nextEnd: wordEnd)
            {
                current.end = max(current.end, wordEnd)
                current.speechSeconds += wordSpeech
                current.texts.append(text)
                drafts[drafts.count - 1] = current
            } else {
                drafts.append(
                    Draft(
                        track: item.track, speaker: item.speaker, isEcho: item.isEcho,
                        start: item.word.start, end: wordEnd, speechSeconds: wordSpeech,
                        texts: [text]))
            }
        }
        return drafts
    }
}
