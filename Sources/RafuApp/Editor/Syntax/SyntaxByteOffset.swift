import Foundation
import SwiftTreeSitter

/// Pure conversions between the editor's UTF-16 offsets (the unit
/// `NSTextStorage`, `NSRange`, and `DocumentEditDelta` all speak) and the
/// units a tree-sitter parser running on the UTF-16 encoding path expects.
///
/// Two facts anchor everything here (lane-1 increment 8a, verified against
/// SwiftTreeSitter 0.8.0's `Encoding+Helpers` and `Parser` default encoding):
///
/// 1. `Parser` parses in UTF-16 by default, so a tree-sitter "byte" offset is
///    simply `utf16Offset * 2`. The classic UTF-8 byte-offset defect does not
///    apply on this path — query results already come back as UTF-16
///    `NSRange`s.
/// 2. A tree-sitter `Point.column` on the UTF-16 path is measured in bytes
///    from the start of its line, i.e. `(utf16 units since the last "\n") * 2`,
///    and `Point.row` is the count of `"\n"` characters before the offset.
///
/// The `Point` conversion is the piece incremental reparsing (increment 8b's
/// `InputEdit`) needs; it is implemented and tested now so 8b can build on a
/// verified helper. All members are `nonisolated` so the syntax-parsing actor
/// can call them off the main actor.
nonisolated enum SyntaxByteOffset {
    /// tree-sitter byte width of one UTF-16 code unit on the UTF-16 encoding
    /// path.
    static let bytesPerUTF16Unit = 2

    /// The tree-sitter byte offset for a UTF-16 offset (`offset * 2`).
    static func byteOffset(forUTF16Offset offset: Int) -> Int {
        offset * bytesPerUTF16Unit
    }

    /// The tree-sitter `Point` (`row`, `column`) for a UTF-16 `offset` into
    /// `text`. `row` counts `"\n"` before `offset`; `column` is the UTF-16
    /// distance from the start of the current line, converted to bytes. The
    /// offset is clamped into `0...text.utf16.count`.
    static func point(forUTF16Offset offset: Int, in text: String) -> Point {
        let string = text as NSString
        let clamped = min(max(offset, 0), string.length)
        var row = 0
        var lineStart = 0
        var index = 0
        let newline: unichar = 0x000A
        while index < clamped {
            if string.character(at: index) == newline {
                row += 1
                lineStart = index + 1
            }
            index += 1
        }
        let column = (clamped - lineStart) * bytesPerUTF16Unit
        return Point(row: row, column: column)
    }
}
