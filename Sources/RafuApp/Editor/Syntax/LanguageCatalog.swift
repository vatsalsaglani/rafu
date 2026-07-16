import Foundation

/// Canonical extension/info-string → language identifier tables backing
/// `LanguageIdentifier.forURL(_:)` and `GrammarLanguageID.languageID(
/// forExtension:fileName:)` / `languageID(forInfoString:)`. Those three
/// entry points were independently maintained parallel `switch` statements
/// that happened to agree wherever their coverage overlapped; this catalog
/// merges them into one source of truth so future language additions touch a
/// single table instead of three. Pure data, no isolation.
///
/// `SyntaxHighlighter`'s regex-based language detection
/// (`Sources/RafuApp/Editor/SyntaxHighlighter.swift`) is intentionally NOT
/// unified here — its groupings cover non-grammar languages (Rust, Go, Ruby,
/// Java, Kotlin, SQL, the C family, C#, PHP) and non-grammar concepts (HTML,
/// XML, CSS, INI, dotenv, Makefile) that don't correspond to a
/// `GrammarLanguageID`, and folding it in would risk changing its regex
/// output, which `EditorSyntaxHighlighterTests` pins.
nonisolated enum LanguageCatalog {
    /// One extension's LSP `languageId` and/or packaged tree-sitter grammar.
    /// Either field may be `nil` — an extension can have a grammar with no
    /// LSP server integration yet (e.g. `toml`) or an LSP `languageId` with
    /// no packaged grammar (e.g. `rs`); those are intentional asymmetries
    /// preserved from the pre-catalog tables, not gaps to fill in here.
    struct Mapping: Sendable {
        let grammarID: GrammarLanguageID?
        let lspID: String?
    }

    /// Lowercased file extension → `Mapping`. Merges `LanguageIdentifier`'s
    /// former extension table with `GrammarLanguageID`'s former extension
    /// table; every asymmetric row (grammar-only, LSP-only, or where the two
    /// axes disagree, e.g. `tsx`/`jsx`) is intentional — see the type doc.
    static let byExtension: [String: Mapping] = [
        "swift": Mapping(grammarID: .swift, lspID: "swift"),
        "rs": Mapping(grammarID: nil, lspID: "rust"),
        "go": Mapping(grammarID: nil, lspID: "go"),
        "ts": Mapping(grammarID: .typescript, lspID: "typescript"),
        "tsx": Mapping(grammarID: .tsx, lspID: "typescriptreact"),
        "js": Mapping(grammarID: .javascript, lspID: "javascript"),
        "mjs": Mapping(grammarID: .javascript, lspID: "javascript"),
        "cjs": Mapping(grammarID: .javascript, lspID: "javascript"),
        "jsx": Mapping(grammarID: .javascript, lspID: "javascriptreact"),
        "py": Mapping(grammarID: .python, lspID: "python"),
        "pyw": Mapping(grammarID: .python, lspID: nil),
        "c": Mapping(grammarID: nil, lspID: "c"),
        "h": Mapping(grammarID: nil, lspID: "c"),
        "cpp": Mapping(grammarID: nil, lspID: "cpp"),
        "cc": Mapping(grammarID: nil, lspID: "cpp"),
        "cxx": Mapping(grammarID: nil, lspID: "cpp"),
        "hpp": Mapping(grammarID: nil, lspID: "cpp"),
        "md": Mapping(grammarID: .markdown, lspID: "markdown"),
        "markdown": Mapping(grammarID: .markdown, lspID: "markdown"),
        "json": Mapping(grammarID: .json, lspID: "json"),
        "jsonc": Mapping(grammarID: .json, lspID: nil),
        "yaml": Mapping(grammarID: .yaml, lspID: "yaml"),
        "yml": Mapping(grammarID: .yaml, lspID: "yaml"),
        "toml": Mapping(grammarID: .toml, lspID: nil),
        "sh": Mapping(grammarID: .bash, lspID: nil),
        "bash": Mapping(grammarID: .bash, lspID: nil),
        "zsh": Mapping(grammarID: .bash, lspID: nil),
    ]

    /// Trimmed, lowercased Markdown fenced-code-block info string → grammar.
    /// A distinct namespace from `byExtension`: info strings use language
    /// names/common aliases (`python`, `shell`), not file extensions, so a
    /// key colliding with an extension (e.g. `md`) is not expected to
    /// resolve here, and vice versa (e.g. `mjs`, `zsh`, `jsonc`).
    /// `markdownInline` is never a value here — it is an injection-only
    /// secondary grammar.
    static let byInfoString: [String: GrammarLanguageID] = [
        "swift": .swift,
        "python": .python,
        "py": .python,
        "javascript": .javascript,
        "js": .javascript,
        "jsx": .javascript,
        "typescript": .typescript,
        "ts": .typescript,
        "tsx": .tsx,
        "json": .json,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "bash": .bash,
        "sh": .bash,
        "shell": .bash,
    ]

    /// The one filename-based special case (Dockerfile) that wins over
    /// extension-based lookup in `GrammarLanguageID.languageID(
    /// forExtension:fileName:)`. `LanguageIdentifier.forURL(_:)` never
    /// consults filenames, so it never calls this. Returns `nil` when `name`
    /// (expected already-lowercased) isn't a Dockerfile filename.
    static func mapping(forFileName name: String) -> Mapping? {
        guard name == "dockerfile" || name.hasPrefix("dockerfile.") else {
            return nil
        }
        return Mapping(grammarID: .dockerfile, lspID: nil)
    }
}
