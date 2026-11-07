import Foundation
import JSONRenderCore
import Testing

@testable import RafuApp

/// The "no visible change" guard at the data level (ADR 0034 amendment).
///
/// The two real wireframe documents are scanned, resolved, and bridged. Each
/// top-level component block is summarised in one line: its name, its
/// `MDXBlock.Body` case, its child count, and the catalog element tree it
/// draws as. A line that changes means the preview draws something new: look
/// at the rendered preview (Preview and Split, light and dark) before you
/// update the expected lines.
///
/// The documents are read from `docs/plans/wireframes/workspace-canvas/`
/// rather than copied into the test target, so they cannot drift from the
/// files people open.
private enum Wireframe {
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/plans/wireframes/workspace-canvas", directoryHint: .isDirectory)

    static func blocks(named name: String) throws -> [MDXBlock] {
        let url = directory.appending(path: name)
        let source = try String(contentsOf: url, encoding: .utf8)
        let context = MDXParseContext(registry: .builtIn, baseURL: directory)
        return MarkdownPreviewSegmentParser().parse(source, mdx: context).compactMap {
            if case .component(let block) = $0.content { return block }
            return nil
        }
    }

    static func bodyName(_ body: MDXBlock.Body) -> String {
        switch body {
        case .callout(let tone): "callout(\(tone.rawValue))"
        case .card(let status): "card(\(status ?? "-"))"
        case .checklist(let done, let total): "checklist(\(done)/\(total))"
        case .questions(let list): "questions(\(list.count))"
        case .fileTree(let entries): "fileTree(\(entries.count))"
        case .svg: "svg"
        case .stat: "stat"
        case .matrix: "matrix"
        case .fallback: "fallback"
        }
    }

    /// `Card(Markdown,Figure,Table)`: the element types in tree order.
    static func tree(_ spec: Spec, id: String) -> String {
        guard let element = spec.elements[id] else { return "?" }
        let kids = (element.children ?? []).map { tree(spec, id: $0) }
        // A checklist shows its item count: 0 means its text stayed Markdown.
        let name =
            element.type == "Checklist"
            ? "Checklist[\(element.props["items"]?.arrayValue?.count ?? 0)]" : element.type
        return kids.isEmpty ? name : "\(name)(\(kids.joined(separator: ",")))"
    }

    static func outline(of blocks: [MDXBlock]) -> [String] {
        blocks.map { block in
            let shape = block.catalogSpec.map { tree($0, id: $0.root) } ?? "unbridged"
            return
                "\(block.name) \(bodyName(block.body)) children=\(block.children.count) \(shape)"
        }
    }
}

@Test("canvas-plan.mdx keeps its block outline through the catalog bridge")
func canvasPlanOutline() throws {
    let actual = Wireframe.outline(of: try Wireframe.blocks(named: "canvas-plan.mdx"))
    #expect(actual == canvasPlanExpected, Comment(rawValue: actual.joined(separator: "\n")))
}

@Test("execution-plan.mdx keeps its block outline through the catalog bridge")
func executionPlanOutline() throws {
    let actual = Wireframe.outline(of: try Wireframe.blocks(named: "execution-plan.mdx"))
    #expect(actual == executionPlanExpected, Comment(rawValue: actual.joined(separator: "\n")))
}

@Test("Every wireframe block is bridged and its spec validates against the Rafu catalog")
func wireframeSpecsValidate() throws {
    for name in ["canvas-plan.mdx", "execution-plan.mdx"] {
        for block in try Wireframe.blocks(named: name) {
            let spec = try #require(block.catalogSpec, "\(name) block \(block.id) has no spec")
            #expect(RafuCatalog.rafu.validate(spec).errors.isEmpty)
        }
    }
}

private let canvasPlanExpected: [String] = [
    "Callout callout(tip) children=1 Callout(Markdown)",
    "Phase card(planned) children=3 Card(Markdown,Figure,Markdown)",
    "Phase card(planned) children=4 Card(Markdown,Figure,Mermaid,Callout(Markdown))",
    "Phase card(planned) children=4 Card(Markdown,Figure,Markdown,Callout(Markdown))",
    "Phase card(planned) children=2 Card(Markdown,Callout(Markdown))",
    "Phase card(planned) children=2 Card(Markdown,Checklist[4])",
    "Phase card(planned) children=2 Card(Markdown,FileTree)",
    "Phase card(planned) children=2 Card(Markdown,Checklist[6])",
    "Questions questions(3) children=1 Questions",
]

private let executionPlanExpected: [String] = [
    "Callout callout(decision) children=1 Callout(Markdown)",
    "Callout callout(decision) children=1 Callout(Markdown)",
    "Phase card(planned) children=3 Card(Markdown,Checklist[7],Callout(Markdown))",
    "FileTree fileTree(14) children=1 FileTree",
    "Phase card(planned) children=3 Card(Markdown,Checklist[3],Markdown)",
    "Phase card(planned) children=3 Card(Markdown,Checklist[3],Markdown)",
    "Phase card(planned) children=2 Card(Markdown,Checklist[7])",
    "Questions questions(3) children=1 Questions",
    "Callout callout(note) children=1 Callout(Markdown)",
]
