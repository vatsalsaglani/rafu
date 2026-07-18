import Foundation
import Testing

@testable import RafuApp

@Suite("Hunk peek slice")
struct HunkPeekSliceTests {
    private func row(id: Int, newLine: Int?, oldLine: Int?, kind: GitDiffRowKind) -> GitDiffRow {
        GitDiffRow(
            id: id,
            oldLine: oldLine.map { GitDiffLine(number: $0, content: "old\($0)", kind: .context) },
            newLine: newLine.map { GitDiffLine(number: $0, content: "new\($0)", kind: .context) },
            kind: kind
        )
    }

    private func hunk(
        id: Int, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, rowCount: Int
    ) -> GitDiffHunk {
        let rows = (0..<rowCount).map { offset in
            row(id: offset, newLine: newStart + offset, oldLine: oldStart + offset, kind: .context)
        }
        return GitDiffHunk(
            id: id,
            header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
            oldStart: oldStart, oldCount: oldCount,
            newStart: newStart, newCount: newCount,
            rows: rows
        )
    }

    private func diff(hunks: [GitDiffHunk]) -> GitFileDiff {
        GitFileDiff(
            path: "file.swift", originalPath: nil, isBinary: false, hunks: hunks, rawPatch: "")
    }

    @Test("Slices the hunk whose new-line range contains the target line")
    func findsContainingHunk() {
        let first = hunk(id: 0, oldStart: 1, oldCount: 5, newStart: 1, newCount: 5, rowCount: 5)
        let second = hunk(id: 1, oldStart: 20, oldCount: 5, newStart: 22, newCount: 5, rowCount: 5)
        let result = HunkPeekSlice.slice(diff(hunks: [first, second]), atLine: 24)
        #expect(result?.hunk.id == 1)
        #expect(result?.isTruncated == false)
        #expect(result?.rows.count == 5)
    }

    @Test("Returns nil when no hunk covers the line")
    func noHunkAtLine() {
        let first = hunk(id: 0, oldStart: 1, oldCount: 5, newStart: 1, newCount: 5, rowCount: 5)
        let result = HunkPeekSlice.slice(diff(hunks: [first]), atLine: 100)
        #expect(result == nil)
    }

    @Test("Matches the first hunk when the line lands exactly at its start")
    func matchesFirstHunkAtStart() {
        let first = hunk(id: 0, oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, rowCount: 3)
        let second = hunk(id: 1, oldStart: 10, oldCount: 3, newStart: 10, newCount: 3, rowCount: 3)
        let result = HunkPeekSlice.slice(diff(hunks: [first, second]), atLine: 1)
        #expect(result?.hunk.id == 0)
    }

    @Test("Matches the last hunk when the line lands at its final row")
    func matchesLastHunkAtEnd() {
        let first = hunk(id: 0, oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, rowCount: 3)
        let second = hunk(id: 1, oldStart: 10, oldCount: 4, newStart: 10, newCount: 4, rowCount: 4)
        let result = HunkPeekSlice.slice(diff(hunks: [first, second]), atLine: 13)
        #expect(result?.hunk.id == 1)
    }

    @Test("Exactly 200 rows is not truncated")
    func boundaryNotTruncated() {
        let full = hunk(
            id: 0, oldStart: 1, oldCount: 200, newStart: 1, newCount: 200, rowCount: 200)
        let result = HunkPeekSlice.slice(diff(hunks: [full]), atLine: 1)
        #expect(result?.rows.count == 200)
        #expect(result?.isTruncated == false)
    }

    @Test("201 rows truncates to exactly 200")
    func boundaryTruncated() {
        let big = hunk(id: 0, oldStart: 1, oldCount: 201, newStart: 1, newCount: 201, rowCount: 201)
        let result = HunkPeekSlice.slice(diff(hunks: [big]), atLine: 1)
        #expect(result?.rows.count == 200)
        #expect(result?.isTruncated == true)
    }

    @Test("A pure-deletion hunk (newCount 0) still matches at its newStart line")
    func pureDeletionHunkMatches() {
        let deletion = hunk(id: 0, oldStart: 5, oldCount: 3, newStart: 4, newCount: 0, rowCount: 3)
        let result = HunkPeekSlice.slice(diff(hunks: [deletion]), atLine: 4)
        #expect(result?.hunk.id == 0)
    }

    @Test("An empty diff never crashes and returns nil")
    func emptyDiffReturnsNil() {
        #expect(HunkPeekSlice.slice(diff(hunks: []), atLine: 1) == nil)
    }
}
