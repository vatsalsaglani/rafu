import Foundation
import Testing

@testable import RafuApp

@Test("Single-line ASCII: utf16 and utf8 characters agree")
func positionEncodingSingleLineASCII() {
    let mirror = DocumentTextMirror(text: "let x = 1")
    #expect(mirror.position(forUTF16Offset: 0, encoding: .utf16) == Position(line: 0, character: 0))
    #expect(mirror.position(forUTF16Offset: 4, encoding: .utf16) == Position(line: 0, character: 4))
    #expect(mirror.position(forUTF16Offset: 4, encoding: .utf8) == Position(line: 0, character: 4))
    #expect(
        mirror.utf16Offset(for: Position(line: 0, character: 4), encoding: .utf16) == 4)
    #expect(
        mirror.utf16Offset(for: Position(line: 0, character: 4), encoding: .utf8) == 4)
}

@Test("Multi-line text: line/character track across \\n boundaries")
func positionEncodingMultiLine() {
    let mirror = DocumentTextMirror(text: "abc\ndef\nghi")
    // Offsets: a=0 b=1 c=2 \n=3 d=4 e=5 f=6 \n=7 g=8 h=9 i=10
    #expect(mirror.position(forUTF16Offset: 0, encoding: .utf16) == Position(line: 0, character: 0))
    #expect(mirror.position(forUTF16Offset: 3, encoding: .utf16) == Position(line: 0, character: 3))
    #expect(mirror.position(forUTF16Offset: 4, encoding: .utf16) == Position(line: 1, character: 0))
    #expect(mirror.position(forUTF16Offset: 6, encoding: .utf16) == Position(line: 1, character: 2))
    #expect(mirror.position(forUTF16Offset: 8, encoding: .utf16) == Position(line: 2, character: 0))
    #expect(
        mirror.position(forUTF16Offset: 11, encoding: .utf16) == Position(line: 2, character: 3))

    #expect(
        mirror.utf16Offset(for: Position(line: 1, character: 0), encoding: .utf16) == 4)
    #expect(
        mirror.utf16Offset(for: Position(line: 2, character: 3), encoding: .utf16) == 11)
}

@Test("utf16 round-trips position -> offset -> position for every offset")
func positionEncodingUTF16RoundTrips() {
    let mirror = DocumentTextMirror(text: "abc\ndef\nghi")
    for offset in 0...11 {
        let position = mirror.position(forUTF16Offset: offset, encoding: .utf16)
        #expect(position != nil)
        let roundTripped = mirror.utf16Offset(for: position!, encoding: .utf16)
        #expect(roundTripped == offset)
    }
}

@Test("utf8 with an astral scalar: character counts bytes, not UTF-16 units")
func positionEncodingUTF8AstralScalar() {
    // "a😀b": a=1 utf16 unit/1 byte, 😀=2 utf16 units/4 bytes, b=1 utf16 unit/1 byte.
    let mirror = DocumentTextMirror(text: "a😀b")
    // utf16 offsets: a@0, 😀@[1,3), b@3
    #expect(mirror.position(forUTF16Offset: 0, encoding: .utf16) == Position(line: 0, character: 0))
    #expect(mirror.position(forUTF16Offset: 3, encoding: .utf16) == Position(line: 0, character: 3))
    #expect(mirror.position(forUTF16Offset: 3, encoding: .utf8) == Position(line: 0, character: 5))

    #expect(
        mirror.utf16Offset(for: Position(line: 0, character: 5), encoding: .utf8) == 3)
    #expect(
        mirror.utf16Offset(for: Position(line: 0, character: 0), encoding: .utf8) == 0)
}

@Test("End-of-line and end-of-document offsets resolve to valid positions")
func positionEncodingEndOfLineAndDocument() {
    let mirror = DocumentTextMirror(text: "ab\ncd")
    #expect(mirror.position(forUTF16Offset: 2, encoding: .utf16) == Position(line: 0, character: 2))
    #expect(mirror.position(forUTF16Offset: 5, encoding: .utf16) == Position(line: 1, character: 2))
    #expect(mirror.position(forUTF16Offset: 6, encoding: .utf16) == nil)
    #expect(mirror.position(forUTF16Offset: -1, encoding: .utf16) == nil)
}

@Test("A utf8 character offset landing inside a multi-byte scalar is unrepresentable")
func positionEncodingUTF8UnrepresentableMidScalar() {
    // "😀" alone is one astral scalar: 2 utf16 units, 4 utf8 bytes.
    let mirror = DocumentTextMirror(text: "😀")
    // utf16 offset 1 lands between the two surrogate halves.
    #expect(mirror.position(forUTF16Offset: 1, encoding: .utf8) == nil)
    // utf8 character offsets 1-3 land inside the 4-byte scalar.
    #expect(mirror.utf16Offset(for: Position(line: 0, character: 1), encoding: .utf8) == nil)
    #expect(mirror.utf16Offset(for: Position(line: 0, character: 2), encoding: .utf8) == nil)
    #expect(mirror.utf16Offset(for: Position(line: 0, character: 3), encoding: .utf8) == nil)
    // But the whole scalar's bounds are representable.
    #expect(mirror.utf16Offset(for: Position(line: 0, character: 0), encoding: .utf8) == 0)
    #expect(mirror.utf16Offset(for: Position(line: 0, character: 4), encoding: .utf8) == 2)
}

@Test("An out-of-range line or negative character is unrepresentable")
func positionEncodingOutOfRangeIsUnrepresentable() {
    let mirror = DocumentTextMirror(text: "abc")
    #expect(mirror.utf16Offset(for: Position(line: 5, character: 0), encoding: .utf16) == nil)
    #expect(mirror.utf16Offset(for: Position(line: 0, character: -1), encoding: .utf16) == nil)
    #expect(mirror.utf16Offset(for: Position(line: 0, character: 100), encoding: .utf16) == nil)
}
