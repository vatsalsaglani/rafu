import Foundation

@testable import RafuCore

/// Builders for the transcript tests. Times are binary-exact (multiples of
/// 0.25) wherever a test sits on a threshold, so no rounding error decides.
enum MeetingTestWords {
    static func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> MeetingWord {
        MeetingWord(text: text, start: start, end: end)
    }

    /// One word per `step` seconds, each lasting `length`, from `start`.
    static func sentence(
        _ text: String, from start: TimeInterval, step: TimeInterval = 0.5,
        length: TimeInterval = 0.25
    ) -> [MeetingWord] {
        text.split(separator: " ").enumerated().map { index, piece in
            let wordStart = start + Double(index) * step
            return MeetingWord(text: String(piece), start: wordStart, end: wordStart + length)
        }
    }

    /// `count` anonymised words (`word0` ... `word12`, then again), one per
    /// 0.5 s, each 0.25 s long, from `start`.
    static func anonymous(_ count: Int, from start: TimeInterval, prefix: String = "word")
        -> [MeetingWord]
    {
        (0..<count).map { index in
            let wordStart = start + Double(index) * 0.5
            return MeetingWord(
                text: "\(prefix)\(index % 13)", start: wordStart, end: wordStart + 0.25)
        }
    }

    /// The same words `delay` seconds later, as the microphone hears the far
    /// side through the built-in speakers.
    static func heard(_ words: [MeetingWord], delay: TimeInterval = 0.25) -> [MeetingWord] {
        words.map { MeetingWord(text: $0.text, start: $0.start + delay, end: $0.end + delay) }
    }

    /// The same words, each ending at the start of the next (the shape of
    /// the Nemotron words).
    static func nemotronShape(_ words: [MeetingWord]) -> [MeetingWord] {
        words.enumerated().map { index, word in
            let end = index + 1 < words.count ? words[index + 1].start : word.end
            return MeetingWord(text: word.text, start: word.start, end: end)
        }
    }

    static func turn(
        _ number: Int, _ track: MeetingTrack, _ speaker: MeetingSpeakerLabel, _ start: TimeInterval,
        _ text: String, isEcho: Bool = false
    ) -> MeetingTurn {
        MeetingTurn(
            id: MeetingTurnID(number), track: track, speaker: speaker, start: start,
            end: start + 1, text: text, isEcho: isEcho)
    }
}
