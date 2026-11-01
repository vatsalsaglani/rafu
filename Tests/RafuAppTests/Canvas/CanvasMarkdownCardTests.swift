import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Canvas Markdown file card")
struct CanvasMarkdownCardTests {
    @Test(
        "Only .md and .markdown files are Markdown, in any case",
        arguments: [
            ("a/b.md", true), ("a/b.MARKDOWN", true), ("README.Md", true),
            ("a/b.mdx", false), ("a/b.txt", false), ("README", false), ("md", false),
            ("notes.md.bak", false),
        ])
    func recognisesMarkdown(path: String, expected: Bool) {
        #expect(CanvasMarkdownCard.isMarkdown(path: path) == expected)
        #expect(CanvasMarkdownCard.defaultShowsSource(path: path) == !expected)
    }

    @Test("A short text is kept whole; a long one is cut at its last line end")
    func truncatesAtLastLine() {
        let whole = CanvasMarkdownCard.truncatedAtLastLine("one\ntwo", limitBytes: 100)
        #expect(whole.text == "one\ntwo" && !whole.isTruncated)
        let cut = CanvasMarkdownCard.truncatedAtLastLine("one\ntwo\nthree", limitBytes: 10)
        #expect(cut.text == "one\ntwo" && cut.isTruncated)
        let noNewline = CanvasMarkdownCard.truncatedAtLastLine(
            String(repeating: "x", count: 20), limitBytes: 8)
        #expect(noNewline.text == "xxxxxxxx" && noNewline.isTruncated)
        // A cut inside a multi-byte character never leaves half a character.
        let wide = CanvasMarkdownCard.truncatedAtLastLine(
            "ab\n" + String(repeating: "é", count: 10), limitBytes: 6)
        #expect(wide.text == "ab" && wide.isTruncated)
    }

    @Test("Front matter, paragraphs and a Mermaid fence keep source order with unique ids")
    func itemsKeepOrder() {
        let source = """
            ---
            title: Plan
            ---

            # Heading

            First paragraph.

            ```mermaid
            flowchart TD
              A --> B
            ```

            Last paragraph.
            """
        let items = CanvasMarkdownCard.items(from: source)
        var order: [String] = []
        for item in items {
            switch item.kind {
            case .frontmatter: order.append("front")
            case .block(let block):
                if case .heading = block.kind {
                    order.append("heading")
                } else {
                    order.append("block")
                }
            case .mermaid(let result):
                if case .diagram = result {
                    order.append("diagram")
                } else {
                    order.append("other")
                }
            }
        }
        #expect(order == ["front", "heading", "block", "diagram", "block"])
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.map(\.id) == Array(items.indices))
        // 12 above a heading is only after the first row; 6 below it; 8 otherwise.
        #expect(items[0].gap == 0)
        #expect(items[1].gap == 12)
        #expect(items[2].gap == 6)
        #expect(items[3].gap == 8)
    }

    @Test("Diagrams past the cap show as code, not as more native renders")
    func diagramCap() {
        let fence = "```mermaid\nflowchart TD\n  A --> B\n```\n\n"
        let items = CanvasMarkdownCard.items(
            from: String(repeating: fence, count: CanvasMarkdownCard.maxDiagrams + 3))
        let diagrams = items.filter {
            if case .mermaid = $0.kind { true } else { false }
        }
        #expect(diagrams.count == CanvasMarkdownCard.maxDiagrams)
        #expect(items.count == CanvasMarkdownCard.maxDiagrams + 3)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("An empty file has no rows")
    func emptyFile() {
        #expect(CanvasMarkdownCard.items(from: "").isEmpty)
    }
}

@Suite("Canvas Markdown card view state")
@MainActor
struct CanvasMarkdownCardStateTests {
    @Test("Preview is the default, the toggle flips it, and the choice is never saved")
    func toggleIsViewStateOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-markdown-card-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: folder.appending(path: "state"))))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Markdown", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Docs"))
        session.installCanvasResources(for: board)
        try board.add(title: "README", content: .file(path: "README.md"))
        try board.add(title: "main", content: .file(path: "main.swift"))
        let markdown = try #require(board.cards.first { $0.title == "README" }?.id)
        let swift = try #require(board.cards.first { $0.title == "main" }?.id)
        let resources = try #require(session.canvasResources[board.id])

        #expect(!resources.showsSource(for: markdown, path: "README.md"))
        #expect(resources.showsSource(for: swift, path: "main.swift"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(board.snapshot().cards)

        resources.toggleSource(for: markdown, path: "README.md")
        #expect(resources.showsSource(for: markdown, path: "README.md"))
        resources.toggleSource(for: markdown, path: "README.md")
        #expect(!resources.showsSource(for: markdown, path: "README.md"))
        resources.toggleSource(for: markdown, path: "README.md")
        let after = try encoder.encode(board.snapshot().cards)
        #expect(before == after)

        resources.stop(cards: [markdown])
        #expect(!resources.showsSource(for: markdown, path: "README.md"))
        resources.toggleSource(for: markdown, path: "README.md")
        board.selection = [markdown]
        try board.removeSelection()
        resources.prune()
        #expect(resources.markdownCardShowsSource[markdown] == nil)
    }
}
