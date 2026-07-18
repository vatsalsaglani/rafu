import Foundation

/// Locates and bounds the single hunk a gutter change-strip click (or the
/// "Peek Change at Line" command) targets, sliced verbatim from an already
/// captured `GitFileDiff` — never a second `git diff` call. Pure and
/// side-effect-free.
nonisolated enum HunkPeekSlice {
    /// Hard cap on rows rendered in the hunk-peek popover (ADR 0013). A
    /// hunk larger than this truncates; the popover then shows a summary
    /// and only an "Open Full Diff" action.
    static let maximumRows = 200

    /// Finds the hunk in `diff` whose new-file line range contains
    /// `newLine` (a 1-based line number in the CURRENT, working-tree
    /// version of the file) and returns its rows capped at
    /// `maximumRows`, plus whether the hunk was truncated. Returns `nil`
    /// when no hunk covers `newLine`.
    static func slice(_ diff: GitFileDiff, atLine newLine: Int) -> (
        hunk: GitDiffHunk, rows: [GitDiffRow], isTruncated: Bool
    )? {
        guard
            let hunk = diff.hunks.first(where: { contains(newLine: newLine, in: $0) })
        else { return nil }
        guard hunk.rows.count > maximumRows else {
            return (hunk, hunk.rows, false)
        }
        return (hunk, Array(hunk.rows.prefix(maximumRows)), true)
    }

    /// A hunk with `newCount == 0` (a pure deletion with no surviving new
    /// lines) still "contains" its `newStart` line — that is the line after
    /// which the deletion occurs in the current file, and is exactly where a
    /// gutter deletion marker is drawn (see `EditorGutterRulerView`'s
    /// `deletedAfter` marker).
    private static func contains(newLine: Int, in hunk: GitDiffHunk) -> Bool {
        let span = max(hunk.newCount, 1)
        return newLine >= hunk.newStart && newLine < hunk.newStart + span
    }
}
