import AppKit
import MarkdownUI
import Neon
import SwiftTreeSitter
import SwiftUI

/// Fence-code syntax highlighter for the Markdown preview (plan §7.7,
/// lane-1 increment 9). Routes a fenced code block's info string through
/// `GrammarLanguageID.languageID(forInfoString:)` and, when a packaged
/// grammar exists, does a one-shot tree-sitter parse + highlights-query pass
/// and maps captures through `CaptureTokenMap` to theme colors. Falls back
/// to a plain, theme-styled `Text` for an unmapped/unknown info string, an
/// oversized block, or any parse/query failure — never a crash, never a
/// blank block, and never a `WKWebView`.
///
/// MarkdownUI's `CodeSyntaxHighlighter.highlightCode(_:language:)` is
/// synchronous and called directly from `CodeBlockView.body`, which SwiftUI
/// guarantees runs on the main actor (`View.body` is a `@MainActor`
/// protocol requirement) — but the requirement itself is not actor-isolated,
/// and `RafuApp`'s module-wide default `@MainActor` isolation cannot
/// satisfy a non-isolated protocol witness. `highlightCode` is therefore
/// `nonisolated` and bridges to the main actor with `MainActor
/// .assumeIsolated`, the same pattern `WorkspaceTerminalController`'s
/// `DelegateProxy` uses for SwiftTerm's main-thread, non-actor-annotated
/// delegate callbacks.
///
/// The grammar/query cache below is a small, main-actor-only dictionary —
/// deliberately NOT routed through the off-main `GrammarRegistry` actor,
/// because this call path has no `async` entry point to `await` an actor
/// hop from. Caching only `Sendable` `Language`/`Query` values here (never
/// live buffer state) keeps this a safe, non-duplicated slice of
/// `GrammarRegistry`'s own thread-safety story, per the increment-9 brief.
nonisolated struct TreeSitterCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    /// Strict cap (UTF-8 bytes) on fenced-block content eligible for
    /// synchronous tree-sitter highlighting. Above this, a fence renders as
    /// plain, theme-styled text instead of blocking the main-actor render
    /// pass on a full parse + query of a very large block — the preview is
    /// already debounced and presentation-only, but a single huge fence
    /// inside it should never do so.
    static let maximumHighlightedByteCount = 8_000

    let theme: RafuTheme

    func highlightCode(_ code: String, language: String?) -> Text {
        MainActor.assumeIsolated {
            Text(
                AttributedString(
                    Self.attributedString(code: code, language: language, theme: theme)))
        }
    }

    /// Builds the fully-styled `NSAttributedString` for one fenced code
    /// block. Internal (not `private`) and returning `NSAttributedString`
    /// rather than `Text` specifically so `MarkdownCodeSyntaxHighlighterTests`
    /// can assert on the actual resolved attributes (color, size-cap
    /// fallback) — SwiftUI's `Text` exposes no introspectable content.
    /// `highlightCode` is the only production call site; it wraps this
    /// result in `Text` at the MarkdownUI boundary.
    @MainActor
    static func attributedString(code: String, language: String?, theme: RafuTheme)
        -> NSAttributedString
    {
        guard let language,
            let grammarID = GrammarLanguageID.languageID(forInfoString: language),
            code.utf8.count <= maximumHighlightedByteCount,
            let query = FenceHighlightQueryCache.query(for: grammarID),
            let highlighted = highlightedAttributedString(
                code: code, grammarID: grammarID, query: query, theme: theme)
        else {
            return plainAttributedString(code, theme: theme)
        }
        return highlighted
    }

    /// One-shot parse (deliberately not reusing the live editor's
    /// incremental `SyntaxParsingActor` tree — out of scope here, and this
    /// path has no open `EditorDocument` to attach to anyway) + a highlights
    /// query pass — the parse+query core now lives in the shared
    /// `PlainTextSyntaxHighlighter.spans(text:language:highlightsQuery:)`
    /// (also used by the diff canvas's `DiffSyntaxHighlighter`); this method
    /// only adds theming, building an `NSMutableAttributedString` the same
    /// way `SyntaxHighlighter.attributes(for:)` styles editor tokens so a
    /// fence and the live editor render a language identically. `nil` on any
    /// parser/query failure.
    @MainActor
    private static func highlightedAttributedString(
        code: String, grammarID: GrammarLanguageID, query: Query, theme: RafuTheme
    ) -> NSAttributedString? {
        guard
            let spans = PlainTextSyntaxHighlighter.spans(
                text: code, language: grammarID.language, highlightsQuery: query)
        else { return nil }

        let highlighter = SyntaxHighlighter(theme: theme, fileExtension: "", fileName: "")
        let mutable = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: highlighter.baseFont,
                .foregroundColor: NSColor(rafuHex: theme.editor.foreground),
            ]
        )
        for span in spans {
            mutable.addAttributes(
                highlighter.attributes(for: Token(name: span.themeKey, range: span.range)),
                range: span.range)
        }
        return mutable
    }

    private static func plainAttributedString(_ code: String, theme: RafuTheme)
        -> NSAttributedString
    {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = theme.syntax["markup.code"]?.color {
            attributes[.foregroundColor] = NSColor(rafuHex: color)
        }
        return NSAttributedString(string: code, attributes: attributes)
    }
}

/// Main-actor cache of compiled `highlights.scm` queries for
/// `TreeSitterCodeSyntaxHighlighter`. See that type's doc for why this
/// cannot route through the off-main `GrammarRegistry` actor.
@MainActor
private enum FenceHighlightQueryCache {
    private static var cache: [GrammarLanguageID: Query?] = [:]

    static func query(for id: GrammarLanguageID) -> Query? {
        if let cached = cache[id] {
            return cached
        }
        guard
            let url = Bundle.module.url(
                forResource: "highlights", withExtension: "scm",
                subdirectory: "Grammars/\(id.configurationName)"),
            let query = try? Query(language: id.language, url: url)
        else {
            cache[id] = nil
            return nil
        }
        cache[id] = query
        return query
    }
}
