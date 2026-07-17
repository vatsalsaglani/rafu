import Foundation
import SwiftTreeSitter

/// One declaration extracted from a file by a tree-sitter `tags.scm` query.
/// Unlike `BufferSymbol` (the palette's `@`-mode display type), this keeps
/// EVERY `@definition.*` kind as a raw suffix string — function, method,
/// class, interface, property, constant, module — so the workspace symbol
/// index and its navigation provider can surface constants and properties the
/// buffer scanner intentionally dropped this lane (see increment 9's outline
/// gap), and dedup fixes the duplicate-Swift-method wart.
nonisolated struct ExtractedSymbol: Sendable, Equatable {
    let name: String
    /// The `@definition.` suffix (e.g. `function`, `method`, `class`,
    /// `interface`, `property`, `constant`, `module`).
    let kind: String
    /// UTF-16 range of the name inside the scanned text.
    let range: NSRange
}

/// Grammar-backed declaration extraction for the workspace symbol index
/// (increment 10a, plan §7.3/§7.9), reusing the `tags.scm` mechanics of
/// `BufferSymbolScanner.scanUsingGrammar` but keeping all definition kinds and
/// deduplicating by `(name, range)` within a file.
///
/// The synchronous `extractSymbols(text:query:parser:limit:)` core is the hot
/// path: `WorkspaceSymbolIndex` resolves each grammar's `Query`/`Parser` ONCE
/// (parser `setLanguage` is the expensive step) and calls it per file, so the
/// non-`Sendable` tree-sitter `Parser`/`Tree`/`QueryCursor` never cross an
/// `await`. The async `extract(text:grammarID:limit:)` convenience builds its
/// own one-shot parser and is used by unit tests.
nonisolated enum WorkspaceSymbolExtractor {
    /// Per-file symbol cap, mirroring `BufferSymbolScanner.symbolLimit`.
    static let perFileLimit = 2_000

    /// The only packaged grammars with a vendored `tags.scm` (increment 9;
    /// Bash and Dockerfile added in the symbol-coverage lane's increment A;
    /// TOML and YAML added in increment B; Markdown added in increment C):
    /// every other extension is skipped by a cheap lookup so indexing a
    /// 100k-file monorepo never reads or parses files it has no query for.
    static let grammarsWithTags: Set<GrammarLanguageID> = [
        .swift, .python, .javascript, .typescript, .tsx, .bash, .dockerfile,
        .toml, .yaml, .markdown,
    ]

    /// Kinds answerable by go-to-definition/declaration. `section` (Markdown
    /// headings) is deliberately excluded so headings surface only in `#`
    /// search, never as a ⌃⌘J answer. Config keys share code kinds
    /// (property/class/constant) and remain navigable by design.
    static let navigableKinds: Set<String> = [
        "function", "method", "class", "interface", "property", "constant", "module",
    ]

    /// Maps a workspace-relative path to a packaged grammar that has a
    /// vendored `tags.scm`, or `nil` when the file has no such grammar (a
    /// cheap extension/filename check done before any file read).
    static func grammarWithTags(forRelativePath relativePath: String) -> GrammarLanguageID? {
        let name = (relativePath as NSString).lastPathComponent
        let fileExtension = (relativePath as NSString).pathExtension
        guard
            let grammarID = GrammarLanguageID.languageID(
                forExtension: fileExtension, fileName: name),
            grammarsWithTags.contains(grammarID)
        else { return nil }
        return grammarID
    }

    /// Extracts declarations from `text` using `grammarID`'s vendored
    /// `tags.scm`. Returns `nil` — never `[]` — when the grammar has no tags
    /// query so a caller can distinguish "unsupported grammar" from "parsed
    /// fine, nothing found". Convenience wrapper: builds a one-shot parser.
    static func extract(
        text: String,
        grammarID: GrammarLanguageID,
        limit: Int = perFileLimit
    ) async -> [ExtractedSymbol]? {
        guard limit > 0, !text.isEmpty else { return [] }
        guard let query = await GrammarRegistry.shared.tagsQuery(for: grammarID),
            let configuration = try? await GrammarRegistry.shared.configuration(for: grammarID)
        else { return nil }

        let parser = Parser()
        guard (try? parser.setLanguage(configuration.language)) != nil else { return nil }
        return extractSymbols(text: text, query: query, parser: parser, limit: limit)
    }

    /// Synchronous extraction core. `parser` must already have had
    /// `setLanguage` called with the language `query` was compiled against.
    /// Everything here is non-`Sendable` tree-sitter work and MUST stay
    /// synchronous — no `await` may touch `parser`, the parsed `tree`, or the
    /// query cursor. Deduplicates by `(name, range)` so a declaration matched
    /// by both a nested and a generic `tags.scm` pattern appears once.
    static func extractSymbols(
        text: String,
        query: Query,
        parser: Parser,
        limit: Int
    ) -> [ExtractedSymbol] {
        guard limit > 0, !text.isEmpty, let tree = parser.parse(text) else { return [] }

        let cursor = query.execute(in: tree)
        let context = Predicate.Context(string: text)
        let nsText = text as NSString

        var symbols: [ExtractedSymbol] = []
        var seen: Set<DedupKey> = []
        for match in cursor.resolve(with: context) {
            guard let symbol = symbol(from: match, text: nsText) else { continue }
            let key = DedupKey(
                name: symbol.name, location: symbol.range.location, length: symbol.range.length)
            guard seen.insert(key).inserted else { continue }
            symbols.append(symbol)
            if symbols.count >= limit { break }
        }
        return symbols
    }

    /// Builds an `ExtractedSymbol` from one resolved `tags.scm` match, keeping
    /// every `@definition.*` kind (`@reference.*` matches are still dropped —
    /// the index stores declarations, not occurrences).
    private static func symbol(from match: QueryMatch, text: NSString) -> ExtractedSymbol? {
        guard let nameCapture = match.captures(named: "name").first else { return nil }
        guard
            let definitionCapture = match.captures.first(where: {
                $0.name?.hasPrefix("definition.") == true
            }),
            let definitionName = definitionCapture.name
        else { return nil }

        let range = nameCapture.range
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        return ExtractedSymbol(
            name: text.substring(with: range),
            kind: String(definitionName.dropFirst("definition.".count)),
            range: range
        )
    }

    private struct DedupKey: Hashable {
        let name: String
        let location: Int
        let length: Int
    }
}
