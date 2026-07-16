import Foundation
import Testing

@testable import RafuApp

/// Cross-consistency pin for the `LanguageCatalog` refactor (post-merge
/// validation batch C): asserts the three PUBLIC entry points —
/// `LanguageIdentifier.forURL(_:)`, `GrammarLanguageID.languageID(
/// forExtension:fileName:)`, and `GrammarLanguageID.languageID(
/// forInfoString:)` — against hardcoded golden literals rather than the
/// catalog itself, so the test is meaningful before and after the catalog
/// exists. It intentionally captures the cross-axis asymmetries between the
/// LSP-language and grammar-language tables (e.g. `tsx`/`jsx` diverge across
/// the two axes, some extensions have a grammar but no LSP id or vice versa)
/// — none of these are bugs, and this test must keep passing unmodified
/// through the internal refactor that introduces `LanguageCatalog`.
@Test(
    "forURL and forExtension agree on shared extensions",
    arguments: [
        ("swift", "swift", GrammarLanguageID.swift),
        ("ts", "typescript", GrammarLanguageID.typescript),
        ("tsx", "typescriptreact", GrammarLanguageID.tsx),
        ("js", "javascript", GrammarLanguageID.javascript),
        ("mjs", "javascript", GrammarLanguageID.javascript),
        ("cjs", "javascript", GrammarLanguageID.javascript),
        ("jsx", "javascriptreact", GrammarLanguageID.javascript),
        ("py", "python", GrammarLanguageID.python),
        ("md", "markdown", GrammarLanguageID.markdown),
        ("markdown", "markdown", GrammarLanguageID.markdown),
        ("json", "json", GrammarLanguageID.json),
        ("yaml", "yaml", GrammarLanguageID.yaml),
        ("yml", "yaml", GrammarLanguageID.yaml),
    ]
)
func sharedExtensionsAgreeAcrossLspAndGrammarTables(
    ext: String, expectedLspID: String, expectedGrammarID: GrammarLanguageID
) {
    let url = URL(fileURLWithPath: "/workspace/file.\(ext)")
    #expect(LanguageIdentifier.forURL(url) == expectedLspID)
    #expect(
        GrammarLanguageID.languageID(forExtension: ext, fileName: "file.\(ext)")
            == expectedGrammarID)
}

@Test(
    "LSP-only extensions resolve for forURL but decline for forExtension",
    arguments: [
        "rs", "go", "c", "h", "cpp", "cc", "cxx", "hpp",
    ]
)
func lspOnlyExtensionsHaveNoGrammar(ext: String) {
    let url = URL(fileURLWithPath: "/workspace/file.\(ext)")
    #expect(LanguageIdentifier.forURL(url) != nil)
    #expect(GrammarLanguageID.languageID(forExtension: ext, fileName: "file.\(ext)") == nil)
}

@Test(
    "Grammar-only extensions resolve for forExtension but decline for forURL",
    arguments: [
        ("pyw", GrammarLanguageID.python),
        ("jsonc", GrammarLanguageID.json),
        ("toml", GrammarLanguageID.toml),
        ("sh", GrammarLanguageID.bash),
        ("bash", GrammarLanguageID.bash),
        ("zsh", GrammarLanguageID.bash),
    ]
)
func grammarOnlyExtensionsHaveNoLspID(ext: String, expectedGrammarID: GrammarLanguageID) {
    let url = URL(fileURLWithPath: "/workspace/file.\(ext)")
    #expect(LanguageIdentifier.forURL(url) == nil)
    #expect(
        GrammarLanguageID.languageID(forExtension: ext, fileName: "file.\(ext)")
            == expectedGrammarID)
}

@Test("forURL never consults the filename, only the extension")
func forURLIgnoresFileNameSpecialCases() {
    let url = URL(fileURLWithPath: "/workspace/Dockerfile")
    #expect(LanguageIdentifier.forURL(url) == nil)
}

