import Foundation
import JSONRenderCore
import Testing

@testable import RafuApp

// MARK: - Helpers

private let documentBase = URL(fileURLWithPath: "/tmp/docs/")

private func blocks(
    _ source: String, registry: MDXComponentRegistry = .builtIn
) -> [MDXBlock] {
    let context = MDXParseContext(registry: registry, baseURL: documentBase)
    return MarkdownPreviewSegmentParser().parse(source, mdx: context).compactMap {
        if case .component(let block) = $0.content { return block }
        return nil
    }
}

private func spec(_ source: String, registry: MDXComponentRegistry = .builtIn) throws -> Spec {
    let block = try #require(blocks(source, registry: registry).first)
    return MDXCatalogBridge.spec(for: block)
}

private func types(_ spec: Spec) -> [String: String] {
    spec.elements.mapValues(\.type)
}

private func root(_ spec: Spec) throws -> UIElement {
    try #require(spec.elements[spec.root])
}

private let hasStat = RafuCatalog.rafu.component(named: "Stat") != nil

// MARK: - One test per body case

@Test("MDX bridge: Callout keeps kind and title and puts Markdown in children")
func bridgeCallout() throws {
    let result = try spec(
        """
        <Callout type="warn" title="Careful">
        Do **not** skip this.
        </Callout>
        """)
    let element = try root(result)
    #expect(element.type == "Callout")
    #expect(element.props["kind"] == .string("warning"))
    #expect(element.props["title"] == .string("Careful"))
    let child = try #require(element.children?.first.flatMap { result.elements[$0] })
    #expect(child.type == "Markdown")
    #expect(child.props["text"]?.stringValue?.contains("Do **not** skip this.") == true)
}

@Test("MDX bridge: Phase becomes a standard Card with a status label")
func bridgeCard() throws {
    let result = try spec(
        """
        <Phase title="Build" status="in-progress">
        Intro.
        </Phase>
        """)
    let element = try root(result)
    #expect(element.type == "Card")
    #expect(element.props["title"] == .string("Build"))
    #expect(element.props["description"] == .string("In progress"))
    #expect(element.children?.count == 1)
}

@Test("MDX bridge: a Phase without a title shows its component name")
func bridgeCardDefaultTitle() throws {
    let element = try root(try spec("<Phase>\nBody.\n</Phase>"))
    #expect(element.props["title"] == .string("Phase"))
    #expect(element.props["description"] == nil)
}

@Test("MDX bridge: Checklist items come from the task list")
func bridgeChecklist() throws {
    let result = try spec(
        """
        <Checklist title="Evidence">
        - [x] One
        - [ ] Two
        - [X] **Three**
        </Checklist>
        """)
    let element = try root(result)
    #expect(element.type == "Checklist")
    #expect(element.props["title"] == .string("Evidence"))
    #expect(
        element.props["items"]
            == .array([
                .object(["text": "One", "done": true]),
                .object(["text": "Two", "done": false]),
                .object(["text": "**Three**", "done": true]),
            ]))
    #expect(element.children == nil)
}

@Test("MDX bridge: a Checklist with other text keeps the text as Markdown children")
func bridgeChecklistWithProse() throws {
    let result = try spec(
        """
        <Checklist>
        Read this first.

        - [x] One
        </Checklist>
        """)
    let element = try root(result)
    #expect(element.props["items"] == .array([]))
    let child = try #require(element.children?.first.flatMap { result.elements[$0] })
    #expect(child.type == "Markdown")
}

@Test("MDX bridge: Questions and FileTree carry their rows")
func bridgeQuestionsAndFileTree() throws {
    let questions = try spec(
        """
        <Questions title="Review">
        - First?
          - Yes
          - No
        - Second?
        </Questions>
        """)
    let questionElement = try root(questions)
    #expect(questionElement.type == "Questions")
    #expect(
        questionElement.props["items"]
            == .array([
                .object(["text": "First?", "options": ["Yes", "No"]]),
                .object(["text": "Second?", "options": []]),
            ]))

    let tree = try spec(
        """
        <FileTree>
        - add Sources/A.swift -- new file
          - plain/file.swift
        </FileTree>
        """)
    let treeElement = try root(tree)
    #expect(treeElement.type == "FileTree")
    #expect(
        treeElement.props["entries"]
            == .array([
                .object(
                    [
                        "depth": 0, "path": "Sources/A.swift", "action": "add",
                        "note": "new file",
                    ]),
                .object(["depth": 1, "path": "plain/file.swift"]),
            ]))
}

