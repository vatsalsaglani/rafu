// Word error rate: lower-case, punctuation removed, then edit distance on
// words. Throw-away spike code; see .rafu/plans/meeting-speech-spike.md.
import Foundation

public struct WordErrorResult: Sendable, Equatable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWordCount: Int

    /// (substitutions + deletions + insertions) / referenceWordCount.
    /// 0.0 when the reference has no words and the hypothesis also has none.
    public var errorRate: Double {
        guard referenceWordCount > 0 else {
            return (substitutions + deletions + insertions) == 0 ? 0.0 : 1.0
        }
        return Double(substitutions + deletions + insertions) / Double(referenceWordCount)
    }
}

public enum WordErrorRate {
    /// Lower-case, strip punctuation (keep letters, digits and internal
    /// apostrophes), collapse whitespace, split into words.
    public static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" && !current.isEmpty {
                // keep internal apostrophes ("don't"); dropped if trailing below
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty {
                    words.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            words.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        }
        return words.filter { !$0.isEmpty }
    }

    public static func score(reference: String, hypothesis: String) -> WordErrorResult {
        score(referenceWords: normalize(reference), hypothesisWords: normalize(hypothesis))
    }

    /// Standard Levenshtein edit distance on word sequences, with a
    /// backtrace that attributes each edit to a substitution, a deletion
    /// (a reference word with no counterpart) or an insertion (a
    /// hypothesis word with no counterpart). Ties prefer, in order: match,
    /// substitution, deletion, insertion — the usual scoring convention.
    public static func score(referenceWords: [String], hypothesisWords: [String]) -> WordErrorResult {
        let r = referenceWords
        let h = hypothesisWords
        let n = r.count
        let m = h.count

        if n == 0 {
            return WordErrorResult(substitutions: 0, deletions: 0, insertions: m, referenceWordCount: 0)
        }
        if m == 0 {
            return WordErrorResult(substitutions: 0, deletions: n, insertions: 0, referenceWordCount: n)
        }

        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if r[i - 1] == h[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                } else {
                    let sub = cost[i - 1][j - 1] + 1
                    let del = cost[i - 1][j] + 1
                    let ins = cost[i][j - 1] + 1
                    cost[i][j] = min(sub, del, ins)
                }
            }
        }

        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && r[i - 1] == h[j - 1] && cost[i][j] == cost[i - 1][j - 1] {
                i -= 1
                j -= 1
                continue
            }
            if i > 0 && j > 0 && cost[i][j] == cost[i - 1][j - 1] + 1 {
                substitutions += 1
                i -= 1
                j -= 1
                continue
            }
            if i > 0 && cost[i][j] == cost[i - 1][j] + 1 {
                deletions += 1
                i -= 1
                continue
            }
            if j > 0 && cost[i][j] == cost[i][j - 1] + 1 {
                insertions += 1
                j -= 1
                continue
            }
            // Unreachable for a correctly built matrix; guard against an
            // infinite loop if it ever is.
            break
        }

        return WordErrorResult(
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            referenceWordCount: n
        )
    }
}