@Test("Dockerfile filename special-case wins over an unrelated extension")
func dockerfileFileNameWinsOverExtension() {
    #expect(
        GrammarLanguageID.languageID(forExtension: "dev", fileName: "Dockerfile.dev")
            == .dockerfile)
    #expect(GrammarLanguageID.languageID(forExtension: "", fileName: "Dockerfile") == .dockerfile)
    #expect(
        GrammarLanguageID.languageID(forExtension: "dev", fileName: "dockerfile.dev")
            == .dockerfile)
}

@Test("forInfoString and forExtension use distinct alias namespaces")
func infoStringAndExtensionNamespacesAreDistinct() {
    // Info-string-only aliases (language names, not extensions).
    #expect(GrammarLanguageID.languageID(forInfoString: "python") == .python)
    #expect(GrammarLanguageID.languageID(forExtension: "python", fileName: "x.python") == nil)

    #expect(GrammarLanguageID.languageID(forInfoString: "javascript") == .javascript)
    #expect(
        GrammarLanguageID.languageID(forExtension: "javascript", fileName: "x.javascript") == nil)

    #expect(GrammarLanguageID.languageID(forInfoString: "typescript") == .typescript)
    #expect(
        GrammarLanguageID.languageID(forExtension: "typescript", fileName: "x.typescript") == nil)

    #expect(GrammarLanguageID.languageID(forInfoString: "shell") == .bash)
    #expect(GrammarLanguageID.languageID(forExtension: "shell", fileName: "x.shell") == nil)

    // Extension-only aliases (not accepted as info-string language names).
    #expect(GrammarLanguageID.languageID(forInfoString: "md") == nil)
    #expect(GrammarLanguageID.languageID(forExtension: "md", fileName: "x.md") == .markdown)

    #expect(GrammarLanguageID.languageID(forInfoString: "mjs") == nil)
    #expect(GrammarLanguageID.languageID(forExtension: "mjs", fileName: "x.mjs") == .javascript)

    #expect(GrammarLanguageID.languageID(forInfoString: "zsh") == nil)
    #expect(GrammarLanguageID.languageID(forExtension: "zsh", fileName: "x.zsh") == .bash)

    #expect(GrammarLanguageID.languageID(forInfoString: "jsonc") == nil)
    #expect(GrammarLanguageID.languageID(forExtension: "jsonc", fileName: "x.jsonc") == .json)
}

@Test("markdownInline is never returned by forExtension or forInfoString")
func markdownInlineNeverSurfacesFromEitherLookup() {
    #expect(GrammarLanguageID.languageID(forExtension: "md", fileName: "x.md") != .markdownInline)
    #expect(
        GrammarLanguageID.languageID(forExtension: "markdown", fileName: "x.markdown")
            != .markdownInline)
    #expect(GrammarLanguageID.languageID(forInfoString: "markdown") != .markdownInline)
}

@Test("forURL and forExtension are both case-insensitive on the extension")
func extensionLookupsAreCaseInsensitive() {
    let url = URL(fileURLWithPath: "/workspace/Main.SWIFT")
    #expect(LanguageIdentifier.forURL(url) == "swift")
    #expect(GrammarLanguageID.languageID(forExtension: "SWIFT", fileName: "Main.SWIFT") == .swift)
}

@Test("forInfoString trims whitespace and is case-insensitive")
func infoStringLookupTrimsAndLowercases() {
    #expect(GrammarLanguageID.languageID(forInfoString: "  Swift  ") == .swift)
    #expect(GrammarLanguageID.languageID(forInfoString: "SWIFT") == .swift)
}

@Test("Unrecognized extensions and info strings decline across all three lookups")
func unrecognizedInputsDeclineEverywhere() {
    let url = URL(fileURLWithPath: "/workspace/notes.txt")
    #expect(LanguageIdentifier.forURL(url) == nil)
    #expect(GrammarLanguageID.languageID(forExtension: "txt", fileName: "notes.txt") == nil)
    #expect(GrammarLanguageID.languageID(forInfoString: "plaintext") == nil)
}
