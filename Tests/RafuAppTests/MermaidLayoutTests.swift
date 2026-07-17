import CoreGraphics
import Testing

@testable import RafuApp

private func flow(_ source: String) -> MermaidFlow {
    guard case .flow(let result) = MarkdownParser().parseMermaid(source) else {
        preconditionFailure("Expected a flow diagram for fixture: \(source)")
    }
    return result
}

private func sequence(_ source: String) -> MermaidSequence {
    guard case .sequence(let result) = MarkdownParser().parseMermaid(source) else {
        preconditionFailure("Expected a sequence diagram for fixture: \(source)")
    }
    return result
}

private func doesNotOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
    let intersection = a.intersection(b)
    return intersection.isNull || intersection.width == 0 || intersection.height == 0
}

// MARK: - 1. Rank assignment: linear chain

@Test("Ranks increase strictly along a linear chain")
func ranksIncreaseAlongLinearChain() {
    let layout = MermaidLayoutEngine().layout(flow("flowchart TD\nA-->B-->C-->D"))
    let rankByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.rank) })

    #expect(rankByID["A"] == 0)
    #expect(rankByID["B"] == 1)
    #expect(rankByID["C"] == 2)
    #expect(rankByID["D"] == 3)
}

// MARK: - 2. Rank assignment: longest path wins

@Test("Longest path wins rank assignment for a diamond with a shortcut")
func rankUsesLongestPath() {
    let layout = MermaidLayoutEngine().layout(
        flow("flowchart TD\nA-->B\nA-->C\nB-->D\nC-->D\nA-->D"))
    let rankByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.rank) })

    #expect(rankByID["D"] == 2)
}

// MARK: - 3. In-rank ordering determinism

@Test("Layout is deterministic across repeated runs and orders are contiguous within a rank")
func layoutIsDeterministicAndOrdersAreContiguous() {
    let source = "flowchart TD\nA-->B\nA-->C\nA-->D\nB-->E\nC-->E\nD-->E"
    let engine = MermaidLayoutEngine()
    let parsedFlow = flow(source)
    let first = engine.layout(parsedFlow)
    let second = engine.layout(parsedFlow)

    #expect(first.nodes.count == second.nodes.count)
    for (a, b) in zip(first.nodes, second.nodes) {
        #expect(a.id == b.id)
        #expect(a.rank == b.rank)
        #expect(a.order == b.order)
    }

    let byRank = Dictionary(grouping: first.nodes, by: \.rank)
    for (_, nodesInRank) in byRank {
        let orders = nodesInRank.map(\.order).sorted()
        #expect(orders == Array(0..<orders.count))
    }
}

// MARK: - 4. Subgraph containment, including nesting

@Test("Subgraph frames enclose their member node frames and nested children")
func subgraphFramesContainMembersAndChildren() {
    let layout = MermaidLayoutEngine().layout(
        flow(
            """
            flowchart TD
              subgraph outer
                A-->B
                subgraph inner
                  C-->D
                end
              end
            """))

    let frameByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })
    guard let outer = layout.subgraphs.first(where: { $0.depth == 0 }),
        let inner = layout.subgraphs.first(where: { $0.depth == 1 })
    else {
        Issue.record("Expected outer and inner subgraph frames")
        return
    }

    for id in ["A", "B"] {
        guard let nodeFrame = frameByID[id] else {
            Issue.record("Missing frame for \(id)")
            continue
        }
        #expect(outer.frame.contains(nodeFrame))
    }
    for id in ["C", "D"] {
        guard let nodeFrame = frameByID[id] else {
            Issue.record("Missing frame for \(id)")
            continue
        }
        #expect(inner.frame.contains(nodeFrame))
    }
    #expect(outer.frame.contains(inner.frame))
}

// MARK: - 5. No-overlap node frames

@Test("Node frames never overlap, even across siblings sharing a rank")
func nodeFramesDoNotOverlap() {
    let layout = MermaidLayoutEngine().layout(
        flow("flowchart TD\nA-->D\nB-->D\nC-->D\nD-->E\nD-->F\nD-->G"))
    let frames = layout.nodes.map(\.frame)

    for i in 0..<frames.count {
        for j in (i + 1)..<frames.count {
            #expect(doesNotOverlap(frames[i], frames[j]))
        }
    }
}

