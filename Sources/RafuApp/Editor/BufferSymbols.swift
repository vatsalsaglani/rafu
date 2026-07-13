import Foundation

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
