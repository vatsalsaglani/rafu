import Foundation
import Testing

@testable import RafuApp

@Test("Fenced-code-only hover yields a signature and no documentation")
func hoverParserFencedCodeOnly() {
    let raw = "```swift\nfunc greet(name: String) -> String\n```"
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature == "func greet(name: String) -> String")
    #expect(parsed.documentation == nil)
}

@Test("Code fence followed by a thematic break and prose yields both parts")
func hoverParserFenceBreakProse() {
    let raw = """
        ```swift
        func greet(name: String) -> String
        ```
        ---
        Returns a friendly greeting for `name`.
        """
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature == "func greet(name: String) -> String")
    #expect(parsed.documentation == "Returns a friendly greeting for `name`.")
    #expect(parsed.documentation?.contains("---") == false)
}

@Test("Code fence followed by prose without a thematic break still splits")
func hoverParserFenceProseNoBreak() {
    let raw = """
        ```swift
        func greet(name: String) -> String
        ```
        Returns a friendly greeting for `name`.
        """
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature == "func greet(name: String) -> String")
    #expect(parsed.documentation == "Returns a friendly greeting for `name`.")
}

@Test("Plain text with no fence becomes documentation only")
func hoverParserNoFence() {
    let raw = "Just a plain-text hover with no code block."
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature == nil)
    #expect(parsed.documentation == raw)
}

@Test("Multiple code blocks: the first becomes the signature, the rest fold into documentation")
func hoverParserMultipleFences() {
    let raw = """
        ```swift
        func greet(name: String) -> String
        ```
        See also:
        ```swift
        func farewell(name: String) -> String
        ```
        """
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature == "func greet(name: String) -> String")
    #expect(parsed.documentation?.contains("See also:") == true)
    #expect(parsed.documentation?.contains("func farewell(name: String) -> String") == true)
}

@Test("Empty or whitespace-only input yields no signature and no documentation")
func hoverParserEmptyInput() {
    #expect(
        HoverMarkdownParser.parse("", isMarkdown: true) == .init(signature: nil, documentation: nil)
    )
    #expect(
        HoverMarkdownParser.parse("   \n\n   ", isMarkdown: true)
            == .init(signature: nil, documentation: nil))
}

@Test("isMarkdown false keeps the payload verbatim as documentation, skipping fence parsing")
func hoverParserPlaintextMode() {
    let raw = "```swift\nfunc greet(name: String) -> String\n```"
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: false)
    #expect(parsed.signature == nil)
    #expect(parsed.documentation == raw)
}

@Test("Oversized input keeps signature and documentation individually bounded")
func hoverParserOversizedInput() {
    let hugeSignature = String(repeating: "x", count: 3_000)
    let hugeDocs = String(repeating: "y", count: 3_000)
    let raw = "```swift\n\(hugeSignature)\n```\n---\n\(hugeDocs)"
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature?.count == 2_000)
    #expect(parsed.documentation?.count == 2_000)
}

@Test("A fence with no language tag still yields a clean signature")
func hoverParserFenceNoLanguageTag() {
    let raw = "```\nlet x = 1\n```"
    let parsed = HoverMarkdownParser.parse(raw, isMarkdown: true)
    #expect(parsed.signature == "let x = 1")
    #expect(parsed.documentation == nil)
}
