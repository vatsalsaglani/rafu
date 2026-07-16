import Foundation

/// Pure, nonisolated Markdown-shape parsing for the editor's hover tooltip.
/// A language server's hover payload is usually one fenced code block (the
/// symbol's signature) followed by prose documentation, but the raw text
/// arriving from `LSPNavigationProvider.flattenedHoverMultiline` still
/// carries the literal ```` ``` ```` fences and any `---` thematic breaks.
/// This type separates those two concerns into `ParsedHover.signature` (fence
/// contents, fences stripped) and `ParsedHover.documentation` (everything
/// else) so the tooltip can render a clean monospaced signature block above
/// lightly-rendered prose instead of showing raw fence markers. Never logs
/// its input or output — the hover payload is redaction-sensitive.
nonisolated enum HoverMarkdownParser {
    /// The result of splitting a raw hover payload into its signature and
    /// documentation parts. Either may be `nil` (no fenced code block, or no
    /// prose outside it); both are individually length-bounded so a
    /// pathologically large hover can never balloon either field.
    nonisolated struct ParsedHover: Sendable, Equatable {
        let signature: String?
        let documentation: String?
    }

    /// Upper bound on each of `signature`/`documentation`, independent of the
    /// bound already applied to the raw payload upstream
    /// (`LSPNavigationProvider.maximumHoverCharacters`). Defensive: keeps
    /// this parser's output bounded even if a caller passes unbounded text.
    private static let maximumSegmentCharacters = 2_000

    /// Splits `raw` into a signature (the first fenced code block, if any,
    /// with its fences and language tag stripped) and documentation
    /// (everything else, with `---` thematic breaks removed and surrounding
    /// blank lines trimmed).
    ///
    /// `isMarkdown: false` skips fence parsing entirely — the payload is
    /// plain text, so it becomes verbatim `documentation` with `signature`
    /// left `nil`. Whitespace-only or empty `raw` yields both fields `nil`
    /// so the caller can fall back to a plain-text rendering instead of an
    /// empty box.
    static func parse(_ raw: String, isMarkdown: Bool) -> ParsedHover {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedHover(signature: nil, documentation: nil) }

        guard isMarkdown else {
            return ParsedHover(signature: nil, documentation: bounded(trimmed))
        }

        let lines = trimmed.components(separatedBy: "\n")
        guard let fenceStart = lines.firstIndex(where: isFenceMarker),
            let closingOffset = lines[(fenceStart + 1)...].firstIndex(where: isFenceMarker)
        else {
            // No fence, or an unterminated one: treat the whole payload as
            // documentation rather than guessing at a signature.
            return ParsedHover(signature: nil, documentation: bounded(cleanedDocumentation(lines)))
        }

        let signatureLines = lines[(fenceStart + 1)..<closingOffset]
        let signature = signatureLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let remainderLines = Array(lines[..<fenceStart]) + Array(lines[(closingOffset + 1)...])
        let documentation = cleanedDocumentation(remainderLines)

        return ParsedHover(
            signature: signature.isEmpty ? nil : bounded(signature),
            documentation: documentation.isEmpty ? nil : bounded(documentation)
        )
    }

    /// A fenced-code-block delimiter line: three or more backticks, with an
    /// optional language tag on the opening line, possibly indented.
    private static func isFenceMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// Joins `lines`, drops `---`/`***`/`___` thematic-break separators left
    /// behind by the fence split, and trims leading/trailing blank lines.
    private static func cleanedDocumentation(_ lines: [String]) -> String {
        let withoutBreaks = lines.filter { !isThematicBreak($0) }
        var start = 0
        var end = withoutBreaks.count
        while start < end, withoutBreaks[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        while end > start, withoutBreaks[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return withoutBreaks[start..<end].joined(separator: "\n")
    }

    /// A CommonMark-style thematic break: a line of three or more identical
    /// `-`, `*`, or `_` characters (ignoring surrounding whitespace).
    private static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let marker = trimmed.first,
            "-*_".contains(marker)
        else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private static func bounded(_ text: String) -> String {
        String(text.prefix(maximumSegmentCharacters))
    }
}
