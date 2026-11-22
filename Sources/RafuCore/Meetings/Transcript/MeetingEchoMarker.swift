import Foundation

/// The result of echo marking.
public struct MeetingEchoMarking: Hashable, Sendable {
    /// The same turns, in the same order, with the same ids and text. Only
    /// `isEcho` can differ.
    public var turns: [MeetingTurn]
    /// How many turns are echo (the interface says "Show 4 echo lines").
    public var echoCount: Int

    public init(turns: [MeetingTurn], echoCount: Int) {
        self.turns = turns
        self.echoCount = echoCount
    }
}

/// Marks the "Me" turns that are the far side heard again through the
/// microphone. On the built-in speakers the microphone hears the far side
/// about 30 ms later, so the same text is in both tracks.
///
/// A mark sets `isEcho` and nothing else: no text is removed or changed and no
/// turn is deleted. The interface hides a marked turn until the user asks to
/// see it.
public enum MeetingEchoMarker {
    /// A "Me" turn is a candidate when a "Them" turn starts within this many
    /// seconds of the start of the "Me" turn (`them.start - me.start`). The
    /// lower bound is negative: the "Them" turn starts a little before.
    public static let themStartWindow: ClosedRange<TimeInterval> = -0.3...2.0
    /// At least this percentage of the normalised "Me" words must be in the
    /// "Them" turn, in the same order.
    public static let minimumMatchPercent = 80
    /// A shorter "Me" turn is never an echo ("yes" is a real answer).
    public static let minimumWordCount = 3

    /// - Parameter outputWasSpeakers: false for headphones. Then there is no
    ///   echo and the marker changes nothing.
    public static func mark(
        _ turns: [MeetingTurn], outputWasSpeakers: Bool
    ) -> MeetingEchoMarking {
        guard outputWasSpeakers else {
            return MeetingEchoMarking(turns: turns, echoCount: turns.filter(\.isEcho).count)
        }

        let themTurns = turns.filter { $0.track == .them }.map {
            (start: $0.start, words: normalisedWords($0.text))
        }
        var result = turns
        for index in result.indices where result[index].track == .me && !result[index].isEcho {
            let meWords = normalisedWords(result[index].text)
            guard meWords.count >= minimumWordCount else { continue }
            let start = result[index].start
            let isEcho = themTurns.contains { them in
                themStartWindow.contains(them.start - start) && matches(meWords, in: them.words)
            }
            if isEcho { result[index].isEcho = true }
        }
        return MeetingEchoMarking(turns: result, echoCount: result.filter(\.isEcho).count)
    }

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

    private static func matches(_ me: [String], in them: [String]) -> Bool {
        guard !me.isEmpty, !them.isEmpty else { return false }
        let common = longestCommonSubsequence(me, them)
        return common * 100 >= me.count * minimumMatchPercent
    }

    /// The length of the longest common subsequence (same order, gaps allowed).
    static func longestCommonSubsequence(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = previous
        for left in lhs {
            for (column, right) in rhs.enumerated() {
                current[column + 1] =
                    left == right
                    ? previous[column] + 1
                    : max(previous[column + 1], current[column])
            }
            swap(&previous, &current)
            current[0] = 0
        }
        return previous[rhs.count]
    }
}
