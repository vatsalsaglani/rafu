import AppKit
import Foundation
import Testing

@testable import RafuApp

@MainActor
@Test("Neon token provider emits themed repository-language tokens")
func neonTokenProviderEmitsThemeTokens() throws {
    let source = "let count = 42 // repaired\n"
    let highlighter = SyntaxHighlighter(theme: RafuThemeCatalog.indigo, fileExtension: "swift")

    let application = highlighter.tokenApplication(
        in: source,
        targetRange: NSRange(location: 0, length: (source as NSString).length)
    )

    #expect(application.tokens.contains(where: { $0.name == "keyword" }))
    #expect(application.tokens.contains(where: { $0.name == "number" }))
    #expect(application.tokens.contains(where: { $0.name == "comment" }))

    let keyword = try #require(application.tokens.first(where: { $0.name == "keyword" }))
    let attributes = highlighter.attributes(for: keyword)
    #expect(attributes[.foregroundColor] is NSColor)
}

@MainActor
@Test("Neon pipeline accepts edits and theme invalidation without owning live text")
func neonPipelineUsesTextViewStorage() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let textView = NSTextView(frame: scrollView.bounds)
    scrollView.documentView = textView
    textView.string = "func mend() { return }"

    let pipeline = NeonSyntaxHighlightingPipeline(
        textView: textView,
        theme: RafuThemeCatalog.indigo,
        fileExtension: "swift"
    )
    let previousLength = textView.string.utf16.count
    textView.textStorage?.append(NSAttributedString(string: " "))
    pipeline.didProcessEditing(
        editedMask: .editedCharacters,
        editedRange: NSRange(location: previousLength, length: 1),
        changeInLength: 1
    )
    pipeline.update(theme: RafuThemeCatalog.khadi, fileExtension: "swift")

    #expect(textView.string == "func mend() { return } ")
}

@MainActor
@Test("Extension-sensitive rules cover common source and configuration languages")
func extensionSensitiveSyntaxRules() {
    let theme = RafuThemeCatalog.indigo
    let cases: [(SyntaxHighlighter, String, String)] = [
        (SyntaxHighlighter(theme: theme, fileExtension: "py"), "def mend(): pass", "function"),
        (SyntaxHighlighter(theme: theme, fileExtension: "js"), "function mend() {}", "function"),
        (SyntaxHighlighter(theme: theme, fileExtension: "rs"), "fn mend() {}", "function"),
        (SyntaxHighlighter(theme: theme, fileExtension: "go"), "package main", "keyword"),
        (SyntaxHighlighter(theme: theme, fileExtension: "html"), "<main id=\"app\">", "tag"),
        (SyntaxHighlighter(theme: theme, fileExtension: "css"), "color: red;", "property"),
        (SyntaxHighlighter(theme: theme, fileExtension: "yaml"), "theme: indigo", "property"),
        (
            SyntaxHighlighter(theme: theme, fileExtension: "", fileName: "Dockerfile"),
            "FROM swift:latest", "keyword"
        ),
    ]

    for (highlighter, source, expectedToken) in cases {
        let tokens = highlighter.tokenApplication(
            in: source,
            targetRange: NSRange(location: 0, length: source.utf16.count)
        ).tokens
        #expect(tokens.contains(where: { $0.name == expectedToken }))
    }
}
