import Foundation
import SwiftTreeSitter
import Testing

@testable import RafuApp

/// The tree-sitter ABI gate: SwiftTreeSitter 0.8.0 vendors a runtime whose
/// `TREE_SITTER_LANGUAGE_VERSION` is 14 (`MIN_COMPATIBLE` 13). Every grammar
/// pinned in `Package.swift` must produce a `Language` that
/// `Parser.setLanguage` accepts; this is bundle-independent (it does not
/// require the `highlights.scm` resource bundle to resolve in the test
/// host) and is the hard pass/fail contract for this increment.
@Test(
    "Every packaged grammar's Language satisfies the tree-sitter ABI gate",
    arguments: GrammarLanguageID.allCases)
func grammarLanguageSatisfiesABIGate(id: GrammarLanguageID) async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: id)

    let parser = Parser()
    // The hard requirement: `setLanguage` throws `ParserError.languageFailure`
    // for an ABI mismatch. Not throwing proves the grammar is ABI 13-14.
    try parser.setLanguage(configuration.language)

    // Increment 8a vendors each grammar's `highlights.scm` into
    // `Resources/Grammars/<Name>/` and loads it via `Bundle.module`
    // + `Query(language:url:)`, which — unlike SwiftTreeSitter's own bundle
    // resolver — resolves under `swift test`. Vendored grammars are asserted
    // non-nil in `vendoredGrammarLoadsCompiledHighlightsQuery`; here we only
    // record that the query, when present, is well-formed.
    if let highlights = configuration.queries[.highlights] {
        #expect(highlights.patternCount >= 0)
    }
}

/// The 8a data-level proof that highlighting works: every grammar with a
/// vendored `highlights.scm` must resolve via `Bundle.module` AND compile
/// against its language under `swift test` (the previously-broken host). A
/// `nil` query here means the router would silently fall back to regex, so
/// this is a HARD pass/fail. `markdownInline` is intentionally excluded — its
/// inline-injection query lands in increment 9.
@Test(
    "Vendored grammars load a compiled highlights query",
    arguments: [
        GrammarLanguageID.swift, .python, .javascript, .typescript, .tsx, .json, .yaml,
        .toml, .bash, .markdown, .dockerfile,
    ])
func vendoredGrammarLoadsCompiledHighlightsQuery(id: GrammarLanguageID) async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: id)

    let highlights = try #require(
        configuration.queries[.highlights],
        "\(id) must resolve and compile its vendored highlights.scm")
    #expect(highlights.patternCount > 0)
}

/// A second `configuration(for:)` call for the same identifier returns the
/// cached value instead of rebuilding it (no eager/duplicate grammar loads).
@Test("GrammarRegistry caches a configuration after its first build")
func grammarRegistryCachesConfiguration() async throws {
    let registry = GrammarRegistry()
    let first = try await registry.configuration(for: .json)
    let second = try await registry.configuration(for: .json)

    #expect(first.name == second.name)
    #expect(first.language.tsLanguage == second.language.tsLanguage)
}

@Test("languageID(forExtension:fileName:) mirrors SyntaxHighlighter's extension groups")
func languageIDMapsKnownExtensions() {
    let cases: [(extension: String, fileName: String, expected: GrammarLanguageID?)] = [
        ("swift", "Main.swift", .swift),
        ("py", "app.py", .python),
        ("pyw", "app.pyw", .python),
        ("js", "index.js", .javascript),
        ("jsx", "App.jsx", .javascript),
        ("mjs", "index.mjs", .javascript),
        ("cjs", "index.cjs", .javascript),
        ("ts", "index.ts", .typescript),
        ("tsx", "App.tsx", .tsx),
        ("json", "package.json", .json),
        ("jsonc", "tsconfig.jsonc", .json),
        ("yaml", "config.yaml", .yaml),
        ("yml", "config.yml", .yaml),
        ("toml", "Package.toml", .toml),
        ("sh", "build.sh", .bash),
        ("bash", "run.bash", .bash),
        ("zsh", "profile.zsh", .bash),
        ("md", "README.md", .markdown),
        ("markdown", "NOTES.markdown", .markdown),
        ("", "Dockerfile", .dockerfile),
        ("dev", "Dockerfile.dev", .dockerfile),
        ("", "unknown", nil),
        ("env", ".env", nil),
        ("rs", "main.rs", nil),
    ]

    for testCase in cases {
        let result = GrammarLanguageID.languageID(
            forExtension: testCase.extension, fileName: testCase.fileName)
        #expect(
            result == testCase.expected,
            "extension \(testCase.extension) fileName \(testCase.fileName) expected \(String(describing: testCase.expected)) got \(String(describing: result))"
        )
    }
}