// MARK: - 6. Cyclic graphs terminate with feedback edges

@Test(
    "Cyclic graphs terminate with finite ranks and at least one feedback edge",
    arguments: [
        "flowchart TD\nA-->B\nB-->C\nC-->A",
        "flowchart TD\nA-->B\nB-->A",
    ])
func cyclicGraphsTerminateWithFeedback(source: String) {
    let layout = MermaidLayoutEngine().layout(flow(source))

    #expect(layout.nodes.allSatisfy { $0.rank >= 0 })
    #expect(layout.canvasSize.width.isFinite)
    #expect(layout.canvasSize.height.isFinite)
    #expect(layout.edges.contains { $0.isFeedback })
}

// MARK: - 7. Self-loop terminates and routes as a bulge

@Test("Self-loop edges terminate and route as a bulge, not a feedback edge")
func selfLoopEdgesRouteAsBulge() {
    let layout = MermaidLayoutEngine().layout(flow("flowchart TD\nA-->A\nA-->B"))

    guard let selfEdge = layout.edges.first(where: { $0.from == "A" && $0.to == "A" }) else {
        Issue.record("Expected a self-loop edge for A")
        return
    }
    #expect(selfEdge.isFeedback == false)
    #expect(!selfEdge.waypoints.isEmpty)
    #expect(selfEdge.start != selfEdge.end)
}

// MARK: - 8. Direction controls the axis of advance

@Test(
    "Node coordinates advance along the axis matching the declared flow direction",
    arguments: [
        ("flowchart TD\nA-->B", MermaidFlow.Direction.topToBottom),
        ("flowchart LR\nA-->B", MermaidFlow.Direction.leftToRight),
        ("flowchart BT\nA-->B", MermaidFlow.Direction.bottomToTop),
        ("flowchart RL\nA-->B", MermaidFlow.Direction.rightToLeft),
    ] as [(String, MermaidFlow.Direction)])
func directionControlsAxisOfAdvance(_ pair: (String, MermaidFlow.Direction)) {
    let layout = MermaidLayoutEngine().layout(flow(pair.0))
    #expect(layout.direction == pair.1)

    let frameByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })
    guard let a = frameByID["A"], let b = frameByID["B"] else {
        Issue.record("Expected frames for A and B")
        return
    }

    switch pair.1 {
    case .topToBottom:
        #expect(b.minY > a.minY)
        #expect(a.minX == b.minX)
    case .bottomToTop:
        #expect(b.minY < a.minY)
        #expect(a.minX == b.minX)
    case .leftToRight:
        #expect(b.minX > a.minX)
        #expect(a.minY == b.minY)
    case .rightToLeft:
        #expect(b.minX < a.minX)
        #expect(a.minY == b.minY)
    }
}

// MARK: - 9. Empty graph

@Test("An empty flow diagram produces empty geometry with a finite non-negative canvas")
func emptyFlowProducesEmptyGeometry() {
    let layout = MermaidLayoutEngine().layout(flow("flowchart TD"))

    #expect(layout.nodes.isEmpty)
    #expect(layout.edges.isEmpty)
    #expect(layout.subgraphs.isEmpty)
    #expect(layout.canvasSize.width.isFinite && layout.canvasSize.width >= 0)
    #expect(layout.canvasSize.height.isFinite && layout.canvasSize.height >= 0)
}

// MARK: - 10. Disconnected components

@Test("Disconnected components each receive frames without overlapping")
func disconnectedComponentsAreLayoutedIndependently() {
    let layout = MermaidLayoutEngine().layout(flow("flowchart TD\nA-->B\nC"))
    let byID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })

    guard let c = byID["C"], let a = byID["A"], let b = byID["B"] else {
        Issue.record("Expected frames for A, B, and C")
        return
    }
    #expect(c.rank == 0)
    #expect(doesNotOverlap(c.frame, a.frame))
    #expect(doesNotOverlap(c.frame, b.frame))
}

// MARK: - 11. Sequence geometry

