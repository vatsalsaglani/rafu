import Foundation
import SwiftTreeSitter

/// A lightweight symbol extracted from an open editor buffer.
nonisolated struct BufferSymbol: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case function
        case type
        case heading(level: Int)

        var symbolName: String {
            switch self {
            case .function: "function"
            case .type: "cube"
            case .heading: "number"
            }
        }
    }

    let name: String
    /// Short display context: the matched declaration keyword or heading level.
    let detail: String
    let kind: Kind
    /// UTF-16 range of the symbol name inside the scanned buffer snapshot.
    let range: NSRange
}

/// Pure regex-based symbol extraction for the palette's "@" mode.
/// Intentionally lightweight — no syntax tree, so comments and strings can
/// produce occasional false positives, which is acceptable for jump-to-symbol.
nonisolated enum BufferSymbolScanner {
    static let symbolLimit = 2_000

    static func scan(
        text: String,
        fileExtension: String,
        limit: Int = symbolLimit
    ) -> [BufferSymbol] {
        guard limit > 0, !text.isEmpty else { return [] }
        if markdownExtensions.contains(fileExtension) {
            return scanMarkdownHeadings(in: text, limit: limit)
        }
        return scanDeclarations(in: text, fileExtension: fileExtension, limit: limit)
    }

    // MARK: - Grammar-backed extraction (increment 9)

    /// Grammar-backed symbol extraction for the palette's "@" mode, using
    /// `grammarID`'s vendored `tags.scm` (plan §7.3/§7.9) instead of regex.
    /// Returns `nil` — never `[]` — when the grammar has no vendored
    /// `tags.scm`, failed to build, or its `Language` rejects the parser, so
    /// the caller can fall back to `scan(text:fileExtension:limit:)`; an
    /// empty array is a legitimate "parsed fine, no definitions found"
    /// result and must not be confused with "try the regex path instead".
    ///
    /// One-shot: builds its own `Parser` and parses `text` once (lane-1
    /// increment 9 deliberately does not reuse the live editor's incremental
    /// `SyntaxParsingActor` tree — out of scope here). `tags.scm` predicates
    /// (`#not-eq? @name "constructor"`, `#not-match? @name "^(require)$"`,
    /// …) ARE evaluated: `cursor.resolve(with:)` (the non-deprecated
    /// `ResolvingQueryMatchSequence` API) is prepared with a
    /// `Predicate.Context(string:)` text provider over the same snapshot, so
    /// a JavaScript/TypeScript constructor or `require()` reference is
    /// correctly excluded rather than showing up as a false symbol.
    static func scanUsingGrammar(
        text: String,
        grammarID: GrammarLanguageID,
        limit: Int = symbolLimit
    ) async -> [BufferSymbol]? {
        guard limit > 0, !text.isEmpty else { return [] }

        guard let query = await GrammarRegistry.shared.tagsQuery(for: grammarID),
            let configuration = try? await GrammarRegistry.shared.configuration(for: grammarID)
        else { return nil }

        // Everything from here is synchronous, non-`Sendable` tree-sitter
        // work confined to this call — no further `await` touches `parser`,
        // `tree`, or `query`.
        let parser = Parser()
        guard (try? parser.setLanguage(configuration.language)) != nil,
            let tree = parser.parse(text)
        else { return nil }

        let cursor = query.execute(in: tree)
        let context = Predicate.Context(string: text)
        let nsText = text as NSString

        var symbols: [BufferSymbol] = []
        for match in cursor.resolve(with: context) {
            guard let symbol = symbol(from: match, text: nsText) else { continue }
            symbols.append(symbol)
            if symbols.count >= limit { break }
        }
        return symbols
    }

    /// Builds a `BufferSymbol` from one resolved `tags.scm` match, or `nil`
    /// when the match has no `@name` capture, no `@definition.*` capture, or
    /// its definition kind isn't one `BufferSymbol.Kind` covers.
    /// `@reference.*` matches (call sites, type references, `new` targets)
    /// and `@definition.property`/`.constant`/`.module` are intentionally
    /// skipped — `BufferSymbol.Kind` stays function/type/heading this
    /// increment (see the phase plan's noted outline gap).
    private static func symbol(from match: QueryMatch, text: NSString) -> BufferSymbol? {
        guard let nameCapture = match.captures(named: "name").first else { return nil }
        guard
            let definitionCapture = match.captures.first(where: {
                $0.name?.hasPrefix("definition.") == true
            }),
            let definitionName = definitionCapture.name
        else { return nil }

        let kindSuffix = String(definitionName.dropFirst("definition.".count))
        let kind: BufferSymbol.Kind
        switch kindSuffix {
        case "function", "method":
            kind = .function
        case "class", "interface":
            kind = .type
        default:
            // property/constant/module (and anything future grammars add)
            // are skipped rather than mis-kinded.
            return nil
        }

        let range = nameCapture.range
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        return BufferSymbol(
            name: text.substring(with: range),
            detail: kindSuffix,
            kind: kind,
            range: range
        )
    }

    // MARK: - Declarations

    private struct LanguageRules {
        let functionKeywords: [String]
        let typeKeywords: [String]
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    private static let defaultRules = LanguageRules(
        functionKeywords: ["func", "def", "function", "fn", "fun"],
        typeKeywords: [
            "class", "struct", "enum", "protocol", "actor", "extension",
            "interface", "trait", "impl",
        ]
    )

    private static let rulesByExtension: [String: LanguageRules] = {
        let swift = LanguageRules(
            functionKeywords: ["func"],
            typeKeywords: ["class", "struct", "enum", "protocol", "actor", "extension"]
        )
        let javascript = LanguageRules(functionKeywords: ["function"], typeKeywords: ["class"])
        let typescript = LanguageRules(
            functionKeywords: ["function"],
            typeKeywords: ["class", "interface", "enum"]
        )
        let python = LanguageRules(functionKeywords: ["def"], typeKeywords: ["class"])
        return [
            "swift": swift,
            "py": python,
            "rb": LanguageRules(functionKeywords: ["def"], typeKeywords: ["class", "module"]),
            "js": javascript,
            "jsx": javascript,
            "mjs": javascript,
            "ts": typescript,
            "tsx": typescript,
            "rs": LanguageRules(
                functionKeywords: ["fn"],
                typeKeywords: ["struct", "enum", "trait", "impl"]
            ),
            "go": LanguageRules(functionKeywords: ["func"], typeKeywords: ["type"]),
            "kt": LanguageRules(
                functionKeywords: ["fun"],
                typeKeywords: ["class", "interface", "object"]
            ),
        ]
    }()

    private static func scanDeclarations(
        in text: String,
        fileExtension: String,
        limit: Int
    ) -> [BufferSymbol] {
        let rules = rulesByExtension[fileExtension] ?? defaultRules
        let keywords = rules.functionKeywords + rules.typeKeywords
        let functionKeywords = Set(rules.functionKeywords)
        let pattern =
            #"\b("# + keywords.joined(separator: "|") + #")\s+([A-Za-z_][A-Za-z0-9_.]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        var symbols: [BufferSymbol] = []
        expression.enumerateMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) { result, _, stop in
            guard let result, result.numberOfRanges == 3 else { return }
            let keyword = nsText.substring(with: result.range(at: 1))
            let nameRange = result.range(at: 2)
            symbols.append(
                BufferSymbol(
                    name: nsText.substring(with: nameRange),
                    detail: keyword,
                    kind: functionKeywords.contains(keyword) ? .function : .type,
                    range: nameRange
                )
            )
            if symbols.count >= limit { stop.pointee = true }
        }
        return symbols
    }

    // MARK: - Markdown

    private static func scanMarkdownHeadings(in text: String, limit: Int) -> [BufferSymbol] {
        let pattern = #"(?m)^(#{1,6})\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        var symbols: [BufferSymbol] = []
        expression.enumerateMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) { result, _, stop in
            guard let result, result.numberOfRanges == 3 else { return }
            let level = result.range(at: 1).length
            let nameRange = result.range(at: 2)
            let name = nsText.substring(with: nameRange)
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            symbols.append(
                BufferSymbol(
                    name: name,
                    detail: "H\(level)",
                    kind: .heading(level: level),
                    range: nameRange
                )
            )
            if symbols.count >= limit { stop.pointee = true }
        }
        return symbols
    }
}
