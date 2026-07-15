import AppKit
import Testing

@testable import RafuApp

/// Data-level proof for the Markdown fence highlighter (plan §7.7, lane-1
/// increment 9). `NSAttributedString.attributedString(code:language:theme:)`
/// is the same builder `highlightCode(_:language:)` wraps in `Text` — tested
/// directly here because SwiftUI's `Text` exposes no introspectable content.
@Suite("TreeSitterCodeSyntaxHighlighter")
@MainActor
struct MarkdownCodeSyntaxHighlighterTests {
    private let theme = RafuThemeCatalog.indigo

    @Test("An unknown/unmapped info string falls back to plain, theme-styled text")
    func unknownInfoStringFallsBackToPlainText() {
        let attributed = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: "some plain block", language: "brainfuck", theme: theme)

        #expect(attributed.string == "some plain block")
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor(rafuHex: theme.syntax["markup.code"]?.color ?? ""))
    }

    @Test("A nil info string falls back to plain, theme-styled text")
    func nilInfoStringFallsBackToPlainText() {
        let attributed = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: "let x = 1", language: nil, theme: theme)
        #expect(attributed.string == "let x = 1")
    }

    @Test("A mapped language under the size cap is highlighted with theme keyword color")
    func mappedLanguageUnderCapIsHighlighted() {
        let code = "let value = 1"
        let attributed = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: code, language: "swift", theme: theme)

        #expect(attributed.string == code)
        let keywordColor = NSColor(rafuHex: theme.syntax["keyword"]?.color ?? "")
        // "let" (0..<3) must carry the theme's keyword color, not the plain
        // markup.code fallback color.
        let letColor =
            attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(letColor == keywordColor)
    }

    @Test("A block over the strict byte cap falls back to plain text, never parses")
    func oversizedBlockFallsBackToPlainText() {
        let oversized = String(
            repeating: "a", count: TreeSitterCodeSyntaxHighlighter.maximumHighlightedByteCount + 1)
        let code = "let value = \"\(oversized)\""
        let attributed = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: code, language: "swift", theme: theme)

        #expect(attributed.string == code)
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor(rafuHex: theme.syntax["markup.code"]?.color ?? ""))
    }

    @Test("An info string alias (py) resolves to the same grammar as its canonical name")
    func infoStringAliasResolves() {
        let canonical = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: "def f():\n    pass", language: "python", theme: theme)
        let alias = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: "def f():\n    pass", language: "py", theme: theme)

        #expect(canonical.string == alias.string)
        let canonicalColor =
            canonical.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let aliasColor = alias.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(canonicalColor == aliasColor)
    }
}