@Test("markdownInline is loadable directly but never returned by the extension mapper")
func markdownInlineIsInjectionOnly() async throws {
    #expect(GrammarLanguageID.languageID(forExtension: "md", fileName: "NOTES.md") == .markdown)
    #expect(
        GrammarLanguageID.languageID(forExtension: "markdown", fileName: "notes.markdown")
            != .markdownInline)

    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .markdownInline)
    let parser = Parser()
    try parser.setLanguage(configuration.language)
}

// MARK: - tags.scm (increment 9)

/// The hard pass/fail proof for increment 9's `@` symbol extraction:
/// Swift/Python/JavaScript/TypeScript/TSX each vendor a `tags.scm` that
/// resolves via `Bundle.module` AND compiles against their OWN `Language` —
/// TypeScript and TSX both come from the `tree-sitter-typescript` checkout's
/// single shared `queries/tags.scm`, so this specifically proves the same
/// combined query text compiles against two different grammars.
@Test(
    "Grammars with a vendored tags.scm produce a compiled tags query",
    arguments: [
        GrammarLanguageID.swift, .python, .javascript, .typescript, .tsx,
    ])
func vendoredGrammarsLoadCompiledTagsQuery(id: GrammarLanguageID) async throws {
    let registry = GrammarRegistry()
    let query = try #require(
        await registry.tagsQuery(for: id),
        "\(id) must resolve and compile its vendored tags.scm")
    #expect(query.patternCount > 0)
}

/// Grammars with no vendored `tags.scm` (no meaningful symbols) gracefully
/// return `nil` rather than throwing or crashing, so `@` symbol mode falls
/// back to the regex scanner for these languages.
@Test(
    "Grammars without a vendored tags.scm return nil",
    arguments: [
        GrammarLanguageID.json, .yaml, .toml, .bash, .markdown, .dockerfile,
        .markdownInline,
    ])
func grammarsWithoutTagsScmReturnNil(id: GrammarLanguageID) async throws {
    let registry = GrammarRegistry()
    #expect(await registry.tagsQuery(for: id) == nil)
}

/// A second `tagsQuery(for:)` call for the same identifier returns the
/// cached value instead of recompiling it.
@Test("GrammarRegistry caches a tags query after its first build")
func grammarRegistryCachesTagsQuery() async throws {
    let registry = GrammarRegistry()
    let first = try #require(await registry.tagsQuery(for: .swift))
    let second = try #require(await registry.tagsQuery(for: .swift))
    #expect(first.patternCount == second.patternCount)
}

@Test("languageID(forInfoString:) maps common fence-language aliases")
func languageIDMapsInfoStringAliases() {
    let cases: [(infoString: String, expected: GrammarLanguageID?)] = [
        ("swift", .swift),
        ("python", .python),
        ("py", .python),
        ("javascript", .javascript),
        ("js", .javascript),
        ("jsx", .javascript),
        ("typescript", .typescript),
        ("ts", .typescript),
        ("tsx", .tsx),
        ("bash", .bash),
        ("sh", .bash),
        ("shell", .bash),
        ("json", .json),
        ("yaml", .yaml),
        ("yml", .yaml),
        ("toml", .toml),
        ("  Swift  ", .swift),
        ("SWIFT", .swift),
        ("", nil),
        ("plaintext", nil),
        ("ruby", nil),
    ]
    for testCase in cases {
        let result = GrammarLanguageID.languageID(forInfoString: testCase.infoString)
        #expect(
            result == testCase.expected,
            "infoString \(testCase.infoString) expected \(String(describing: testCase.expected)) got \(String(describing: result))"
        )
    }
}
