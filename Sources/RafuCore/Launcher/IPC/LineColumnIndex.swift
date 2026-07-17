/// Pure line/column → UTF-16 offset conversion for the `--goto` seam
/// (`WorkspaceSession.openFile(atRelativePath:selecting:)` and its I4
/// completion). Line and column are 1-based, matching
/// `LauncherArgumentParser`'s `--goto path:line[:column]` grammar and
/// `SourceLocation`. No I/O — operates on an in-memory `String` a caller
/// already has (on-disk read today; a mounted buffer's live text once I4
/// lands).
public enum LineColumnIndex {
    /// Converts a 1-based `line` and optional 1-based `column` into a
    /// UTF-16 offset into `text`.
    ///
    /// - A `line` past the text's last line clamps to the start of the
    ///   last line; a `line` below 1 clamps to the start of the first line.
    ///   An empty document has exactly one (empty) line, so every `line`
    ///   clamps to offset 0.
    /// - `column` is 1-based and clamps to the line's end (exclusive of its
    ///   terminator) when it runs past the line's UTF-16 length; `nil` or a
    ///   non-positive value selects the start of the line.
    /// - Both `"\n"` and `"\r\n"` line endings are recognized; a line's
    ///   UTF-16 span excludes its terminator.
    public static func utf16Offset(line: Int, column: Int?, in text: String) -> Int {
        let lines = lineOffsets(in: text)
        let lineIndex = max(0, min(line - 1, lines.count - 1))
        let selectedLine = lines[lineIndex]

        guard let column else { return selectedLine.start }
        let requested = selectedLine.start + max(0, column - 1)
        return min(requested, selectedLine.end)
    }

    /// One entry per line: the UTF-16 `start` offset and the UTF-16 `end`
    /// offset (exclusive of the line's terminator, if any). Always returns
    /// at least one entry, including for empty text.
    private static func lineOffsets(in text: String) -> [(start: Int, end: Int)] {
        var lines: [(start: Int, end: Int)] = []
        var lineStart = 0
        var offset = 0
        var previousWasCarriageReturn = false

        for unit in text.utf16 {
            if unit == 0x0A {
                let lineEnd = previousWasCarriageReturn ? offset - 1 : offset
                lines.append((start: lineStart, end: lineEnd))
                lineStart = offset + 1
            }
            previousWasCarriageReturn = unit == 0x0D
            offset += 1
        }
        lines.append((start: lineStart, end: offset))
        return lines
    }
}
