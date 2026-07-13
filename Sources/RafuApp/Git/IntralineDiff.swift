import Foundation

/// Computes the changed span between two versions of a line by trimming the
/// common prefix and suffix. Cheap (O(n)) and good enough for word-level diff
/// emphasis on modification rows.
nonisolated enum IntralineDiff {
    struct Spans: Sendable, Equatable {
        let old: Range<Int>
        let new: Range<Int>
    }

    static func changedSpans(old: String, new: String) -> Spans? {
        guard old != new else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
            oldChars[prefix] == newChars[prefix]
        {
            prefix += 1
        }

        var oldSuffix = oldChars.count
        var newSuffix = newChars.count
        while oldSuffix > prefix, newSuffix > prefix,
            oldChars[oldSuffix - 1] == newChars[newSuffix - 1]
        {
            oldSuffix -= 1
            newSuffix -= 1
        }

        return Spans(old: prefix..<oldSuffix, new: prefix..<newSuffix)
    }
}
