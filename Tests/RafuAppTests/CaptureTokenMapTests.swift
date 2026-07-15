import Testing

@testable import RafuApp

/// Data-level proof for the full plan §7.3 capture→token table (lane-1
/// increment 9). Every row is driven off the actual `RafuTheme.syntax` key
/// set (`RafuThemeCatalog.indigo`) so the test fails if a theme regresses a
/// key the table depends on — never a hand-maintained duplicate list.
@Suite("CaptureTokenMap")
@MainActor
struct CaptureTokenMapTests {
    private static let themeSyntaxKeys = Set(RafuThemeCatalog.indigo.syntax.keys)

    /// Plan §7.3, verbatim capture names as documented (each cell split on
    /// `,`/`/` into individual captures). `nonisolated` so `@Test`'s
    /// `arguments:` — evaluated outside the suite's actor — can read it.
    nonisolated private static let planRows: [(capture: String, token: String)] = [
        ("comment", "comment"),
        ("comment.documentation", "docComment"),
        ("string", "string"),
        ("string.special", "string"),
        ("string.escape", "escape"),
        ("number", "number"),
        ("float", "number"),
        ("constant", "constant"),
        ("constant.builtin", "constant"),
        ("boolean", "constant"),
        ("keyword", "keyword"),
        ("keyword.control", "keyword"),
        ("operator", "operator"),
        ("punctuation.bracket", "punctuation"),
        ("punctuation.delimiter", "punctuation"),
        ("function", "function"),
        ("function.call", "function"),
        ("function.method", "function"),
        ("type", "type"),
        ("type.builtin", "type"),
        ("variable", "variable"),
        ("variable.parameter", "parameter"),
        ("property", "property"),
        ("field", "property"),
        ("tag", "tag"),
        ("attribute", "attribute"),
        ("tag.attribute", "attribute"),
        ("namespace", "namespace"),
        ("module", "namespace"),
        ("markup.heading", "markup.heading"),
        ("markup.bold", "markup.bold"),
        ("markup.italic", "markup.italic"),
        ("markup.link", "markup.link"),
        ("markup.link.url", "markup.link"),
        ("markup.raw", "markup.code"),
        ("markup.quote", "markup.quote"),
        ("markup.list", "markup.list"),
    ]

    @Test("Every §7.3 capture maps to its documented theme token", arguments: planRows)
    func planRowMapsToDocumentedToken(row: (capture: String, token: String)) {
        #expect(CaptureTokenMap.themeKey(forCapture: row.capture) == row.token)
    }

    @Test("Every mapped token is an existing RafuTheme.syntax key")
    func everyMappedTokenExistsInTheme() {
        for (capture, expected) in Self.planRows {
            guard let token = CaptureTokenMap.themeKey(forCapture: capture) else {
                Issue.record("\(capture) resolved to nil")
                continue
            }
            #expect(
                Self.themeSyntaxKeys.contains(token),
                "\(capture) → \(token), but \(token) is not a RafuTheme.syntax key")
            #expect(token == expected)
        }
    }

    @Test("Hierarchical fallback: an unlisted dotted capture resolves via its parent")
    func hierarchicalFallbackDropsTrailingComponents() {
        // Not listed verbatim, but must resolve via progressively shorter
        // prefixes: keyword.control.conditional -> keyword.control -> keyword.
        #expect(CaptureTokenMap.themeKey(forCapture: "keyword.control.conditional") == "keyword")
        #expect(CaptureTokenMap.themeKey(forCapture: "punctuation.special") == "punctuation")
        #expect(CaptureTokenMap.themeKey(forCapture: "function.builtin") == "function")
        #expect(CaptureTokenMap.themeKey(forCapture: "string.special.key") == "string")
    }

    @Test("An exact dotted row wins over its broader root")
    func exactRowBeatsRootFallback() {
        // string.escape must resolve to `escape`, not fall through to the
        // `string` root's `string` token.
        #expect(CaptureTokenMap.themeKey(forCapture: "string.escape") == "escape")
        // tag.attribute must resolve to `attribute`, not the `tag` root.
        #expect(CaptureTokenMap.themeKey(forCapture: "tag.attribute") == "attribute")
    }

    @Test("Superset entries kept from 8a's SyntaxCaptureMap still resolve")
    func supersetEntriesStillResolve() {
        #expect(CaptureTokenMap.themeKey(forCapture: "comment.documentation") == "docComment")
        #expect(CaptureTokenMap.themeKey(forCapture: "constructor") == "type")
        #expect(CaptureTokenMap.themeKey(forCapture: "variable.member") == "property")
    }

    @Test("An unknown capture at any depth returns nil")
    func unknownCaptureReturnsNil() {
        #expect(CaptureTokenMap.themeKey(forCapture: "spell") == nil)
        #expect(CaptureTokenMap.themeKey(forCapture: "embedded") == nil)
        #expect(CaptureTokenMap.themeKey(forCapture: "text.title.deep") == nil)
    }
}
