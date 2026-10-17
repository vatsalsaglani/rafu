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
        LineIndex(text).point(forUTF16Offset: offset)
    }

    /// Parser-owned LF line starts. Tree-sitter counts LF only, including in
    /// CRLF text. Point lookup is logarithmic and never reads a text prefix.
    nonisolated struct LineIndex: Sendable {
        private var starts: [Int] = [0]
        private(set) var length: Int
        /// Structural evidence for bounded scanning: queries add no work and
        /// an edit scans only its replacement, regardless of its location.
        private(set) var scannedUTF16Count: Int

        init(_ text: String) {
            let string = text as NSString
            length = string.length
            scannedUTF16Count = string.length
            appendLineStarts(in: string, range: NSRange(location: 0, length: length))
        }

        func point(forUTF16Offset offset: Int) -> Point {
            let clamped = min(max(offset, 0), length)
            let row = upperBound(clamped) - 1
            return Point(row: row, column: (clamped - starts[row]) * bytesPerUTF16Unit)
        }

        /// Call only for a validated contiguous edit relative to this index.
        mutating func applyEdit(
            startUTF16: Int, oldEndUTF16: Int, newEndUTF16: Int, newText: String
        ) {
            let firstRemoved = upperBound(startUTF16)
            let suffixStart = upperBound(oldEndUTF16)
            let delta = newEndUTF16 - oldEndUTF16
            let suffix = starts[suffixStart...].map { $0 + delta }
            starts.removeSubrange(firstRemoved...)
            let replacementRange = NSRange(
                location: startUTF16, length: newEndUTF16 - startUTF16)
            appendLineStarts(in: newText as NSString, range: replacementRange)
            starts.append(contentsOf: suffix)
            length += delta
            scannedUTF16Count += replacementRange.length
        }

        private mutating func appendLineStarts(in string: NSString, range: NSRange) {
            for index in range.location..<NSMaxRange(range) {
                if string.character(at: index) == 0x000A { starts.append(index + 1) }
            }
        }

        private func upperBound(_ offset: Int) -> Int {
            var low = 0
            var high = starts.count
            while low < high {
                let middle = low + (high - low) / 2
                if starts[middle] <= offset {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
    }
}
