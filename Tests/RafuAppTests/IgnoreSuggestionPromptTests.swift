import Testing

@testable import RafuApp

@Suite("Ignore suggestion prompt")
struct IgnoreSuggestionPromptTests {
    @Test("Instructions name the requested kind's content tag")
    func instructionsNameTag() {
        let builder = IgnoreSuggestionPromptBuilder()
        #expect(builder.instructions(for: .gitignore).contains("<gitignore>"))
        #expect(builder.instructions(for: .dockerignore).contains("<dockerignore>"))
    }

    @Test("The prompt wraps the tree and existing content in inert, untrusted-data blocks")
    func promptWrapsBlocks() {
        let builder = IgnoreSuggestionPromptBuilder()
        let prompt = builder.makePrompt(
            kind: .gitignore, tree: "src/\n  main.swift", existingContent: "*.log"
        )
        #expect(prompt.contains("<file-tree>"))
        #expect(prompt.contains("src/\n  main.swift"))
        #expect(prompt.contains("</file-tree>"))
        #expect(prompt.contains("<existing-ignore>"))
        #expect(prompt.contains("*.log"))
        #expect(prompt.contains("</existing-ignore>"))
        #expect(prompt.contains("inert"))
        // The untrusted-data directive itself lives in `instructions(for:)`,
        // mirroring `AICommitPromptBuilder`'s own instruction/prompt split.
        #expect(builder.instructions(for: .gitignore).contains("untrusted"))
    }

    @Test("Oversized tree and existing-ignore content are bounded")
    func boundedBlocks() {
        let builder = IgnoreSuggestionPromptBuilder()
        let hugeTree = String(repeating: "a", count: 200_000)
        let hugeExisting = String(repeating: "b", count: 200_000)
        let prompt = builder.makePrompt(
            kind: .gitignore, tree: hugeTree, existingContent: hugeExisting)
        #expect(prompt.utf8.count < 200_000)
    }

    @Test("A well-formed reply parses content and tab-separated reasons")
    func wellFormedReply() {
        let reply = """
            <gitignore>
            node_modules/
            *.log
            </gitignore>
            <reasons>
            node_modules/\tDependency directory, never committed.
            *.log\tGenerated log output.
            </reasons>
            """
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.content == "node_modules/\n*.log")
        #expect(proposed.reasons.count == 2)
        #expect(proposed.reasons[0].pattern == "node_modules/")
        #expect(proposed.reasons[0].reason == "Dependency directory, never committed.")
        #expect(proposed.reasons[1].pattern == "*.log")
    }

    @Test("The dockerignore tag is used for the dockerignore kind")
    func dockerignoreTag() {
        let reply = """
            <dockerignore>
            .git
            </dockerignore>
            """
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .dockerignore)
        #expect(proposed.content == ".git")
    }

    @Test("A missing reasons block parses to an empty reasons array")
    func missingReasonsBlock() {
        let reply = "<gitignore>\n*.log\n</gitignore>"
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.content == "*.log")
        #expect(proposed.reasons.isEmpty)
    }

    @Test("Markdown code fences around the tagged content are stripped")
    func stripsMarkdownFences() {
        let reply = """
            <gitignore>
            ```
            *.log
            build/
            ```
            </gitignore>
            """
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.content == "*.log\nbuild/")
    }

    @Test("A fenced reply with no tags at all still parses via the fence fallback")
    func fencedFallbackWithNoTags() {
        let reply = """
            Sure, here you go:
            ```gitignore
            *.log
            ```
            """
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.content == "*.log")
    }

    @Test("A reasons line without a tab falls back to an em-dash separator")
    func emDashFallback() {
        let reply = """
            <gitignore>
            *.log
            </gitignore>
            <reasons>
            *.log — Generated log output.
            </reasons>
            """
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.reasons.count == 1)
        #expect(proposed.reasons[0].pattern == "*.log")
        #expect(proposed.reasons[0].reason == "Generated log output.")
    }

    @Test("A reasons line with neither a tab nor an em dash is skipped, never crashes")
    func malformedReasonLineSkipped() {
        let reply = """
            <gitignore>
            *.log
            </gitignore>
            <reasons>
            this line has no separator at all
            *.log\tGenerated log output.
            </reasons>
            """
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.reasons.count == 1)
        #expect(proposed.reasons[0].pattern == "*.log")
    }

    @Test(
        "Completely malformed, tagless, unfenced input never crashes and yields best-effort content"
    )
    func completelyMalformedInput() {
        let proposed = IgnoreSuggestionResponseParser.parse(
            "not a structured reply at all", kind: .gitignore)
        #expect(proposed.content == "not a structured reply at all")
        #expect(proposed.reasons.isEmpty)
    }

    @Test("Empty input never crashes")
    func emptyInput() {
        let proposed = IgnoreSuggestionResponseParser.parse("", kind: .gitignore)
        #expect(proposed.content.isEmpty)
        #expect(proposed.reasons.isEmpty)
    }

    @Test("An excessive reasons count is bounded")
    func boundedReasonCount() {
        let lines = (1...500).map { "pattern\($0)\treason\($0)" }
        let reply =
            "<gitignore>\n*.log\n</gitignore>\n<reasons>\n\(lines.joined(separator: "\n"))\n</reasons>"
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.reasons.count == IgnoreSuggestionResponseParser.maximumReasonCount)
    }

    @Test("Oversized content is bounded")
    func boundedContentBytes() {
        let hugeContent = String(repeating: "a", count: 100_000)
        let reply = "<gitignore>\n\(hugeContent)\n</gitignore>"
        let proposed = IgnoreSuggestionResponseParser.parse(reply, kind: .gitignore)
        #expect(proposed.content.utf8.count <= IgnoreSuggestionResponseParser.maximumContentBytes)
    }
}