@Test("Sequence lifelines and message rows use durable identity and monotonic positions")
func sequenceLifelinesAndMessagesAreOrdered() {
    let seq = sequence("sequenceDiagram\nparticipant A\nparticipant B\nA->>B: hi\nB->>A: ok")
    let layout = MermaidLayoutEngine().layout(seq)

    #expect(layout.lifelines.count == 2)
    #expect(layout.messages.count == 2)
    guard layout.lifelines.count == 2, layout.messages.count == 2 else { return }

    #expect(layout.lifelines[0].x != layout.lifelines[1].x)
    #expect(layout.lifelines[0].x < layout.lifelines[1].x)

    #expect(layout.messages[0].y < layout.messages[1].y)
    #expect(layout.messages[0].id == seq.messages[0].id)
    #expect(layout.messages[1].id == seq.messages[1].id)

    #expect(layout.activations.isEmpty)
    #expect(layout.blocks.isEmpty)
}

@Test("Self-messages in a sequence share start and end X")
func sequenceSelfMessageSharesStartAndEndX() {
    let seq = sequence("sequenceDiagram\nparticipant A\nA->>A: note")
    let layout = MermaidLayoutEngine().layout(seq)

    guard let row = layout.messages.first else {
        Issue.record("Expected a self-message row")
        return
    }
    #expect(row.isSelfMessage)
    #expect(row.startX == row.endX)
}

// MARK: - 12. Sequence activations, blocks, notes, and arrow fidelity (M6)

@Test("A closed activation produces one span aligned to its request/response rows")
func sequenceActivationSpansRequestAndResponse() {
    let seq = sequence("sequenceDiagram\nA->>+B: req\nB-->>-A: resp")
    let layout = MermaidLayoutEngine().layout(seq)

    #expect(layout.activations.count == 1)
    guard let span = layout.activations.first, layout.messages.count == 2 else {
        Issue.record("Expected one activation span and two message rows")
        return
    }
    #expect(span.participant == "B")
    #expect(span.depth == 0)
    #expect(span.startY < span.endY)
    #expect(span.startY == layout.messages[0].y)
    #expect(span.endY == layout.messages[1].y)
}

@Test("Nested activations on the same participant produce distinct-depth spans at the same x")
func sequenceNestedActivationsHaveDistinctDepths() {
    let seq = sequence(
        "sequenceDiagram\nA->>+B: a\nA->>+B: b\nB-->>-A: c\nB-->>-A: d")
    let layout = MermaidLayoutEngine().layout(seq)

    let bSpans = layout.activations.filter { $0.participant == "B" }
    #expect(bSpans.count == 2)
    let depths = Set(bSpans.map(\.depth))
    #expect(depths == [0, 1])
    let xs = Set(bSpans.map(\.x))
    #expect(xs.count == 1)
}

@Test("An unclosed activation is flushed to the lifeline's bottom Y")
func sequenceUnclosedActivationFlushesToLifelineBottom() {
    let seq = sequence("sequenceDiagram\nA->>+B: req")
    let layout = MermaidLayoutEngine().layout(seq)

    #expect(layout.activations.count == 1)
    guard let span = layout.activations.first,
        let lifelineB = layout.lifelines.first(where: { $0.participant == "B" })
    else {
        Issue.record("Expected one activation span and a B lifeline")
        return
    }
    #expect(span.endY == lifelineB.bottomY)
}

@Test("A block frame encloses the rows nested inside it")
func sequenceBlockFrameEnclosesNestedRows() {
    let seq = sequence(
        """
        sequenceDiagram
        participant A
        participant B
        alt cond
          A->>B: m
        end
        """)
    let layout = MermaidLayoutEngine().layout(seq)

    #expect(layout.blocks.count == 1)
    guard let block = layout.blocks.first, let row = layout.messages.first else {
        Issue.record("Expected one block frame and one message row")
        return
    }
    #expect(block.frame.minY <= row.y)
    #expect(row.y <= block.frame.maxY)
    #expect(block.frame.minX <= row.startX)
    #expect(row.startX <= block.frame.maxX)
    #expect(block.frame.minX <= row.endX)
    #expect(row.endX <= block.frame.maxX)
}

