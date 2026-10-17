import Foundation

/// UTF-16 line starts for one text storage. Stores offsets, never document text.
/// Line separators match NSString; a final separator starts an empty line.
struct EditorGutterLineIndex {
    struct Operations: Equatable {
        var fullRebuilds = 0
        var incrementalScans = 0
        var fullRebuildUTF16Units = 0
        var incrementalUTF16Units = 0
        var shiftedOffsets = 0
    }

    private(set) var starts: [Int] = [0]
    private(set) var utf16Length = 0
    private(set) var operations = Operations()

    var lineCount: Int { starts.count }

    init(content: NSString) {
        rebuild(content: content)
    }

    mutating func rebuild(content: NSString) {
        starts = [0]
        Self.appendStarts(in: content, range: 0..<content.length, to: &starts)
        utf16Length = content.length
        operations.fullRebuilds += 1
        operations.fullRebuildUTF16Units += content.length
    }

    /// `editedRange` is the post-edit range from NSTextStorage, including
    /// combined replacements in one beginEditing/endEditing transaction.
    mutating func applyEdit(content: NSString, editedRange: NSRange, changeInLength delta: Int) {
        let oldEditedLength = editedRange.length - delta
        guard editedRange.location != NSNotFound,
            editedRange.location >= 0, editedRange.length >= 0,
            oldEditedLength >= 0,
            editedRange.location <= utf16Length,
            oldEditedLength <= utf16Length - editedRange.location,
            utf16Length + delta == content.length,
            NSMaxRange(editedRange) <= content.length
        else {
            rebuild(content: content)
            return
        }

        // A separator can change only inside the replacement or at its edges.
        // The extra units cover a CR joining/leaving an LF on either side.
        // Test the END of each separator, so a scan starting inside CRLF
        // still emits exactly one line start (after LF).
        let scanStart = max(0, editedRange.location - 1)
        let oldScanEnd = min(utf16Length, editedRange.location + oldEditedLength + 1)
        let newScanEnd = oldScanEnd + delta
        let first = upperBound(scanStart)
        let last = upperBound(oldScanEnd)
        var replacement: [Int] = []
        Self.appendStarts(in: content, range: scanStart..<newScanEnd, to: &replacement)

        if delta != 0 {
            for index in last..<starts.count {
                starts[index] += delta
            }
            operations.shiftedOffsets += starts.count - last
        }
        starts.replaceSubrange(first..<last, with: replacement)
        utf16Length = content.length
        operations.incrementalScans += 1
        operations.incrementalUTF16Units += newScanEnd - scanStart
    }

    /// 1-based line number, including the trailing empty line at EOF.
    func lineNumber(forOffset offset: Int) -> Int {
        max(1, upperBound(min(max(0, offset), utf16Length)))
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

    private static func appendStarts(
        in content: NSString, range: Range<Int>, to offsets: inout [Int]
    ) {
        for location in range {
            switch content.character(at: location) {
            case 0x000A, 0x0085, 0x2028, 0x2029:
                offsets.append(location + 1)
            case 0x000D:
                if location + 1 == content.length || content.character(at: location + 1) != 0x000A {
                    offsets.append(location + 1)
                }
            default:
                break
            }
        }
    }
}
