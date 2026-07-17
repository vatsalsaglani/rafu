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

@Test("Flow nodes capture shape delimiters, double-before-single")
func flowNodeShapesAreDetected() {
    let result = MarkdownParser().parseMermaid(
        """
        flowchart TD
          A[rect]
          B(round)
          C{diamond}
          D((circle))
          E[[sub]]
          F[/para/]
          G>flag]
        """)

    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.nodesByID["A"]?.shape == .rectangle)
    #expect(flow.nodesByID["A"]?.label == "rect")
    #expect(flow.nodesByID["B"]?.shape == .round)
    #expect(flow.nodesByID["B"]?.label == "round")
    #expect(flow.nodesByID["C"]?.shape == .diamond)
    #expect(flow.nodesByID["C"]?.label == "diamond")
    #expect(flow.nodesByID["D"]?.shape == .circle)
    #expect(flow.nodesByID["D"]?.label == "circle")
    #expect(flow.nodesByID["E"]?.shape == .subroutine)
    #expect(flow.nodesByID["E"]?.label == "sub")
    #expect(flow.nodesByID["F"]?.shape == .parallelogram)
    #expect(flow.nodesByID["F"]?.label == "para")
    #expect(flow.nodesByID["G"]?.shape == .flag)
    #expect(flow.nodesByID["G"]?.label == "flag")
}

@Test("Flow edges capture line style and start/end arrowheads")
func flowEdgeStylesAndHeadsAreDetected() {
    let result = MarkdownParser().parseMermaid(
        """
        flowchart TD
          A-->B
          C---D
          E-.->F
          G==>H
          I--oJ
          K--xL
          M<-->N
        """)

    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 7)
    let byPair = Dictionary(uniqueKeysWithValues: flow.edges.map { ("\($0.from)-\($0.to)", $0) })

    // Edges are unwrapped before comparison so bare `.none` resolves to
    // `MermaidFlow.EdgeHead.none` rather than `Optional.none`.
    guard let ab = byPair["A-B"], let cd = byPair["C-D"], let ef = byPair["E-F"],
        let gh = byPair["G-H"], let ij = byPair["I-J"], let kl = byPair["K-L"],
        let mn = byPair["M-N"]
    else {
        Issue.record("Expected all seven connector pairs")
        return
    }

    #expect(ab.line == .solid)
    #expect(ab.startHead == .none)
    #expect(ab.endHead == .arrow)

    #expect(cd.line == .solid)
    #expect(cd.startHead == .none)
    #expect(cd.endHead == .none)

    #expect(ef.line == .dotted)
    #expect(ef.endHead == .arrow)

    #expect(gh.line == .thick)
    #expect(gh.endHead == .arrow)

    #expect(ij.line == .solid)
    #expect(ij.endHead == .circle)

    #expect(kl.line == .solid)
    #expect(kl.endHead == .cross)

    #expect(mn.line == .solid)
    #expect(mn.startHead == .arrow)
    #expect(mn.endHead == .arrow)
}

@Test("Flow edge labels are captured from pipe and inline solid syntax")
func flowEdgeLabelsAreCaptured() {
    let pipeResult = MarkdownParser().parseMermaid("flowchart TD\n  A-->|opens|B")
    guard case .flow(let pipeFlow) = pipeResult else {
        Issue.record("Expected .flow")
        return
    }
    #expect(pipeFlow.edges.first?.label == "opens")

    let inlineResult = MarkdownParser().parseMermaid("flowchart TD\n  A -- opens --> B")
    guard case .flow(let inlineFlow) = inlineResult else {
        Issue.record("Expected .flow")
        return
    }
    #expect(inlineFlow.edges.first?.label == "opens")
}

@Test("Chained edges expand into distinct edges with unique identity")
func flowChainedEdgesExpand() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A-->B-->C")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 2)
    let pairs = Set(flow.edges.map { "\($0.from)-\($0.to)" })
    #expect(pairs == ["A-B", "B-C"])
    #expect(Set(flow.edges.map(\.id)).count == 2)
}

