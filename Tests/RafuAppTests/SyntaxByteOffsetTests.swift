import Foundation
import SwiftTreeSitter
import Testing

@testable import RafuApp

/// Pure UTF-16 ↔ tree-sitter offset/point conversions (lane-1 increment 8a).
/// The `Point` conversion is what incremental reparsing (8b) will build on, so
/// its ASCII/astral/CRLF/EOF/empty behavior is pinned now.

@Test("byteOffset doubles the UTF-16 offset")
func byteOffsetDoublesUTF16Offset() {
    #expect(SyntaxByteOffset.byteOffset(forUTF16Offset: 0) == 0)
    #expect(SyntaxByteOffset.byteOffset(forUTF16Offset: 1) == 2)
    #expect(SyntaxByteOffset.byteOffset(forUTF16Offset: 42) == 84)
}

@Test("point maps ASCII offsets to row and byte-column")
func pointMapsASCII() {
    let text = "abc\ndef"
    #expect(SyntaxByteOffset.point(forUTF16Offset: 0, in: text) == Point(row: 0, column: 0))
    #expect(SyntaxByteOffset.point(forUTF16Offset: 2, in: text) == Point(row: 0, column: 4))
    // Offset 4 is the first character after the newline at index 3.
    #expect(SyntaxByteOffset.point(forUTF16Offset: 4, in: text) == Point(row: 1, column: 0))
    #expect(SyntaxByteOffset.point(forUTF16Offset: 6, in: text) == Point(row: 1, column: 4))
}

@Test("point counts a surrogate pair as two UTF-16 units")
func pointHandlesAstralCharacters() {
    // "😀" is U+1F600 — two UTF-16 code units — then "x".
    let text = "😀x"
    #expect(SyntaxByteOffset.point(forUTF16Offset: 2, in: text) == Point(row: 0, column: 4))
    // Multi-line with an astral char before the newline.
    let multiline = "😀\ny"
    #expect(SyntaxByteOffset.point(forUTF16Offset: 3, in: multiline) == Point(row: 1, column: 0))
}

@Test("point counts rows by \\n only across CRLF line endings")
func pointHandlesCRLF() {
    let text = "a\r\nb"
    // The "\r" stays on row 0; only the "\n" (index 2) advances the row.
    #expect(SyntaxByteOffset.point(forUTF16Offset: 1, in: text) == Point(row: 0, column: 2))
    #expect(SyntaxByteOffset.point(forUTF16Offset: 3, in: text) == Point(row: 1, column: 0))
}

@Test("point clamps offsets at or beyond EOF")
func pointClampsAtEOF() {
    let text = "ab"
    #expect(SyntaxByteOffset.point(forUTF16Offset: 2, in: text) == Point(row: 0, column: 4))
    #expect(SyntaxByteOffset.point(forUTF16Offset: 99, in: text) == Point(row: 0, column: 4))
    #expect(SyntaxByteOffset.point(forUTF16Offset: -5, in: text) == Point(row: 0, column: 0))
}

@Test("point on empty text is the origin")
func pointOnEmptyText() {
    #expect(SyntaxByteOffset.point(forUTF16Offset: 0, in: "") == Point(row: 0, column: 0))
    #expect(SyntaxByteOffset.point(forUTF16Offset: 5, in: "") == Point(row: 0, column: 0))
}

// MARK: - InputEdit offset math (increment 8b)

/// The three UTF-16 offsets `NeonSyntaxHighlightingPipeline.enqueueEdit`
/// derives from the storage delegate's post-edit `editedRange`/`changeInLength`,
/// paired with the pre-/post-edit strings the actor uses for the `InputEdit`
/// byte offsets and points. These pin the arithmetic the incremental reparse
/// depends on for inserts, deletes, and multi-line replacements.
private struct EditOffsets {
    let startUTF16: Int
    let oldEndUTF16: Int
    let newEndUTF16: Int

    /// Mirrors `enqueueEdit`: `editedRange` is post-edit, `delta` is
    /// `changeInLength`, so the pre-edit end is `NSMaxRange - delta`.
    init(editedRange: NSRange, delta: Int) {
        startUTF16 = editedRange.location
        newEndUTF16 = editedRange.location + editedRange.length
        oldEndUTF16 = editedRange.location + editedRange.length - delta
    }
}

@Test("InputEdit offsets for a single-character insertion")
func inputEditOffsetsForInsertion() {
    // "abc" -> "abXc": insert "X" at index 2 (editedRange {2,1}, delta +1).
    let offsets = EditOffsets(editedRange: NSRange(location: 2, length: 1), delta: 1)
    #expect(offsets.startUTF16 == 2)
    #expect(offsets.oldEndUTF16 == 2)  // nothing was replaced
    #expect(offsets.newEndUTF16 == 3)

    let oldText = "abc"
    let newText = "abXc"
    #expect(
        SyntaxByteOffset.byteOffset(forUTF16Offset: offsets.startUTF16) == 4)
    #expect(
        SyntaxByteOffset.byteOffset(forUTF16Offset: offsets.newEndUTF16) == 6)
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.startUTF16, in: oldText)
            == Point(row: 0, column: 4))
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.oldEndUTF16, in: oldText)
            == Point(row: 0, column: 4))
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.newEndUTF16, in: newText)
            == Point(row: 0, column: 6))
}

@Test("InputEdit offsets for a single-character deletion")
func inputEditOffsetsForDeletion() {
    // "abXc" -> "abc": delete "X" at index 2 (editedRange {2,0}, delta -1).
    let offsets = EditOffsets(editedRange: NSRange(location: 2, length: 0), delta: -1)
    #expect(offsets.startUTF16 == 2)
    #expect(offsets.oldEndUTF16 == 3)  // one unit was removed
    #expect(offsets.newEndUTF16 == 2)

    let oldText = "abXc"
    let newText = "abc"
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.oldEndUTF16, in: oldText)
            == Point(row: 0, column: 6))
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.newEndUTF16, in: newText)
            == Point(row: 0, column: 4))
}

@Test("InputEdit offsets for a multi-line replacement need the pre-edit text")
func inputEditOffsetsForMultilineReplacement() {
    // "a\nbb\nc" -> "a\nX\nc": replace "bb" (index 2..<4) with "X".
    // editedRange is post-edit {2,1}; delta = 1 - 2 = -1.
    let oldText = "a\nbb\nc"
    let newText = "a\nX\nc"
    let offsets = EditOffsets(editedRange: NSRange(location: 2, length: 1), delta: -1)
    #expect(offsets.startUTF16 == 2)
    #expect(offsets.oldEndUTF16 == 4)
    #expect(offsets.newEndUTF16 == 3)

    // Start is the first character of line 1 (after the "\n" at index 1).
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.startUTF16, in: oldText)
            == Point(row: 1, column: 0))
    // oldEndPoint (offset 4) is still on line 1 in the PRE-edit text — the
    // post-edit string has no such structure, which is why the actor keeps it.
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.oldEndUTF16, in: oldText)
            == Point(row: 1, column: 4))
    // newEndPoint (offset 3) is on line 1 in the POST-edit text.
    #expect(
        SyntaxByteOffset.point(forUTF16Offset: offsets.newEndUTF16, in: newText)
            == Point(row: 1, column: 2))
}
