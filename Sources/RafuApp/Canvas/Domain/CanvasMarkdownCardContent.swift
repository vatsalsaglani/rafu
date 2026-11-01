import Foundation

/// Pure helpers for the Markdown preview on an Ensemble file card. No SwiftUI
/// and no state: the card passes a value snapshot of the text in and keeps
/// only the parsed `Item`s. Nothing here is saved; the Preview/Source choice
/// is view state in `CanvasBoardResources`, so `CanvasCardContent.file(path:)`
/// keeps one shape.
nonisolated enum CanvasMarkdownCard {
    /// Diagrams drawn natively on one card. Later fences show as code, so a
    /// file full of Mermaid cannot start unbounded render work.
    static let maxDiagrams = 8

    /// The card draws these files as Markdown by default.
    static func isMarkdown(path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": true
        default: false
        }
    }

    /// A Markdown file opens as Preview; every other file is the plain excerpt.
    static func defaultShowsSource(path: String) -> Bool { !isMarkdown(path: path) }

    /// Cuts `text` at its last line end when it is at least `limitBytes` long,
    /// because a read of exactly the limit may have stopped mid-line or
    /// mid-character. The flag is true when the file may continue past the cut.
    static func truncatedAtLastLine(_ text: String, limitBytes: Int) -> (
        text: String, isTruncated: Bool
    ) {
        guard text.utf8.count >= limitBytes else { return (text, false) }
        let bytes = Array(text.utf8.prefix(limitBytes))
        if let newline = bytes.lastIndex(of: 10) {
            return (String(decoding: bytes[..<newline], as: UTF8.self), true)
        }
        return (String(decoding: bytes, as: UTF8.self), true)
    }

    /// One row of the rendered card.
    struct Item: Identifiable, Sendable {
        enum Kind: Sendable {
            case block(CanvasNoteMarkdown.Block)
            case mermaid(MermaidParseResult)
            case frontmatter(MarkdownFrontmatterParseResult)
        }

        /// Running position. Never a source line: each Markdown segment
        /// numbers its blocks from line zero.
        let id: Int
        let kind: Kind
        /// Space above the row (`gap(before:after:)`), fixed when parsed so
        /// the view never works it out in `body`.
        let gap: CGFloat
    }

    /// Front matter, then Markdown blocks and Mermaid diagrams in source
    /// order. Run off the main actor; the result is `Sendable`.
    static func items(from source: String) -> [Item] {
        var kinds: [Item.Kind] = []
        var diagrams = 0
        for segment in MarkdownPreviewSegmentParser().parse(source) {
            switch segment.content {
            case .frontmatter(let result):
                kinds.append(.frontmatter(result))
            case .markdown(let text):
                kinds.append(contentsOf: CanvasNoteMarkdown.blocks(in: text).map { .block($0) })
            case .mermaid(let result):
                diagrams += 1
                if diagrams <= maxDiagrams {
                    kinds.append(.mermaid(result))
                } else {
                    let fence = "```mermaid\n\(raw(of: result))\n```"
                    kinds.append(
                        contentsOf: CanvasNoteMarkdown.blocks(in: fence).map { .block($0) })
                }
            }
        }
        return kinds.enumerated().map { index, kind in
            Item(
                id: index, kind: kind,
                gap: gap(before: kind, after: index > 0 ? kinds[index - 1] : nil))
        }
    }

    /// `items(from:)` away from the main actor.
    @concurrent static func parsedItems(from source: String) async -> [Item] {
        items(from: source)
    }

    /// 12 pt above a heading, 6 pt below it, 8 pt between other rows; the
    /// same rhythm as a rendered note.
    static func gap(before kind: Item.Kind, after previous: Item.Kind?) -> CGFloat {
        guard let previous else { return 0 }
        if case .block(let block) = kind, case .heading = block.kind { return 12 }
        if case .block(let block) = previous, case .heading = block.kind { return 6 }
        return 8
    }

    private static func raw(of result: MermaidParseResult) -> String {
        switch result {
        case .diagram(let diagram): diagram.raw
        case .unsupported(_, let raw): raw
        case .malformed(_, let raw, _): raw
        }
    }
}