@Test("Ampersand-joined node groups expand into a cross product of edges")
func flowAmpersandGroupsExpand() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A & B --> C & D")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 4)
    let pairs = Set(flow.edges.map { "\($0.from)-\($0.to)" })
    #expect(pairs == ["A-C", "A-D", "B-C", "B-D"])
    #expect(Set(flow.edges.map(\.id)).count == 4)
}

@Test("Chained edges combine with ampersand expansion")
func flowChainedAmpersandEdgesExpand() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A & B --> C --> D")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 3)
    let pairs = Set(flow.edges.map { "\($0.from)-\($0.to)" })
    #expect(pairs == ["A-C", "B-C", "C-D"])
}

@Test("Subgraphs nest and track member node ids with durable identity")
func flowSubgraphsNestWithMembership() {
    let result = MarkdownParser().parseMermaid(
        """
        flowchart TD
          subgraph outer[Outer]
            A-->B
            subgraph inner[Inner]
              C-->D
            end
            A-->C
          end
        """)

    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.subgraphs.count == 1)
    guard let outer = flow.subgraphs.first else {
        Issue.record("Expected outer subgraph")
        return
    }
    #expect(outer.name == "outer")
    #expect(outer.title == "Outer")
    #expect(Set(outer.nodeIDs).isSuperset(of: ["A", "B"]))
    #expect(outer.children.count == 1)
    guard let inner = outer.children.first else {
        Issue.record("Expected inner subgraph")
        return
    }
    #expect(inner.name == "inner")
    #expect(inner.title == "Inner")
    #expect(Set(inner.nodeIDs).isSuperset(of: ["C", "D"]))
    #expect(inner.id != outer.id)
}

@Test(
    "Flow header direction tokens map to the correct layout direction",
    arguments: [
        ("graph LR", MermaidFlow.Direction.leftToRight),
        ("flowchart TD", MermaidFlow.Direction.topToBottom),
        ("graph BT", MermaidFlow.Direction.bottomToTop),
        ("flowchart RL", MermaidFlow.Direction.rightToLeft),
        ("graph TB", MermaidFlow.Direction.topToBottom),
        ("flowchart", MermaidFlow.Direction.topToBottom),
    ] as [(String, MermaidFlow.Direction)])
func flowDirectionIsParsed(_ pair: (String, MermaidFlow.Direction)) {
    let result = MarkdownParser().parseMermaid("\(pair.0)\n  A-->B")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.direction == pair.1)
}

@Test("Repeated identical edge lines still produce distinct edge identities")
func flowRepeatedEdgesHaveDistinctIdentity() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A-->B\n  A-->B")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 2)
    #expect(flow.edges[0].id != flow.edges[1].id)
}

@Test("A subgraph missing its closing end still parses without crashing")
func flowUnterminatedSubgraphIsFlushed() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  subgraph s\n    A-->B")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 1)
    #expect(flow.edges.first?.from == "A")
    #expect(flow.edges.first?.to == "B")
    #expect(flow.subgraphs.count == 1)
    #expect(flow.subgraphs.first?.name == "s")
}

@Test("Self-loop edges are captured with matching from/to identifiers")
func flowSelfLoopEdgeIsCaptured() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A-->A")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 1)
    #expect(flow.edges.first?.from == "A")
    #expect(flow.edges.first?.to == "A")
}

@Test("Connector-like text inside node brackets is not mistaken for an edge")
func flowBracketContentsAreNotMistakenForConnectors() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A[x --> y] --> B")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(flow.edges.count == 1)
    #expect(flow.edges.first?.from == "A")
    #expect(flow.edges.first?.to == "B")
    #expect(flow.nodesByID["A"]?.label == "x --> y")
}

@Test("Ampersand inside a node bracket does not split the node group")
func flowBracketAmpersandIsNotSplit() {
    let result = MarkdownParser().parseMermaid("flowchart TD\n  A[a & b] & C --> D")
    guard case .flow(let flow) = result else {
        Issue.record("Expected .flow")
        return
    }
    #expect(Set(flow.nodesByID.keys) == ["A", "C", "D"])
    let pairs = Set(flow.edges.map { "\($0.from)-\($0.to)" })
    #expect(pairs == ["A-D", "C-D"])
}
