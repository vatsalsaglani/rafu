import Foundation

/// Per-buffer Git gutter markers expressed in 1-based new-file line numbers.
nonisolated struct GitGutterLineChanges: Equatable, Sendable {
    var added: [ClosedRange<Int>] = []
    var modified: [ClosedRange<Int>] = []
    /// New-file line numbers after which lines were deleted. `0` means lines
    /// were deleted before the first line.
    var deletedAfter: [Int] = []

    static let empty = GitGutterLineChanges()

    static func allAdded(lineCount: Int) -> GitGutterLineChanges {
        GitGutterLineChanges(added: lineCount > 0 ? [1...lineCount] : [])
    }

    var isEmpty: Bool { added.isEmpty && modified.isEmpty && deletedAfter.isEmpty }
}

/// Parses `git diff --unified=0` hunk headers only; body lines are ignored.
/// `@@ -a,b +c,d @@` with `b == 0` marks pure additions, `d == 0` marks a
/// deletion after new-file line `c`, anything else marks modified lines.
nonisolated enum GitGutterHunkParser {
    static func parse(_ patch: String) -> GitGutterLineChanges {
        var changes = GitGutterLineChanges()
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("@@ ") else { continue }
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                let old = parseRange(fields[1], expectedSign: "-"),
                let new = parseRange(fields[2], expectedSign: "+")
            else { continue }

            if old.count == 0 {
                if new.count > 0 { changes.added.append(new.start...(new.start + new.count - 1)) }
            } else if new.count == 0 {
                changes.deletedAfter.append(new.start)
            } else {
                changes.modified.append(new.start...(new.start + new.count - 1))
            }
        }
        return changes
    }

    private static func parseRange(
        _ field: Substring,
        expectedSign: Character
    ) -> (start: Int, count: Int)? {
        guard field.first == expectedSign else { return nil }
        let body = field.dropFirst()
        let parts = body.split(separator: ",", maxSplits: 1)
        guard let first = parts.first, let start = Int(first), start >= 0 else { return nil }
        // A missing count means one line.
        let count = parts.count > 1 ? Int(parts[1]) : 1
        guard let count, count >= 0 else { return nil }
        return (start, count)
    }
}
