import AppKit
import Foundation
import SwiftTreeSitter
import Testing

@testable import RafuApp

/// Data-level proof for `PlainTextSyntaxHighlighter`, the shared parse+query
/// core factored out of `TreeSitterCodeSyntaxHighlighter`'s Markdown fence
/// highlighter (diff-syntax-highlighting-and-hover phase, Part A1). Mirrors
/// `SyntaxParsingActorTests`' pattern for obtaining a real grammar: a fresh
/// `GrammarRegistry` instance loads a packaged `LanguageConfiguration`
/// off-main, and its `.language`/`.queries[.highlights]` feed the function
/// under test directly — the same pre-resolved shape
/// `DiffSyntaxHighlighter`/`TreeSitterCodeSyntaxHighlighter` hand it in
/// production.
@Suite("PlainTextSyntaxHighlighter")
struct PlainTextSyntaxHighlighterTests {
    @Test("A Swift snippet classifies a keyword, string, and comment")
    func swiftSnippetClassifiesCoreCaptures() async throws {
        let registry = GrammarRegistry()
        let configuration = try await registry.configuration(for: .swift)
        let query = try #require(configuration.queries[.highlights])

        let code = "let value = \"hi\" // note"
        let spans = try #require(
            PlainTextSyntaxHighlighter.spans(
                text: code, language: configuration.language, highlightsQuery: query))

        #expect(
            spans.contains {
                $0.themeKey == "keyword" && $0.range == NSRange(location: 0, length: 3)
            })
        #expect(spans.contains { $0.themeKey == "string" })
        #expect(spans.contains { $0.themeKey == "comment" })
    }

    // NOTE ON DEVIATION: the phase brief's original suggested signature
    // (`spans(for text: String, languageID: String) -> [SyntaxSpan]?`)
    // would let a bogus `languageID` exercise a nil-returning "unknown
    // grammar" path here. The advisor brief deliberately overrode that
    // signature to take a pre-resolved `Language`/`Query` instead — grammar
    // *resolution* now happens one layer up (`DiffSyntaxHighlighter`,
    // `TreeSitterCodeSyntaxHighlighter`), so there is no "unknown grammar
    // ID" input left to feed this function. Those two call sites' own
    // "unknown grammar → plain fallback" behavior is covered by
    // `DiffSyntaxHighlighterTests.unknownExtensionFallsBackToPlain` and the
    // untouched `MarkdownCodeSyntaxHighlighterTests
    // .unknownInfoStringFallsBackToPlainText`. What remains genuinely
    // testable at THIS layer is the sibling guarantee: content with no
    // matching captures for a valid grammar returns an empty (never nil,
    // never crashing) array — the plain-rendering fallback a caller sees
    // when nothing lights up.
    @Test("Content with no matching captures yields empty spans, not nil")
    func contentWithNoCapturesYieldsEmptySpans() async throws {
        let registry = GrammarRegistry()
        let configuration = try await registry.configuration(for: .swift)
        let query = try #require(configuration.queries[.highlights])

        // Whitespace-only Swift source parses successfully but has no
        // keyword/string/comment/etc. node to capture.
        let spans = try #require(
            PlainTextSyntaxHighlighter.spans(
                text: "   \n   ", language: configuration.language, highlightsQuery: query))
        #expect(spans.isEmpty)
    }

    @Test("Refactor guard: TreeSitterCodeSyntaxHighlighter still classifies via the shared core")
    @MainActor
    func refactoredHighlighterStillClassifiesKeyword() {
        // Behavior-preserving refactor check: `TreeSitterCodeSyntaxHighlighter
        // .attributedString` now routes through `PlainTextSyntaxHighlighter
        // .spans` internally. This does not replace
        // `MarkdownCodeSyntaxHighlighterTests` (left unmodified per the
        // brief) — it's an extra, layer-crossing proof that the refactor
        // didn't change the observable result.
        let theme = RafuThemeCatalog.indigo
        let attributed = TreeSitterCodeSyntaxHighlighter.attributedString(
            code: "let value = 1", language: "swift", theme: theme)
        let keywordColor = NSColor(rafuHex: theme.syntax["keyword"]?.color ?? "")
        let letColor =
            attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(letColor == keywordColor)
    }
}
