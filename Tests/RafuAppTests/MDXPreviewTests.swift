import Foundation
import Testing

@testable import RafuApp

// MARK: - Scanner

private func components(_ contents: [MDXContent]) -> [MDXComponentNode] {
    contents.compactMap {
        if case .component(let node) = $0 { return node }
        return nil
    }
}

private func markdownTexts(_ contents: [MDXContent]) -> [String] {
    contents.compactMap {
        if case .markdown(let text) = $0 { return text }
        return nil
    }
}

@Test("MDX scanner splits one component block from surrounding Markdown")
func mdxScannerSingleBlock() {
    let source = """
        # Title

        <Callout type="tip">
        Open the **wireframe**.
        </Callout>

        After.
        """
    let result = MDXBlockScanner().scan(source)
    #expect(result.count == 3)
    let nodes = components(result)
    #expect(nodes.count == 1)
    #expect(nodes[0].name == "Callout")
    #expect(nodes[0].prop("type") == .string("tip"))
    #expect(nodes[0].children == [.markdown("Open the **wireframe**.")])
    let texts = markdownTexts(result)
    #expect(texts[0].contains("# Title"))
    #expect(texts[1].contains("After."))
}

@Test("MDX scanner nests components with different names")
func mdxScannerNestedDifferentNames() {
    let source = """
        <Phase title="Build" status="planned">
        Intro text.

        <Callout type="decision">
        Keep it native.
        </Callout>

        <Svg src="./overview.svg" title="Overview" />
        </Phase>
        """
    let nodes = components(MDXBlockScanner().scan(source))
    #expect(nodes.count == 1)
    let phase = nodes[0]
    #expect(phase.name == "Phase")
    #expect(phase.prop("status") == .string("planned"))
    let inner = components(phase.children)
    #expect(inner.map(\.name) == ["Callout", "Svg"])
    #expect(inner[1].isSelfClosing)
    #expect(inner[1].prop("src") == .string("./overview.svg"))
    #expect(markdownTexts(phase.children).first?.contains("Intro text.") == true)
}

@Test("MDX scanner counts same-name nesting depth")
func mdxScannerSameNameNesting() {
    let source = """
        <Box>
        outer
        <Box>
        inner
        </Box>
        tail
        </Box>
        after
        """
    let result = MDXBlockScanner().scan(source)
    let outer = components(result)
    #expect(outer.count == 1)
    let inner = components(outer[0].children)
    #expect(inner.count == 1)
    #expect(inner[0].children == [.markdown("inner")])
    #expect(markdownTexts(outer[0].children).last?.contains("tail") == true)
    #expect(markdownTexts(result) == ["after"])
}

