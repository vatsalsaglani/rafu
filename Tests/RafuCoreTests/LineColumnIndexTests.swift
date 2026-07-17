import RafuCore
import Testing

@Suite("Line/column → UTF-16 offset index")
struct LineColumnIndexTests {
    @Test("First line, no column, selects the start of the text")
    func firstLineNoColumn() {
        let text = "alpha\nbeta\ngamma"
        #expect(LineColumnIndex.utf16Offset(line: 1, column: nil, in: text) == 0)
    }

    @Test("A middle line's start offset lands right after its LF terminator")
    func middleLineStart() {
        let text = "alpha\nbeta\ngamma"
        #expect(LineColumnIndex.utf16Offset(line: 2, column: 1, in: text) == 6)
        #expect(LineColumnIndex.utf16Offset(line: 3, column: 1, in: text) == 11)
    }

    @Test("Column offsets within a line count UTF-16 units from its start")
    func columnWithinLine() {
        let text = "alpha\nbeta\ngamma"
        // "beta" starts at offset 6; column 3 selects the 't'.
        #expect(LineColumnIndex.utf16Offset(line: 2, column: 3, in: text) == 8)
    }

    @Test("CRLF line endings exclude the trailing CR from the line's span")
    func crlfLineEndings() {
        let text = "alpha\r\nbeta\r\ngamma"
        // "beta" still starts right after the CRLF pair, at offset 7.
        #expect(LineColumnIndex.utf16Offset(line: 2, column: 1, in: text) == 7)
        // Column past "beta"'s 4 characters clamps to the line's end (CR
        // excluded), not into the terminator.
        #expect(LineColumnIndex.utf16Offset(line: 2, column: 99, in: text) == 11)
    }

    @Test("A line beyond the text's last line clamps to the last line's start")
    func lineBeyondEndClamps() {
        let text = "alpha\nbeta"
        #expect(LineColumnIndex.utf16Offset(line: 99, column: 1, in: text) == 6)
    }

    @Test("A non-positive line clamps to the first line")
    func nonPositiveLineClamps() {
        let text = "alpha\nbeta"
        #expect(LineColumnIndex.utf16Offset(line: 0, column: 1, in: text) == 0)
        #expect(LineColumnIndex.utf16Offset(line: -5, column: 1, in: text) == 0)
    }

    @Test("A column past the line's end clamps to that line's end")
    func columnPastLineEndClamps() {
        let text = "alpha\nbeta\ngamma"
        // "alpha" is 5 UTF-16 units long.
        #expect(LineColumnIndex.utf16Offset(line: 1, column: 999, in: text) == 5)
    }

    @Test("A non-positive column clamps to the line's start")
    func nonPositiveColumnClamps() {
        let text = "alpha\nbeta"
        #expect(LineColumnIndex.utf16Offset(line: 2, column: 0, in: text) == 6)
        #expect(LineColumnIndex.utf16Offset(line: 2, column: -3, in: text) == 6)
    }

    @Test("Empty text always resolves to offset 0")
    func emptyText() {
        #expect(LineColumnIndex.utf16Offset(line: 1, column: 1, in: "") == 0)
        #expect(LineColumnIndex.utf16Offset(line: 5, column: 5, in: "") == 0)
    }

    @Test("A trailing newline creates one final empty line")
    func trailingNewlineCreatesEmptyLastLine() {
        let text = "alpha\nbeta\n"
        // Offsets: "alpha" [0,5), "beta" [6,10), trailing empty line [11,11).
        #expect(LineColumnIndex.utf16Offset(line: 3, column: 1, in: text) == 11)
    }
}
