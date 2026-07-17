import Testing

@testable import RafuApp

@Test(
    "Mermaid diagram types outside the native flow/sequence subset render as unsupported",
    arguments: [
        "classDiagram", "stateDiagram", "stateDiagram-v2", "erDiagram", "gantt", "pie", "journey",
        "gitGraph", "mindmap", "timeline", "quadrantChart", "requirement", "requirementDiagram",
        "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment", "sankey",
        "sankey-beta", "xychart", "xychart-beta", "block", "block-beta", "packet", "packet-beta",
        "kanban", "architecture", "architecture-beta",
    ])
func unsupportedMermaidTypesAreClassified(header: String) {
    let result = MarkdownParser().parseMermaid("\(header)\n  some body")

    guard case .unsupported(let type, _) = result else {
        Issue.record("Expected .unsupported for header '\(header)'")
        return
    }
    #expect(type == header)
}

@Test(
    "Empty or unrecognized Mermaid sources are reported as malformed",
    arguments: ["", "   \n  ", "wat", "notADiagram foo"])
func malformedMermaidSourcesAreClassified(raw: String) {
    let result = MarkdownParser().parseMermaid(raw)

    guard case .malformed = result else {
        Issue.record("Expected .malformed for raw '\(raw)'")
        return
    }
}

@Test(
    "Legacy flow headers classify as native flow diagrams",
    arguments: ["graph LR\n  A --> B", "flowchart TD\n  A --> B", "flowchart"])
func legacyFlowHeadersClassifyAsFlow(raw: String) {
    let result = MarkdownParser().parseMermaid(raw)

    guard case .flow = result else {
        Issue.record("Expected .flow for raw '\(raw)'")
        return
    }
}

@Test("Flow diagrams without edges still classify as flow with no edges")
func flowWithoutEdgesHasEmptyEdges() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A\n  B")

    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.isEmpty)
}

@Test("Sequence diagrams classify as native sequence with messages")
func sequenceDiagramClassifiesAsSequence() {
    let result = MarkdownParser().parseMermaid("sequenceDiagram\n  A->>B: hi")

    guard case .sequence(let seq) = result else {
        Issue.record("Expected .sequence")
        return
    }
    #expect(!seq.messages.isEmpty)
}
