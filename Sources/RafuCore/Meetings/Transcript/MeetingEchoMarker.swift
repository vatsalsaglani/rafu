import Foundation

/// The turns of a meeting with the echo marks.
public struct MeetingEchoMarking: Hashable, Sendable {
    /// The turns in id order. An echo turn holds only echo words and has
    /// `isEcho == true`; no word is removed.
    public var turns: [MeetingTurn]
    /// How many turns are echo (the interface says "Show 4 echo lines").
    public var echoCount: Int

    public init(turns: [MeetingTurn], echoCount: Int) {
        self.turns = turns
        self.echoCount = echoCount
    }
}

/// Text rules shared by the echo marks. The marks themselves are per word:
/// see `MeetingEchoWordMarker`. The turn builder puts echo words in echo
/// turns, and `MeetingTranscriptAssembly` counts them.
public enum MeetingEchoMarker {
    /// Lower case, no accents, no punctuation; empty words are dropped.
    static func normalisedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let folded = String(piece).folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let kept = String(
                String.UnicodeScalarView(
                    folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
            return kept.isEmpty ? nil : kept
        }
    }
}