@Test("MDX bridge: Questions and FileTree with prose keep the prose as children")
func bridgeNonListChildren() throws {
    let result = try spec("<Questions>\nJust a paragraph.\n</Questions>")
    let element = try root(result)
    #expect(element.type == "Questions")
    #expect(element.props["items"] == .array([]))
    let child = try #require(element.children?.first.flatMap { result.elements[$0] })
    #expect(child.type == "Markdown")
}

@Test("MDX bridge: Svg becomes a Figure with an absolute file URL and never a fetch")
func bridgeFigure() throws {
    let local = try root(
        try spec(#"<Svg src="./overview.svg" title="Overview" caption="A caption" />"#))
    #expect(local.type == "Figure")
    #expect(local.props["src"] == .string("file:///tmp/docs/overview.svg"))
    #expect(local.props["title"] == .string("Overview"))
    #expect(local.props["caption"] == .string("A caption"))

    let remote = try root(try spec(#"<Svg src="https://example.com/a.svg" />"#))
    #expect(remote.props["src"] == .string("https://example.com/a.svg"))

    let missing = try root(try spec("<Svg />"))
    #expect(missing.props["src"] == nil)
}

@Test("MDX bridge: Stat carries its props; an unknown intent is dropped")
func bridgeStat() throws {
    let result = try spec(
        #"<Stat label="Coverage" value={87} delta="+2" unit="%" intent="good" />"#)
    let element = try root(result)
    if hasStat {
        #expect(element.type == "Stat")
        #expect(element.props["label"] == .string("Coverage"))
        #expect(element.props["value"] == .string("87"))
        #expect(element.props["delta"] == .string("+2"))
        #expect(element.props["unit"] == .string("%"))
        #expect(element.props["intent"] == .string("good"))
    } else {
        // Until the board catalog lands, a Stat draws as a Card of text.
        #expect(element.type == "Card")
        #expect(element.props["title"] == .string("Coverage"))
        #expect(element.props["description"] == .string("87 %  +2"))
    }

    let odd = try spec(#"<Stat label="X" value="1" intent="loud" />"#)
    #expect(try root(odd).props["intent"] == nil)
}

@Test("MDX bridge: Matrix and Compare turn the first pipe table into a Table")
func bridgeMatrix() throws {
    let source = """
        <Matrix title="Options">
        Before the table.

        | Option | Cost | Risk |
        |:--|--:|---|
        | A | 1 | low |
        | B | 2 | high |
        | **C** | 3 | `mid` |

        After the table.
        </Matrix>
        """
    let result = try spec(source)
    let card = try root(result)
    #expect(card.type == "Card")
    #expect(card.props["title"] == .string("Options"))
    let kids = try #require(card.children).compactMap { result.elements[$0] }
    #expect(kids.map(\.type) == ["Markdown", "Table", "Markdown"])
    let table = kids[1]
    #expect(table.props["columns"] == ["Option", "Cost", "Risk"])
    #expect(
        table.props["rows"]
            == [["A", "1", "low"], ["B", "2", "high"], ["C", "3", "mid"]])

    let compare = try root(
        try spec("<Compare>\n| A | B |\n|---|---|\n| 1 | 2 |\n</Compare>"))
    #expect(compare.props["title"] == .string("Compare"))
}

@Test("MDX bridge: a Matrix with no table shows its children in a Card")
func bridgeMatrixWithoutTable() throws {
    let result = try spec("<Matrix>\nNo table here.\n</Matrix>")
    #expect(try root(result).type == "Card")
    #expect(types(result).values.sorted() == ["Card", "Markdown"])
}

@Test("MDX bridge: a Matrix table is capped at 500 rows")
func bridgeMatrixRowCap() throws {
    let rows = (0..<600).map { "| \($0) | x |" }.joined(separator: "\n")
    let result = try spec("<Matrix>\n| N | V |\n|---|---|\n\(rows)\n</Matrix>")
    let tableID = try #require(result.elements.first { $0.value.type == "Table" }?.key)
    let tableRows = try #require(result.elements[tableID]?.props["rows"]?.arrayValue)
    #expect(tableRows.count == MDXBlockBuilder.maxListEntries)
}

// MARK: - Structure

@Test("MDX bridge: children keep their order and nested components get nested ids")
func bridgeNesting() throws {
    let source = """
        <Phase title="One" status="planned">
        Intro.

        <Callout type="decision">
        Keep it native.
        </Callout>

        ```mermaid
        flowchart TD
            A --> B
        ```

        <Svg src="./overview.svg" />
        </Phase>
        """
    let block = try #require(blocks(source).first)
    let result = MDXCatalogBridge.spec(for: block)
    #expect(result.root == "b\(block.id)")
    let card = try root(result)
    let childTypes = try #require(card.children).compactMap { result.elements[$0]?.type }
    #expect(childTypes == ["Markdown", "Callout", "Mermaid", "Figure"])
    // Every id starts with b and is unique to this block.
    #expect(result.elements.keys.allSatisfy { $0.hasPrefix("b") })
    let callout = try #require(
        card.children?.compactMap { result.elements[$0] }.first { $0.type == "Callout" })
    #expect(callout.children?.count == 1)
    let mermaid = try #require(result.elements.values.first { $0.type == "Mermaid" })
    #expect(mermaid.props["source"]?.stringValue?.contains("A --> B") == true)
}

@Test("MDX bridge: an unknown component nested in a known one keeps its name and props")
func bridgeNestedFallback() throws {
    let result = try spec(
        """
        <Phase title="One">
        <Chart kind="bar">
        Data here.
        </Chart>
        </Phase>
        """)
    let card = try root(result)
    let nested = try #require(card.children?.first.flatMap { result.elements[$0] })
    #expect(nested.type == "Card")
    #expect(nested.props["title"] == .string("<Chart>"))
    #expect(nested.props["description"] == .string(#"kind="bar""#))
    #expect(nested.children?.count == 1)
}

@Test("MDX bridge: the build attaches a spec to top-level blocks only")
func catalogSpecPlacement() throws {
    let found = blocks(
        """
        <Phase title="One">
        <Callout type="tip">
        Hi.
        </Callout>
        </Phase>

        <Unknown prop="1">
        <Callout type="note">
        Inside a fallback.
        </Callout>
        </Unknown>
        """)
    #expect(found.count == 2)
    #expect(found[0].catalogSpec != nil)
    guard
        case .component(let nested) = found[0].children.first(where: {
            if case .component = $0.content { return true }
            return false
        })?.content
    else {
        Issue.record("Expected a nested component")
        return
    }
    #expect(nested.catalogSpec == nil)

    // A fallback block is not bridged, but a known block inside it is.
    #expect(found[1].catalogSpec == nil)
    guard case .component(let inner) = found[1].children.first?.content else {
        Issue.record("Expected a component inside the fallback")
        return
    }
    #expect(inner.catalogSpec != nil)
}

// MARK: - Validation

@Test("MDX bridge: every built-in renderer kind bridges to a valid spec")
func everyBuiltInKindValidates() throws {
    let source = """
        <Callout type="risk" title="T">
        Text.
        </Callout>

        <Phase title="P" status="done">
        <Checklist>
        - [x] A
        </Checklist>
        </Phase>

        <Checklist title="C">
        - [x] A
        - [ ] B
        </Checklist>

        <Questions>
        - Q?
          - Yes
        </Questions>

        <Questions>
        Prose only.
        </Questions>

        <FileTree>
        - add a.swift
        </FileTree>

        <FileTree>
        Prose only.
        </FileTree>

        <Svg src="./a.svg" caption="c" />

        <Svg src="https://example.com/a.svg" />

        <Stat label="L" value="1" />

        <Stat label="L" value="1">
        With a child.
        </Stat>

        <Matrix>
        | A | B |
        |---|---|
        | 1 | 2 |
        </Matrix>

        <Compare>
        No table.
        </Compare>

        <Unknown a="1">
        <Callout>
        Nested.
        </Callout>
        </Unknown>
        """
    let found = blocks(source)
    #expect(found.count == 14)
    for block in found {
        if case .fallback = block.body { continue }
        let result = MDXCatalogBridge.spec(for: block)
        let report = RafuCatalog.rafu.validate(result)
        #expect(report.errors.isEmpty, "block \(block.id) (\(block.name)) has errors")
        #expect(block.catalogSpec != nil, "block \(block.id) (\(block.name)) has no spec")
    }
}

@Test("MDX bridge: the document components are in the Rafu catalog")
func documentComponentsRegistered() {
    for name in MDXCatalogBridge.documentComponents {
        #expect(RafuCatalog.rafu.component(named: name) != nil, "missing \(name)")
    }
}

// MARK: - Registry file

@Test("MDX registry file accepts the matrix renderer and still rejects unknown kinds")
func registryAcceptsMatrix() {
    let data = Data(
        #"""
        { "components": {
            "Options": { "renderer": "matrix" },
            "Number": { "renderer": "stat" },
            "Graph": { "renderer": "chart" }
        } }
        """#.utf8)
    let registry = MDXComponentRegistry.decode(data)
    #expect(registry.renderer(for: "Options") == .matrix)
    #expect(registry.renderer(for: "Number") == .stat)
    #expect(registry.renderer(for: "Graph") == nil)
    #expect(registry.warnings == [#""Graph" uses unknown renderer "chart"."#])
    #expect(MDXComponentRegistry.builtIn.renderer(for: "Compare") == .matrix)
    #expect(MDXComponentRegistry.builtIn.renderer(for: "Matrix") == .matrix)
    #expect(MDXComponentRegistry.builtIn.renderer(for: "Stat") == .stat)
}

@Test("MDX registry file entries bridge through the chosen renderer")
func registryEntryBridges() throws {
    let registry = MDXComponentRegistry.decode(
        Data(#"{ "components": { "Note": { "renderer": "callout" } } }"#.utf8))
    let result = try spec("<Note type=\"tip\">\nHello.\n</Note>", registry: registry)
    #expect(try root(result).type == "Callout")
    #expect(try root(result).props["kind"] == .string("tip"))
}

// MARK: - Parsers

@Test("MDX table parser reads header, rows, escapes, and pads short rows")
func tableParser() throws {
    let markdown = """
        Intro

        | A | B \\| C |
        | --- | :-: |
        | 1 |
        | 2 | 3 | extra |
        trailing
        """
    let extraction = try #require(MDXTableParser.extractFirstTable(in: markdown))
    #expect(extraction.table.columns == ["A", "B | C"])
    #expect(extraction.table.rows == [["1", ""], ["2", "3"]])
    #expect(extraction.before.contains("Intro"))
    #expect(extraction.after.contains("trailing"))
}

@Test("MDX table parser ignores fenced pipes and needs a delimiter row")
func tableParserNegative() {
    #expect(MDXTableParser.firstTable(in: "```\n| A | B |\n|---|---|\n| 1 | 2 |\n```") == nil)
    #expect(MDXTableParser.firstTable(in: "| A | B |\n| 1 | 2 |") == nil)
    #expect(MDXTableParser.firstTable(in: "| A | B |\n|---|\n| 1 | 2 |") == nil)
}

@Test("MDX checklist items need a pure task list")
func checklistItems() {
    #expect(
        MDXBlockBuilder.checklistItems(in: "- [x] A\n* [ ] B\n")
            == [
                .init(text: "A", done: true), .init(text: "B", done: false),
            ])
    #expect(MDXBlockBuilder.checklistItems(in: "- [x] A\nplain") == nil)
    #expect(MDXBlockBuilder.checklistItems(in: "- plain item") == nil)
    #expect(MDXBlockBuilder.checklistItems(in: "") == nil)
    #expect(MDXBlockBuilder.checklistCounts("- [x] A\n- [ ] B") == (1, 2))
}

// MARK: - Component helpers

@Test("Figure reads a local image only inside an allowed root and never fetches")
func figureSources() {
    let roots = [URL(fileURLWithPath: "/tmp/docs")]
    #expect(
        RafuDocFigure.source("file:///tmp/docs/a.svg", roots: roots)
            == .local(URL(fileURLWithPath: "/tmp/docs/a.svg")))
    #expect(
        RafuDocFigure.source("/tmp/docs/sub/a.png", roots: roots)
            == .local(URL(fileURLWithPath: "/tmp/docs/sub/a.png")))
    #expect(RafuDocFigure.source("/etc/passwd", roots: roots) == .blocked)
    #expect(RafuDocFigure.source("file:///tmp/docs/../secret.png", roots: roots) == .blocked)
    #expect(RafuDocFigure.source("file:///tmp/docs/a.svg", roots: []) == .blocked)
    #expect(
        RafuDocFigure.source("file:///any/where.png", roots: [URL(filePath: "/")])
            == .local(URL(fileURLWithPath: "/any/where.png")))
    #expect(
        RafuDocFigure.source("https://example.com/a.png", roots: roots)
            == .remote("https://example.com/a.png"))
    #expect(RafuDocFigure.source(nil, roots: roots) == .missing)
    #expect(RafuDocFigure.source("  ", roots: roots) == .missing)
}

@Test("Code block fences are longer than any backtick run in the text")
func codeFence() {
    #expect(RafuDocCode.fenced("a", language: "swift") == "```swift\na\n```")
    #expect(RafuDocCode.fenced("x ``` y", language: nil) == "````\nx ``` y\n````")
    #expect(RafuDocCode.fenced("a", language: "sw`ift x") == "```swiftx\na\n```")
}

@Test("Code text over 64 KiB is cut and flagged")
func codeTruncation() {
    let short = RafuDocCode.truncated("hello")
    #expect(short.text == "hello" && !short.isCut)
    let long = RafuDocCode.truncated(String(repeating: "é", count: RafuDocCode.maxBytes))
    #expect(long.isCut)
    #expect(long.text.utf8.count <= RafuDocCode.maxBytes)
    #expect(long.text.utf8.count >= RafuDocCode.maxBytes - 1)
}
