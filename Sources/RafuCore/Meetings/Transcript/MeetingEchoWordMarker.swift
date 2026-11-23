import Foundation

/// Marks each "Me" word that is the far side heard again through the
/// microphone. On the built-in speakers the microphone hears the far side a
/// little later, so the same words are in both tracks at about the same time.
///
/// The rule works per word, not per turn: one turn of the microphone track
/// often holds echo and real speech together, and an echo can start many
/// seconds after the far turn started. There is no energy test: in a real
/// call the echo was as loud as the user.
///
/// 1. Headphones (`outputWasSpeakers == false`) or no "Them" words: no echo.
/// 2. A "Me" word matches one unused "Them" word with the same normalised
///    text whose start is at most `matchSeconds` away; the nearest in time
///    wins, a tie goes to the earlier one. Each "Them" word matches once.
/// 3. A stretch is a run of "Me" words with no pause
///    (`MeetingTurnRules.isPause`). A stretch of fewer than
///    `minimumStretchWords` words is never echo ("yes sure" is an answer).
/// 4. Density: the share of matched words in the words `i-3...i+3` of the
///    same stretch. A matched word is echo at `matchedDensity` or more; an
///    unmatched word is echo at `unmatchedDensity` or more.
/// 5. A run of at most `maximumIslandWords` non-echo words with echo words
///    on both sides in the same stretch is echo too.
///
/// A mark hides nothing by itself and removes no text: the turn builder
/// puts echo words in echo turns, which the interface hides until the user
/// asks to see them.
public enum MeetingEchoWordMarker {
    /// The largest distance between the start of a "Me" word and the start
    /// of the "Them" word it matches.
    public static let matchSeconds: TimeInterval = 1.5
    /// A shorter stretch is never echo.
    public static let minimumStretchWords = 3
    /// The words on each side of a word that the density counts.
    public static let densityRadius = 3
    /// A matched word is echo when at least this share of its neighbourhood
    /// is matched.
    public static let matchedDensity = 0.5
    /// An unmatched word is echo when at least this share of its
    /// neighbourhood is matched.
    public static let unmatchedDensity = 0.6
    /// The longest run of non-echo words between echo words that becomes
    /// echo.
    public static let maximumIslandWords = 2

    /// - Returns: one flag per word of `meWords`, in the order of `meWords`.
    public static func mark(
        meWords: [MeetingWord], themWords: [MeetingWord], outputWasSpeakers: Bool
    ) -> [Bool] {
        var result = [Bool](repeating: false, count: meWords.count)
        guard outputWasSpeakers, !meWords.isEmpty, !themWords.isEmpty else { return result }

        let order = meWords.indices.sorted { MeetingWord.clockOrder(meWords[$0], meWords[$1]) }
        let sortedMe = order.map { meWords[$0] }
        let matched = matches(meWords: sortedMe, themWords: themWords)

        var flags = [Bool](repeating: false, count: sortedMe.count)
        for stretch in stretches(sortedMe) where stretch.count >= minimumStretchWords {
            markStretch(stretch, matched: matched, flags: &flags)
        }
        for (sortedIndex, inputIndex) in order.enumerated() {
            result[inputIndex] = flags[sortedIndex]
        }
        return result
    }

    /// Step 2: one flag per word of `meWords` (already in clock order), true
    /// when the word matches a "Them" word.
    static func matches(meWords: [MeetingWord], themWords: [MeetingWord]) -> [Bool] {
        // The "Them" starts per normalised text, in clock order.
        var themByKey: [String: [(start: TimeInterval, used: Bool)]] = [:]
        for word in themWords.sorted(by: MeetingWord.clockOrder) {
            guard let key = key(word.text) else { continue }
            themByKey[key, default: []].append((word.start, false))
        }

        var result = [Bool](repeating: false, count: meWords.count)
        for (index, word) in meWords.enumerated() {
            guard let key = key(word.text), var candidates = themByKey[key] else { continue }
            let lowest = word.start - matchSeconds - MeetingTurnRules.tolerance
            let highest = word.start + matchSeconds + MeetingTurnRules.tolerance
            var best: Int?
            var bestDistance = TimeInterval.infinity
            var position = firstIndex(in: candidates, notBefore: lowest)
            while position < candidates.count, candidates[position].start <= highest {
                let candidate = candidates[position]
                let distance = abs(candidate.start - word.start)
                // Strictly nearer only: at equal distance the earlier stays.
                if !candidate.used, distance < bestDistance {
                    best = position
                    bestDistance = distance
                }
                position += 1
            }
            if let best {
                candidates[best].used = true
                themByKey[key] = candidates
                result[index] = true
            }
        }
        return result
    }

    /// The normalised text of one word, or nil when nothing is left.
    private static func key(_ text: String) -> String? {
        let key = MeetingEchoMarker.normalisedWords(text).joined()
        return key.isEmpty ? nil : key
    }

    /// The first position with a start at or after `time` (binary search).
    private static func firstIndex(
        in candidates: [(start: TimeInterval, used: Bool)], notBefore time: TimeInterval
    ) -> Int {
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle].start < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Step 3: the index ranges of the runs of words with no pause.
    private static func stretches(_ words: [MeetingWord]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        var end = -TimeInterval.infinity
        for (index, word) in words.enumerated() {
            if index > 0, MeetingTurnRules.isPause(gap: word.start - end) {
                result.append(start..<index)
                start = index
            }
            end = max(end, MeetingTurnRules.effectiveEnd(of: word))
        }
        result.append(start..<words.count)
        return result
    }

    /// Steps 4 and 5 for one stretch.
    private static func markStretch(
        _ stretch: Range<Int>, matched: [Bool], flags: inout [Bool]
    ) {
        for index in stretch {
            let window =
                max(
                    stretch.lowerBound, index - densityRadius)...min(
                    stretch.upperBound - 1, index + densityRadius)
            let count = window.filter { matched[$0] }.count
            let density = Double(count) / Double(window.count)
            flags[index] =
                matched[index] ? density >= matchedDensity : density >= unmatchedDensity
        }

        // Islands: a short non-echo run with echo on both sides.
        var index = stretch.lowerBound
        while index < stretch.upperBound {
            guard !flags[index] else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < stretch.upperBound, !flags[runEnd] { runEnd += 1 }
            let echoBefore = index > stretch.lowerBound
            let echoAfter = runEnd < stretch.upperBound
            if echoBefore, echoAfter, runEnd - index <= maximumIslandWords {
                for island in index..<runEnd { flags[island] = true }
            }
            index = runEnd
        }
    }
}