@Test("MDX scanner reads a self-closing tag on one line")
func mdxScannerSelfClosing() {
    let result = MDXBlockScanner().scan(#"<Svg src="a.svg" caption="A" />"#)
    let nodes = components(result)
    #expect(nodes.count == 1)
    #expect(nodes[0].isSelfClosing)
    #expect(nodes[0].children.isEmpty)
    #expect(nodes[0].prop("caption") == .string("A"))
}

@Test("MDX scanner parses prop forms without evaluating expressions")
func mdxScannerPropForms() {
    let source = """
        <Stat label='Users' value={42} ratio={0.5} live={true} hidden items={["a", "b"]} \
        meta={{"k": 1}} total={a + b} name={"quoted"} />
        """
    let nodes = components(MDXBlockScanner().scan(source))
    #expect(nodes.count == 1)
    let node = nodes[0]
    #expect(node.prop("label") == .string("Users"))
    #expect(node.prop("value") == .number(42))
    #expect(node.prop("ratio") == .number(0.5))
    #expect(node.prop("live") == .bool(true))
    #expect(node.prop("hidden") == .bool(true))
    #expect(node.prop("items") == .json(.array([.string("a"), .string("b")])))
    #expect(node.prop("meta") == .json(.object(["k": .number(1)])))
    #expect(node.prop("total") == .expression("a + b"))
    #expect(node.prop("name") == .string("quoted"))
}

@Test("MDX scanner drops top-level import and export statements only")
func mdxScannerStripsModuleLines() {
    let source = """
        import { Chart } from "./chart"
        import Thing from './thing'
        export const meta = {
          title: "Plan"
        }
        import the rest of this sentence as prose.

        # Body
        """
    let result = MDXBlockScanner().scan(source)
    #expect(components(result).isEmpty)
    let text = markdownTexts(result).joined()
    #expect(!text.contains("Chart"))
    #expect(!text.contains("meta"))
    #expect(!text.contains("title:"))
    #expect(text.contains("import the rest of this sentence"))
    #expect(text.contains("# Body"))
}

@Test("MDX scanner ignores component tags inside fenced code")
func mdxScannerIgnoresFencedTags() {
    let source = """
        ```mdx
        <Callout type="tip">
        Example
        </Callout>
        ```

        ~~~
        <Phase>
        ~~~
        """
    let result = MDXBlockScanner().scan(source)
    #expect(components(result).isEmpty)
    #expect(markdownTexts(result).joined().contains("<Callout type=\"tip\">"))
}

@Test("MDX scanner ignores a closing tag inside fenced code within a block")
func mdxScannerFenceInsideBlock() {
    let source = """
        <Callout>
        ```
        </Callout>
        ```
        </Callout>
        """
    let nodes = components(MDXBlockScanner().scan(source))
    #expect(nodes.count == 1)
    #expect(markdownTexts(nodes[0].children).first?.contains("```\n</Callout>\n```") == true)
}

@Test("MDX scanner keeps an unterminated block as literal Markdown")
func mdxScannerUnterminated() {
    let source = """
        <Callout type="tip">
        No closing tag.
        """
    let result = MDXBlockScanner().scan(source)
    #expect(components(result).isEmpty)
    #expect(markdownTexts(result).joined().contains("<Callout type=\"tip\">"))
    #expect(markdownTexts(result).joined().contains("No closing tag."))
}

@Test("MDX scanner leaves lowercase HTML tags as Markdown")
func mdxScannerLowercaseHTML() {
    let result = MDXBlockScanner().scan("<div>\nhello\n</div>")
    #expect(components(result).isEmpty)
}

// MARK: - Registry

@Test("MDX registry built-ins cover the vplan component names")
func mdxRegistryDefaults() {
    let registry = MDXComponentRegistry.builtIn
    #expect(registry.renderer(for: "Callout") == .callout)
    #expect(registry.renderer(for: "Phase") == .card)
    #expect(registry.renderer(for: "Checklist") == .checklist)
    #expect(registry.renderer(for: "Questions") == .questions)
    #expect(registry.renderer(for: "FileTree") == .fileTree)
    #expect(registry.renderer(for: "Svg") == .svg)
    #expect(registry.renderer(for: "Chart") == nil)
    #expect(registry.warnings.isEmpty)
}

@Test("MDX registry file adds aliases and overrides built-ins")
func mdxRegistryUserAlias() {
    let json =
        #"{"components": {"Note": {"renderer": "callout"}, "Phase": {"renderer": "checklist"}}}"#
    let registry = MDXComponentRegistry.decode(Data(json.utf8))
    #expect(registry.renderer(for: "Note") == .callout)
    #expect(registry.renderer(for: "Phase") == .checklist)
    #expect(registry.renderer(for: "Callout") == .callout)
    #expect(registry.warnings.isEmpty)
}

@Test("MDX registry rejects unknown renderers and invalid names")
func mdxRegistryRejectsUnknown() {
    let json = #"""
        {"components": {
          "Chart": {"renderer": "javascript"},
          "lower": {"renderer": "callout"},
          "Bare": {}
        }}
        """#
    let registry = MDXComponentRegistry.decode(Data(json.utf8))
    #expect(registry.renderer(for: "Chart") == nil)
    #expect(registry.renderer(for: "lower") == nil)
    #expect(registry.renderer(for: "Bare") == nil)
    #expect(registry.warnings.count == 3)
    #expect(registry.renderer(for: "Callout") == .callout)
}

@Test("MDX registry ignores a file above the size cap and malformed JSON")
func mdxRegistrySizeCapAndMalformed() {
    let oversized = Data(repeating: 0x20, count: MDXComponentRegistry.maxFileBytes + 1)
    let big = MDXComponentRegistry.decode(oversized)
    #expect(big.entries == MDXComponentRegistry.builtIn.entries)
    #expect(big.warnings.count == 1)

    let malformed = MDXComponentRegistry.decode(Data("not json".utf8))
    #expect(malformed.entries == MDXComponentRegistry.builtIn.entries)
    #expect(malformed.warnings.count == 1)
}

@Test("MDX registry is found in the nearest ancestor and stops at the repository root")
func mdxRegistryLoadsFromAncestor() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mdx-registry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    let docs = repo.appendingPathComponent("docs/plans", isDirectory: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let document = docs.appendingPathComponent("plan.mdx")

    // A file above the repository root is not used.
    let outside = root.appendingPathComponent(".rafu", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data(#"{"components": {"Outside": {"renderer": "card"}}}"#.utf8)
        .write(to: outside.appendingPathComponent(MDXComponentRegistry.fileName))
    #expect(MDXComponentRegistry.load(forDocumentAt: document).renderer(for: "Outside") == nil)

    let inside = repo.appendingPathComponent(".rafu", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try Data(#"{"components": {"Note": {"renderer": "callout"}}}"#.utf8)
        .write(to: inside.appendingPathComponent(MDXComponentRegistry.fileName))
    #expect(MDXComponentRegistry.load(forDocumentAt: document).renderer(for: "Note") == .callout)
}

// MARK: - Segments and blocks

private func blocks(_ segments: [MarkdownPreviewSegment]) -> [MDXBlock] {
    segments.compactMap {
        if case .component(let block) = $0.content { return block }
        return nil
    }
}

@Test("Plain Markdown never produces component segments")
func markdownParseIgnoresComponents() {
    let segments = MarkdownPreviewSegmentParser().parse("<Callout>\nhi\n</Callout>")
    #expect(blocks(segments).isEmpty)
    #expect(segments.count == 1)
}

@Test("MDX segments resolve built-in renderers, fallback, and Mermaid children")
func mdxSegmentsResolveRenderers() throws {
    let source = """
        ---
        title: Plan
        ---
        import X from "./x"

        <Callout type="risk">
        Careful.
        </Callout>

        <Phase title="One" status="in-progress">
        ```mermaid
        flowchart TD
            A --> B
        ```
        </Phase>

        <Chart kind="bar">
        Data here.
        </Chart>
        """
    let context = MDXParseContext(baseURL: URL(fileURLWithPath: "/tmp/docs"))
    let segments = MarkdownPreviewSegmentParser().parse(source, mdx: context)
    guard case .frontmatter = segments.first?.content else {
        Issue.record("Expected front matter first")
        return
    }
    let resolved = blocks(segments)
    #expect(resolved.count == 3)
    guard case .callout(let tone) = resolved[0].body else {
        Issue.record("Expected a callout")
        return
    }
    #expect(tone == .risk)
    guard case .card(let status) = resolved[1].body else {
        Issue.record("Expected a card")
        return
    }
    #expect(status == "in-progress")
    #expect(resolved[1].title == "One")
    guard case .mermaid = resolved[1].children.first?.content else {
        Issue.record("Expected a Mermaid child")
        return
    }
    guard case .fallback = resolved[2].body else {
        Issue.record("Expected the fallback block")
        return
    }
    #expect(resolved[2].propsLine == #"kind="bar""#)
    guard case .markdown(let text) = resolved[2].children.first?.content else {
        Issue.record("Expected fallback children as Markdown")
        return
    }
    #expect(text.contains("Data here."))
}

@Test("MDX checklist, questions, and file tree derive their rows")
func mdxDerivedRows() {
    let source = """
        <Checklist title="Evidence">
        - [x] One
        - [ ] Two
        - [X] Three
        </Checklist>

        <Questions>
        - First?
          - Yes
          - No
        - Second?
        </Questions>

        <FileTree>
        - add Sources/RafuApp/Canvas/ -- board
        - modify Sources/RafuApp/Editor/EditorLayout.swift -- typed tab
          - plain/file.swift
        </FileTree>
        """
    let resolved = blocks(MarkdownPreviewSegmentParser().parse(source, mdx: MDXParseContext()))
    #expect(resolved.count == 3)
    guard case .checklist(let done, let total) = resolved[0].body else {
        Issue.record("Expected a checklist")
        return
    }
    #expect(done == 2)
    #expect(total == 3)

    guard case .questions(let questions) = resolved[1].body else {
        Issue.record("Expected questions")
        return
    }
    #expect(questions.map(\.text) == ["First?", "Second?"])
    #expect(questions[0].options == ["Yes", "No"])
    #expect(questions[1].options.isEmpty)

    guard case .fileTree(let entries) = resolved[2].body else {
        Issue.record("Expected a file tree")
        return
    }
    #expect(entries.count == 3)
    #expect(entries[0].action == "add")
    #expect(entries[0].path == "Sources/RafuApp/Canvas/")
    #expect(entries[0].note == "board")
    #expect(entries[1].action == "modify")
    #expect(entries[2].action == nil)
    #expect(entries[2].depth == 1)
}

@Test("MDX Svg resolves local sources and never fetches remote ones")
func mdxSvgSources() {
    let base = URL(fileURLWithPath: "/tmp/docs/")
    #expect(
        MDXBlockBuilder.imageSource("./overview.svg", baseURL: base)
            == .local(URL(fileURLWithPath: "/tmp/docs/overview.svg")))
    #expect(
        MDXBlockBuilder.imageSource("https://example.com/a.svg", baseURL: base)
            == .remote("https://example.com/a.svg"))
    #expect(MDXBlockBuilder.imageSource(nil, baseURL: base) == .missing)
    #expect(MDXBlockBuilder.imageSource("", baseURL: base) == .missing)
}

@Test("MDX question and file tree blocks fall back to Markdown for non-list children")
func mdxNonListChildren() {
    #expect(MDXBlockBuilder.questions(in: "Just a paragraph.").isEmpty)
    #expect(MDXBlockBuilder.fileTree(in: "Not a list").isEmpty)
    #expect(MDXBlockBuilder.questions(in: nil).isEmpty)
}

// MARK: - Routing

@Test("mdx routes to the Markdown grammar with no language server")
func mdxLanguageRouting() {
    #expect(
        GrammarLanguageID.languageID(forExtension: "mdx", fileName: "plan.mdx") == .markdown)
    #expect(LanguageIdentifier.forURL(URL(fileURLWithPath: "/w/plan.mdx")) == nil)
}

@MainActor
@Test("mdx documents and Ensemble cards use the Markdown presentation")
func mdxDocumentIsMarkdown() {
    let document = EditorDocument(url: URL(fileURLWithPath: "/w/plan.mdx"))
    #expect(document.isMarkdown)
    #expect(document.supportsPresentationModes)
    #expect(CanvasMarkdownCard.isMarkdown(path: "/w/plan.MDX"))
    #expect(!CanvasMarkdownCard.defaultShowsSource(path: "/w/plan.mdx"))
}
