import Foundation
import SwiftTreeSitter

/// Shared, string-level tree-sitter parse + highlights-query pass, factored
/// out of `TreeSitterCodeSyntaxHighlighter`'s fence-highlighting core
/// (`Sources/RafuApp/Markdown/MarkdownCodeSyntaxHighlighter.swift`) so the
/// diff canvas's `DiffSyntaxHighlighter` can reuse the identical grammar
/// pipeline instead of owning a second parse+query implementation. Pure and
/// `nonisolated`: given an already-resolved `Language` + compiled
/// `highlights.scm` `Query`, it does one `Parser.parse` + `query.execute`
/// pass and classifies each capture through `CaptureTokenMap` into UTF-16
/// `SyntaxSpan`s. No theming here — color resolution stays with the caller
/// (`TreeSitterCodeSyntaxHighlighter` for Markdown fences, `GitDiffCell` for
/// the diff canvas) so each surface can style independently.
///
/// Deliberately takes a pre-resolved `Language`/`Query` rather than a
/// `GrammarLanguageID`: query loading in this codebase is either
/// `@MainActor` (`FenceHighlightQueryCache`, because `Bundle.module` is
/// main-actor-isolated) or `async` on the off-main `GrammarRegistry` actor —
/// both async/isolated concerns this helper stays deliberately free of, so
/// both a `@MainActor` caller (Markdown fences) and an off-main
/// `@concurrent` caller (`DiffSyntaxHighlighter`) can call it synchronously
/// without an actor hop baked into its signature.
///
/// Heavy — a full parse + query pass over arbitrary-length text. Never call
/// this on the main actor for diff-sized (multi-hundred-line) input; callers
/// doing so must already be off the main actor (see `DiffSyntaxHighlighter`,
/// which is `@concurrent`).
nonisolated enum PlainTextSyntaxHighlighter {
    /// One-shot parse + highlights-query pass over `text` using an already
    /// resolved grammar. Returns capture-classified UTF-16 `SyntaxSpan`s (via
    /// `CaptureTokenMap`), or `nil` when the parser rejects `language` or
    /// produces no tree — never partial/garbage spans. Emission order
    /// matches the query cursor's traversal order (the same order the
    /// pre-refactor inline loop this replaces produced).
    static func spans(text: String, language: Language, highlightsQuery: Query) -> [SyntaxSpan]? {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil,
            let tree = parser.parse(text)
        else { return nil }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var spans: [SyntaxSpan] = []
        let cursor = highlightsQuery.execute(in: tree)
        for namedRange in cursor.highlights() {
            guard let themeKey = CaptureTokenMap.themeKey(forCapture: namedRange.name) else {
                continue
            }
            let range = NSIntersectionRange(fullRange, namedRange.range)
            guard range.length > 0 else { continue }
            spans.append(SyntaxSpan(themeKey: themeKey, range: range))
        }
        return spans
    }
}
