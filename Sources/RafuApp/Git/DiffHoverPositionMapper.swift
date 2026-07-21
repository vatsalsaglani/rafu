import Foundation

/// Pure position math for Part B (new-side-only hover) of the
/// diff-syntax-highlighting-and-hover phase. Both functions are
/// self-contained and unit-tested independently — neither trusts
/// render-side state, so a bug in the diff canvas's row bookkeeping can
/// never silently corrupt a hover request.
nonisolated enum DiffHoverPositionMapper {
    /// The 1-based file line for a hovered new-side row: `hunk.newStart`
    /// advanced by the count of rows preceding `row` IN THAT HUNK that carry
    /// a `newLine` (context/addition/modification rows advance the new
    /// side; deletion-only rows do not). `GitDiffLine.number` already equals
    /// this by construction (`UnifiedDiffParser.align`) — this function
    /// exists to prove that equivalence independently in tests, deriving
    /// the line purely from the hunk rather than trusting `row.newLine?
    /// .number`.
    ///
    /// `nil` when `row` itself has no `newLine` (nothing to hover — this
    /// includes deletion-only rows) or `row` is not a member of `hunk`.
    /// Membership is checked by full `Equatable` value (id, lines, and kind)
    /// rather than `id` alone — `GitDiffRow.id` is only unique WITHIN one
    /// parsed diff (`UnifiedDiffParser` restarts its counter per diff), so
    /// an `id` match across two different diffs' hunks would be a false
    /// positive.
    static func newSideLocation(row: GitDiffRow, in hunk: GitDiffHunk) -> Int? {
        guard row.newLine != nil,
            let rowIndex = hunk.rows.firstIndex(of: row)
        else { return nil }
        let precedingNewLineCount = hunk.rows[..<rowIndex].count { $0.newLine != nil }
        return hunk.newStart + precedingNewLineCount
    }

    /// UTF-16 offset of `(line, utf16Column)` in a full-file text snapshot.
    /// `line` is 1-based, matching `GitDiffLine.number`; `utf16Column` is
    /// 0-based.
    ///
    /// Contract:
    /// - `nil` when `line` is below 1 or exceeds `text`'s line count — the
    ///   file changed since the diff was captured (or the snapshot
    ///   genuinely doesn't have that many lines), and hover suppresses
    ///   rather than guessing at a stale position.
    /// - `utf16Column` past the end of the line CLAMPS to the line's UTF-16
    ///   length (exclusive of its terminator) rather than declining — a
    ///   debounced pointer position can legitimately land past the last
    ///   character of a short line, and clamping there still resolves to a
    ///   sensible (if identifier-less) position instead of silently
    ///   dropping the hover.
    /// - Both `"\n"` and `"\r\n"` line endings are recognized; a line's
    ///   UTF-16 span excludes its terminator. A trailing newline at the end
    ///   of `text` yields one additional (empty) final line, matching
    ///   `RafuCore.LineColumnIndex`'s convention.
    static func utf16Offset(line: Int, utf16Column: Int, in text: String) -> Int? {
        guard line >= 1 else { return nil }

        let rawLines = text.components(separatedBy: "\n")
        guard line <= rawLines.count else { return nil }

        var offset = 0
        for index in 0..<(line - 1) {
            offset += (rawLines[index] as NSString).length + 1
        }

        var currentLine = rawLines[line - 1]
        if currentLine.hasSuffix("\r") {
            currentLine.removeLast()
        }
        let lineLength = (currentLine as NSString).length
        let clampedColumn = max(0, min(utf16Column, lineLength))
        return offset + clampedColumn
    }
}
