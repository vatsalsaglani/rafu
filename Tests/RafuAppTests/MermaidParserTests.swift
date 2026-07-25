import Foundation
import Testing

@testable import RafuApp

private func diagram(_ source: String) -> MermaidDiagram {
    guard case .diagram(let result) = MarkdownParser().parseMermaid(source) else {
        preconditionFailure("Expected a diagram for fixture: \(source)")
    }
    return result
}

@Test(
    "Mermaid diagram types outside the native six-type subset render as unsupported",
    arguments: [
        "gantt", "pie", "journey", "gitGraph", "mindmap", "timeline", "quadrantChart",
        "requirement", "requirementDiagram", "C4Context", "C4Container", "C4Component",
        "C4Dynamic", "C4Deployment", "sankey", "sankey-beta", "block", "block-beta", "packet",
        "packet-beta", "kanban", "architecture", "architecture-beta",
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
    "All six BeautifulMermaid-backed diagram types classify to .diagram with the right kind",
    arguments: [
        ("flowchart TD\n  A --> B", MermaidDiagramKind.flowchart),
        ("graph LR\n  A --> B", MermaidDiagramKind.flowchart),
        ("stateDiagram-v2\n  [*] --> A", MermaidDiagramKind.stateDiagram),
        ("sequenceDiagram\n  A->>B: hi", MermaidDiagramKind.sequenceDiagram),
        ("classDiagram\n  class A", MermaidDiagramKind.classDiagram),
        ("erDiagram\n  A ||--o{ B : has", MermaidDiagramKind.erDiagram),
        ("xychart-beta\n  title \"t\"", MermaidDiagramKind.xyChart),
    ] as [(String, MermaidDiagramKind)])
func supportedMermaidTypesClassifyWithKind(_ pair: (String, MermaidDiagramKind)) {
    let result = MarkdownParser().parseMermaid(pair.0)

    guard case .diagram(let diagram) = result else {
        Issue.record("Expected .diagram for raw '\(pair.0)'")
        return
    }
    #expect(diagram.kind == pair.1)
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

    guard case .diagram(let diagram) = result else {
        Issue.record("Expected .diagram for raw '\(raw)'")
        return
    }
    #expect(diagram.kind == .flowchart)
}

// MARK: - Normalisation (ADR 0020 "Compensating work Rafu must carry")

@Test(
    "A bare flowchart/graph header, with or without a trailing semicolon, gets a default TD appended",
    arguments: ["flowchart", "graph", "flowchart;", "graph;"])
func bareFlowHeaderGetsDefaultDirection(header: String) {
    let expectedToken = header.hasSuffix(";") ? String(header.dropLast()) : header
    let result = diagram("\(header)\n  A --> B")
    #expect(result.source.hasPrefix("\(expectedToken) TD"))
    #expect(result.raw == "\(header)\n  A --> B")
}

@Test("YAML frontmatter is stripped from the normalised source but kept in raw")
func frontmatterIsStrippedFromSourceButKeptInRaw() {
    let raw = "---\ntitle: X\n---\nflowchart\n  A --> B"
    let result = diagram(raw)
    #expect(!result.source.contains("title: X"))
    #expect(result.source.hasPrefix("flowchart TD"))
    #expect(result.raw == raw)
}

@Test("A %% comment line before a bare header still normalises correctly")
func commentBeforeBareHeaderStillNormalises() {
    let raw = "%% hi\nflowchart\n  A --> B"
    let result = diagram(raw)
    #expect(!result.source.contains("%%"))
    #expect(result.source.hasPrefix("flowchart TD"))
}

@Test("Normalisation is the identity transform when a direction is already present")
func normalisationIsIdentityWhenDirectionPresent() {
    let raw = "flowchart LR\n  A --> B"
    let result = diagram(raw)
    #expect(result.source == raw)
}