@Test("A nested block is enclosed by its outer block at a greater depth")
func sequenceNestedBlockIsInsetWithinOuterBlock() {
    let seq = sequence(
        """
        sequenceDiagram
        participant A
        participant B
        alt cond
          loop retry
            A->>B: m
          end
        end
        """)
    let layout = MermaidLayoutEngine().layout(seq)

    guard let outer = layout.blocks.first(where: { $0.kind == "alt" }),
        let inner = layout.blocks.first(where: { $0.kind == "loop" })
    else {
        Issue.record("Expected an outer alt block and an inner loop block")
        return
    }
    #expect(outer.depth < inner.depth)
    #expect(outer.frame.contains(inner.frame))
}

@Test("A block's else divider sits between its top and bottom edges")
func sequenceBlockDividerSitsWithinFrame() {
    let seq = sequence(
        """
        sequenceDiagram
        participant A
        participant B
        alt a
          A->>B: m
        else b
          A->>B: n
        end
        """)
    let layout = MermaidLayoutEngine().layout(seq)

    #expect(layout.blocks.count == 1)
    guard let block = layout.blocks.first, let divider = block.dividers.first else {
        Issue.record("Expected one block with one divider")
        return
    }
    #expect(block.dividers.count == 1)
    #expect(block.frame.minY < divider.y)
    #expect(divider.y < block.frame.maxY)
    #expect(divider.label.contains("b"))
}

@Test("Note placement spans, sits left of, or sits right of its participants")
func sequenceNotePlacementRespectsParticipantPositions() {
    let over = sequence(
        "sequenceDiagram\nparticipant A\nparticipant B\nnote over A,B: hi")
    let overLayout = MermaidLayoutEngine().layout(over)
    guard let overNote = overLayout.notes.first,
        let xA = overLayout.lifelines.first(where: { $0.participant == "A" })?.x,
        let xB = overLayout.lifelines.first(where: { $0.participant == "B" })?.x
    else {
        Issue.record("Expected a note and lifelines for A and B")
        return
    }
    #expect(overNote.frame.minX <= min(xA, xB))
    #expect(overNote.frame.maxX >= max(xA, xB))

    let left = sequence(
        "sequenceDiagram\nparticipant A\nparticipant B\nnote left of A: hi")
    let leftLayout = MermaidLayoutEngine().layout(left)
    guard let leftNote = leftLayout.notes.first,
        let leftXA = leftLayout.lifelines.first(where: { $0.participant == "A" })?.x
    else {
        Issue.record("Expected a note and a lifeline for A")
        return
    }
    #expect(leftNote.frame.maxX <= leftXA)

    let right = sequence(
        "sequenceDiagram\nparticipant A\nparticipant B\nnote right of A: hi")
    let rightLayout = MermaidLayoutEngine().layout(right)
    guard let rightNote = rightLayout.notes.first,
        let rightXA = rightLayout.lifelines.first(where: { $0.participant == "A" })?.x
    else {
        Issue.record("Expected a note and a lifeline for A")
        return
    }
    #expect(rightNote.frame.minX >= rightXA)
}

@Test("Message rows carry the parsed message's arrow style")
func sequenceMessageRowsCarryArrowFidelity() {
    let seq = sequence("sequenceDiagram\nA-->>B: d\nA->>B: s")
    let layout = MermaidLayoutEngine().layout(seq)

    #expect(layout.messages.count == seq.messages.count)
    for (row, message) in zip(layout.messages, seq.messages) {
        #expect(row.arrow == message.arrow)
    }
}

@Test("The two M3 sequence fixtures still yield empty activations, blocks, and notes")
func sequenceEmptyEventStreamsStayEmpty() {
    let ordered = sequence(
        "sequenceDiagram\nparticipant A\nparticipant B\nA->>B: hi\nB->>A: ok")
    let orderedLayout = MermaidLayoutEngine().layout(ordered)
    #expect(orderedLayout.activations.isEmpty)
    #expect(orderedLayout.blocks.isEmpty)
    #expect(orderedLayout.notes.isEmpty)

    let selfMessage = sequence("sequenceDiagram\nparticipant A\nA->>A: note")
    let selfLayout = MermaidLayoutEngine().layout(selfMessage)
    #expect(selfLayout.activations.isEmpty)
    #expect(selfLayout.blocks.isEmpty)
    #expect(selfLayout.notes.isEmpty)
}
