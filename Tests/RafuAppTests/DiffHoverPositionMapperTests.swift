import Foundation
import Testing

@testable import RafuApp

/// Data-level proof for `DiffHoverPositionMapper` (diff-syntax-highlighting-
/// and-hover phase, Part B2): pure position math with no view/session
/// dependency. Fixtures use `UnifiedDiffParser.parse` so hunk/row shapes
/// match production exactly.
@Suite("DiffHoverPositionMapper")
struct DiffHoverPositionMapperTests {
    // MARK: - newSideLocation

    @Test(
        "newSideLocation: context, addition, and modification rows advance the new-side line and equal GitDiffLine.number across a multi-hunk diff"
    )
    func newSideLocationMatchesLineNumberAcrossHunks() throws {
        let patch = [
            "@@ -1,4 +1,3 @@",
            " context1",
            "-deletedOnly",
            "-oldModified",
            "+newModified",
            "@@ -10,1 +9,2 @@",
            " context2",
            "+addedOnly",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(path: "sample.txt", originalPath: nil, patch: patch)

        for hunk in diff.hunks {
            for row in hunk.rows where row.newLine != nil {
                let derived = DiffHoverPositionMapper.newSideLocation(row: row, in: hunk)
                #expect(derived == row.newLine?.number)
            }
        }

        // Sanity: at least one context, one modification, and one pure
        // addition row were actually exercised above.
        let kinds = Set(diff.rows.map(\.kind))
        #expect(kinds.isSuperset(of: [.context, .modification, .addition, .deletion]))
    }

    @Test("newSideLocation: an old-side deletion-only row returns nil")
    func newSideLocationNilForDeletionOnlyRow() throws {
        let patch = [
            "@@ -1,2 +1,1 @@",
            " context1",
            "-deletedOnly",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(path: "sample.txt", originalPath: nil, patch: patch)
        let hunk = try #require(diff.hunks.first)
        let deletionRow = try #require(hunk.rows.first { $0.kind == .deletion })

        #expect(deletionRow.newLine == nil)
        #expect(DiffHoverPositionMapper.newSideLocation(row: deletionRow, in: hunk) == nil)
    }

    @Test("newSideLocation: a row that is not a member of the given hunk returns nil")
    func newSideLocationNilForForeignRow() throws {
        let patchA = ["@@ -1,1 +1,1 @@", " onlyLine", ""].joined(separator: "\n")
        let patchB = ["@@ -1,1 +1,1 @@", " otherLine", ""].joined(separator: "\n")
        let diffA = UnifiedDiffParser.parse(path: "a.txt", originalPath: nil, patch: patchA)
        let diffB = UnifiedDiffParser.parse(path: "b.txt", originalPath: nil, patch: patchB)
        let foreignRow = try #require(diffB.hunks.first?.rows.first)
        let hunk = try #require(diffA.hunks.first)

        #expect(DiffHoverPositionMapper.newSideLocation(row: foreignRow, in: hunk) == nil)
    }

    // MARK: - utf16Offset

    @Test("utf16Offset: maps (line, column) correctly across multi-byte lines")
    func utf16OffsetMapsMultiByteLinesCorrectly() {
        let text = "line one\n\u{1F600} caf\u{00E9}\nline three"
        // Line 1 = "line one" (8 UTF-16 units), line 2 starts at 9.
        #expect(DiffHoverPositionMapper.utf16Offset(line: 1, utf16Column: 0, in: text) == 0)
        #expect(DiffHoverPositionMapper.utf16Offset(line: 1, utf16Column: 4, in: text) == 4)
        #expect(DiffHoverPositionMapper.utf16Offset(line: 2, utf16Column: 0, in: text) == 9)
        // Column 2 on line 2 lands right after the emoji (2 UTF-16 units) at
        // the space before "café".
        #expect(DiffHoverPositionMapper.utf16Offset(line: 2, utf16Column: 2, in: text) == 11)
        let line3Start = 9 + ("\u{1F600} caf\u{00E9}" as NSString).length + 1
        #expect(
            DiffHoverPositionMapper.utf16Offset(line: 3, utf16Column: 0, in: text) == line3Start)
    }

    @Test("utf16Offset: a column past end-of-line clamps to the line's UTF-16 length")
    func utf16OffsetClampsColumnPastEndOfLine() {
        let text = "abc\nde"
        #expect(DiffHoverPositionMapper.utf16Offset(line: 1, utf16Column: 999, in: text) == 3)
        #expect(DiffHoverPositionMapper.utf16Offset(line: 1, utf16Column: -5, in: text) == 0)
        #expect(DiffHoverPositionMapper.utf16Offset(line: 2, utf16Column: 999, in: text) == 6)
    }

    @Test("utf16Offset: a line beyond the snapshot's line count returns nil")
    func utf16OffsetNilBeyondSnapshotLineCount() {
        let text = "only one line"
        #expect(DiffHoverPositionMapper.utf16Offset(line: 2, utf16Column: 0, in: text) == nil)
        #expect(DiffHoverPositionMapper.utf16Offset(line: 0, utf16Column: 0, in: text) == nil)
        #expect(DiffHoverPositionMapper.utf16Offset(line: -1, utf16Column: 0, in: text) == nil)
    }
}
