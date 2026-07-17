import CoreGraphics
import Foundation

/// A pure, deterministic, one-shot geometry for a `MermaidFlow` model. Values here are
/// resolved coordinates in an abstract diagram canvas (origin top-left, Y grows downward,
/// matching `CGRect`/Canvas conventions), not SwiftUI view state.
nonisolated struct MermaidFlowLayout: Sendable {
    nonisolated struct NodeFrame: Sendable {
        let id: String
        let frame: CGRect
        let shape: MermaidFlow.NodeShape
        let rank: Int
        let order: Int
    }
    nonisolated struct EdgeGeometry: Sendable {
        let id: UUID
        let from: String
        let to: String
        let start: CGPoint
        let end: CGPoint
        let waypoints: [CGPoint]
        let arrowAnchor: CGPoint
        let arrowDirection: CGVector
        let isFeedback: Bool
        let line: MermaidFlow.EdgeLine
        let startHead: MermaidFlow.EdgeHead
        let endHead: MermaidFlow.EdgeHead
        let label: String
    }
    nonisolated struct SubgraphFrame: Sendable {
        let id: UUID
        let title: String
        let frame: CGRect
        let titleAnchor: CGPoint
        let depth: Int
    }
    let nodes: [NodeFrame]
    let edges: [EdgeGeometry]
    let subgraphs: [SubgraphFrame]
    let canvasSize: CGSize
    let direction: MermaidFlow.Direction
}

/// A pure, deterministic, one-shot geometry for a `MermaidSequence` model. `activations`
/// and `blocks` are structural placeholders (always empty from M3) so a later increment can
/// populate activation bars and `alt`/`opt`/`loop` frames without a shape change.
nonisolated struct MermaidSequenceLayout: Sendable {
    nonisolated struct Lifeline: Sendable {
        let participant: String
        let x: CGFloat
        let headFrame: CGRect
        let bottomY: CGFloat
    }
    nonisolated struct MessageRow: Sendable {
        let id: UUID
        let from: String
        let to: String
        let label: String
        let y: CGFloat
        let startX: CGFloat
        let endX: CGFloat
        let isSelfMessage: Bool
    }
    nonisolated struct ActivationSpan: Sendable {
        let participant: String
        let x: CGFloat
        let startY: CGFloat
        let endY: CGFloat
    }
    nonisolated struct BlockFrame: Sendable {
        let kind: String
        let title: String
        let frame: CGRect
    }
    let lifelines: [Lifeline]
    let messages: [MessageRow]
    let activations: [ActivationSpan]
    let blocks: [BlockFrame]
    let canvasSize: CGSize
}

/// Pure geometry engine for the frozen M2 Mermaid flow/sequence models. `layout(_:)` is a
/// one-shot, deterministic function with no cross-call state; callers (M4) are expected to
/// cache the result rather than recompute it per frame.
nonisolated struct MermaidLayoutEngine: Sendable {
    nonisolated struct Metrics: Sendable {
        var nodeHeight: CGFloat = 40
        var nodeMinWidth: CGFloat = 60
        var nodeBaseWidth: CGFloat = 24
        var perCharacterWidth: CGFloat = 8
        var rankGap: CGFloat = 70
        var siblingGap: CGFloat = 40
        var subgraphPadding: CGFloat = 16
        var subgraphTitleHeight: CGFloat = 22
        var margin: CGFloat = 24
        var lifelineGap: CGFloat = 120
        var messageGap: CGFloat = 44
        var headerHeight: CGFloat = 40
        var topMargin: CGFloat = 20
    }

    var metrics = Metrics()

    // MARK: - Flow layout

    func layout(_ flow: MermaidFlow) -> MermaidFlowLayout {
        let seedOrder = deterministicSeedOrder(flow)
        let (rankByID, feedbackEdgeIDs) = rankAssignment(for: flow, seedOrder: seedOrder)
        let orderByID = orderAssignment(for: flow, rank: rankByID, seedOrder: seedOrder)

        var idsByRank: [Int: [String]] = [:]
        for id in seedOrder {
            idsByRank[rankByID[id] ?? 0, default: []].append(id)
        }
        for rank in idsByRank.keys {
            idsByRank[rank]?.sort { (orderByID[$0] ?? 0) < (orderByID[$1] ?? 0) }
        }
        let maxRank = idsByRank.keys.max() ?? 0

        let axisVertical =
            direction(of: flow) == .topToBottom || direction(of: flow) == .bottomToTop
        let isReversedRank =
            direction(of: flow) == .bottomToTop || direction(of: flow) == .rightToLeft
        let rankTraversal: [Int] =
            isReversedRank ? Array((0...maxRank).reversed()) : Array(0...maxRank)

        var rankStart: [Int: CGFloat] = [:]
        var rankCursor: CGFloat = metrics.margin
        for rank in rankTraversal {
            let ids = idsByRank[rank] ?? []
            rankStart[rank] = rankCursor
            rankCursor +=
                rankAxisExtent(ids: ids, flow: flow, axisVertical: axisVertical) + metrics.rankGap
        }

        var crossStart: [String: CGFloat] = [:]
        for rank in 0...maxRank {
            var crossCursor: CGFloat = metrics.margin
            for id in idsByRank[rank] ?? [] {
                crossStart[id] = crossCursor
                let label = flow.nodesByID[id]?.label ?? id
                crossCursor +=
                    crossAxisExtent(for: label, axisVertical: axisVertical) + metrics.siblingGap
            }
        }

        var nodeFrameByID: [String: CGRect] = [:]
        var nodeFrames: [MermaidFlowLayout.NodeFrame] = []
        for rank in 0...maxRank {
            for id in idsByRank[rank] ?? [] {
                guard let node = flow.nodesByID[id] else { continue }
                let size = nodeSize(for: node.label)
                let rankPos = rankStart[rank] ?? metrics.margin
                let crossPos = crossStart[id] ?? metrics.margin
                let frame: CGRect =
                    axisVertical
                    ? CGRect(x: crossPos, y: rankPos, width: size.width, height: size.height)
                    : CGRect(x: rankPos, y: crossPos, width: size.width, height: size.height)
                nodeFrameByID[id] = frame
                nodeFrames.append(
                    .init(
                        id: id, frame: frame, shape: node.shape, rank: rank,
                        order: orderByID[id] ?? 0))
            }
        }

        let edgeGeometries = routeEdges(
            flow.edges, nodeFrameByID: nodeFrameByID, feedbackEdgeIDs: feedbackEdgeIDs)

        var subgraphFrames: [MermaidFlowLayout.SubgraphFrame] = []
        for subgraph in flow.subgraphs {
            let result = layoutSubgraph(subgraph, depth: 0, nodeFrameByID: nodeFrameByID)
            subgraphFrames.append(contentsOf: result.emitted)
        }

        let allRects = nodeFrames.map(\.frame) + subgraphFrames.map(\.frame)
        let canvasSize = canvasBounds(from: allRects)

        return MermaidFlowLayout(
            nodes: nodeFrames, edges: edgeGeometries, subgraphs: subgraphFrames,
            canvasSize: canvasSize, direction: flow.direction)
    }

    private func direction(of flow: MermaidFlow) -> MermaidFlow.Direction { flow.direction }

    // MARK: - Node sizing

    private func nodeWidth(for label: String) -> CGFloat {
        max(
            metrics.nodeMinWidth,
            metrics.nodeBaseWidth + metrics.perCharacterWidth * CGFloat(label.count))
    }

    private func nodeSize(for label: String) -> CGSize {
        CGSize(width: nodeWidth(for: label), height: metrics.nodeHeight)
    }

    private func rankAxisExtent(ids: [String], flow: MermaidFlow, axisVertical: Bool) -> CGFloat {
        if axisVertical { return metrics.nodeHeight }
        let widths = ids.map { nodeWidth(for: flow.nodesByID[$0]?.label ?? $0) }
        return widths.max() ?? metrics.nodeMinWidth
    }

    private func crossAxisExtent(for label: String, axisVertical: Bool) -> CGFloat {
        axisVertical ? nodeWidth(for: label) : metrics.nodeHeight
    }

    // MARK: - Deterministic seed order

    /// First appearance across edges (from then to, in edge order), then any remaining
    /// `nodesByID` keys sorted lexicographically. Never iterate `nodesByID` directly for
    /// ordering purposes — raw `Dictionary` iteration order is not stable across runs.
    private func deterministicSeedOrder(_ flow: MermaidFlow) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for edge in flow.edges {
            if seen.insert(edge.from).inserted { order.append(edge.from) }
            if seen.insert(edge.to).inserted { order.append(edge.to) }
        }
        for id in flow.nodesByID.keys.sorted() where !seen.contains(id) {
            seen.insert(id)
            order.append(id)
        }
        return order
    }

    // MARK: - Rank assignment (longest path + iterative-DFS back-edge detection)

    private enum DFSColor { case white, gray, black }

    private func rankAssignment(for flow: MermaidFlow, seedOrder: [String]) -> (
        rank: [String: Int], feedback: Set<UUID>
    ) {
        var adjacency: [String: [(edgeID: UUID, to: String)]] = [:]
        for edge in flow.edges where edge.from != edge.to {
            adjacency[edge.from, default: []].append((edge.id, edge.to))
        }

        var color: [String: DFSColor] = [:]
        for id in seedOrder { color[id] = .white }
        var feedback: Set<UUID> = []

        for start in seedOrder where color[start] == .white {
            var stack: [(node: String, index: Int)] = [(start, 0)]
            color[start] = .gray
            while !stack.isEmpty {
                let (node, index) = stack[stack.count - 1]
                let neighbors = adjacency[node] ?? []
                if index < neighbors.count {
                    stack[stack.count - 1].index += 1
                    let (edgeID, to) = neighbors[index]
                    switch color[to] ?? .white {
                    case .white:
                        color[to] = .gray
                        stack.append((to, 0))
                    case .gray:
                        feedback.insert(edgeID)
                    case .black:
                        break
                    }
                } else {
                    color[node] = .black
                    stack.removeLast()
                }
            }
        }

        var rank: [String: Int] = [:]
        for id in seedOrder { rank[id] = 0 }

        var dagAdjacency: [String: [String]] = [:]
        var inDegree: [String: Int] = [:]
        for id in seedOrder { inDegree[id] = 0 }
        for edge in flow.edges where edge.from != edge.to && !feedback.contains(edge.id) {
            dagAdjacency[edge.from, default: []].append(edge.to)
            inDegree[edge.to, default: 0] += 1
        }

        var queue = seedOrder.filter { (inDegree[$0] ?? 0) == 0 }
        var queueIndex = 0
        while queueIndex < queue.count {
            let node = queue[queueIndex]
            queueIndex += 1
            for next in dagAdjacency[node] ?? [] {
                rank[next] = max(rank[next] ?? 0, (rank[node] ?? 0) + 1)
                inDegree[next]? -= 1
                if inDegree[next] == 0 { queue.append(next) }
            }
        }

        return (rank, feedback)
    }

    // MARK: - In-rank ordering (deterministic barycenter-lite)

    private func orderAssignment(for flow: MermaidFlow, rank: [String: Int], seedOrder: [String])
        -> [String: Int]
    {
        let firstSeenIndex = Dictionary(
            uniqueKeysWithValues: seedOrder.enumerated().map { ($0.element, $0.offset) })

        var byRank: [Int: [String]] = [:]
        for id in seedOrder {
            byRank[rank[id] ?? 0, default: []].append(id)
        }
        let maxRank = byRank.keys.max() ?? 0

        var current: [Int: [String]] = [:]
        for r in 0...maxRank {
            current[r] = (byRank[r] ?? []).sorted {
                (firstSeenIndex[$0] ?? 0) < (firstSeenIndex[$1] ?? 0)
            }
        }

        var orderIndex: [String: Int] = [:]
        for r in 0...maxRank {
            for (i, id) in (current[r] ?? []).enumerated() { orderIndex[id] = i }
        }

        var undirectedNeighbors: [String: [String]] = [:]
        for edge in flow.edges where edge.from != edge.to {
            undirectedNeighbors[edge.from, default: []].append(edge.to)
            undirectedNeighbors[edge.to, default: []].append(edge.from)
        }

        if maxRank >= 1 {
            for r in 1...maxRank {
                let ids = current[r] ?? []
                func barycenter(_ id: String) -> Double {
                    let previousRankNeighbors = (undirectedNeighbors[id] ?? []).filter {
                        (rank[$0] ?? 0) == r - 1
                    }
                    guard !previousRankNeighbors.isEmpty else {
                        return Double(firstSeenIndex[id] ?? 0)
                    }
                    let sum = previousRankNeighbors.reduce(0.0) {
                        $0 + Double(orderIndex[$1] ?? 0)
                    }
                    return sum / Double(previousRankNeighbors.count)
                }
                let sorted = ids.sorted { lhs, rhs in
                    let bl = barycenter(lhs)
                    let br = barycenter(rhs)
                    if bl != br { return bl < br }
                    return (firstSeenIndex[lhs] ?? 0) < (firstSeenIndex[rhs] ?? 0)
                }
                current[r] = sorted
                for (i, id) in sorted.enumerated() { orderIndex[id] = i }
            }
        }

        var result: [String: Int] = [:]
        for r in 0...maxRank {
            for (i, id) in (current[r] ?? []).enumerated() { result[id] = i }
        }
        return result
    }

    // MARK: - Edge routing

    private func routeEdges(
        _ edges: [MermaidFlow.Edge], nodeFrameByID: [String: CGRect], feedbackEdgeIDs: Set<UUID>
    ) -> [MermaidFlowLayout.EdgeGeometry] {
        var results: [MermaidFlowLayout.EdgeGeometry] = []
        for edge in edges {
            guard let sourceFrame = nodeFrameByID[edge.from],
                let targetFrame = nodeFrameByID[edge.to]
            else { continue }

            if edge.from == edge.to {
                let start = CGPoint(
                    x: sourceFrame.maxX, y: sourceFrame.minY + sourceFrame.height * 0.3)
                let end = CGPoint(
                    x: sourceFrame.maxX, y: sourceFrame.minY + sourceFrame.height * 0.7)
                let bulgeX = sourceFrame.maxX + max(20, sourceFrame.width * 0.3)
                let waypoints = [CGPoint(x: bulgeX, y: start.y), CGPoint(x: bulgeX, y: end.y)]
                results.append(
                    .init(
                        id: edge.id, from: edge.from, to: edge.to, start: start, end: end,
                        waypoints: waypoints, arrowAnchor: end,
                        arrowDirection: CGVector(dx: -1, dy: 0),
                        isFeedback: false, line: edge.line, startHead: edge.startHead,
                        endHead: edge.endHead, label: edge.label))
                continue
            }

            let sourceCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
            let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            let start = pointOnRectBoundary(sourceFrame, towards: targetCenter)
            let end = pointOnRectBoundary(targetFrame, towards: sourceCenter)
            results.append(
                .init(
                    id: edge.id, from: edge.from, to: edge.to, start: start, end: end,
                    waypoints: [],
                    arrowAnchor: end, arrowDirection: normalizedVector(from: start, to: end),
                    isFeedback: feedbackEdgeIDs.contains(edge.id), line: edge.line,
                    startHead: edge.startHead, endHead: edge.endHead, label: edge.label))
        }
        return results
    }

    /// The point where a ray from `rect`'s center towards `target` exits `rect`'s boundary.
    private func pointOnRectBoundary(_ rect: CGRect, towards target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let scaleX = dx != 0 ? halfWidth / abs(dx) : CGFloat.greatestFiniteMagnitude
        let scaleY = dy != 0 ? halfHeight / abs(dy) : CGFloat.greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    private func normalizedVector(from start: CGPoint, to end: CGPoint) -> CGVector {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
    }

    // MARK: - Subgraph bounds (bottom-up, pre-order emission)

    private func layoutSubgraph(
        _ subgraph: MermaidFlow.Subgraph, depth: Int, nodeFrameByID: [String: CGRect]
    ) -> (frame: CGRect, emitted: [MermaidFlowLayout.SubgraphFrame]) {
        let childResults = subgraph.children.map {
            layoutSubgraph($0, depth: depth + 1, nodeFrameByID: nodeFrameByID)
        }

        var memberRects: [CGRect] = subgraph.nodeIDs.compactMap { nodeFrameByID[$0] }
        memberRects.append(contentsOf: childResults.map(\.frame))

        let padding = metrics.subgraphPadding
        let titleHeight = metrics.subgraphTitleHeight
        let frame: CGRect
        if memberRects.isEmpty {
            frame = CGRect(
                x: metrics.margin, y: metrics.margin, width: metrics.nodeMinWidth,
                height: metrics.nodeHeight + titleHeight)
        } else {
            var union = memberRects[0]
            for rect in memberRects.dropFirst() { union = union.union(rect) }
            let inset = union.insetBy(dx: -padding, dy: -padding)
            frame = CGRect(
                x: inset.minX, y: inset.minY - titleHeight, width: inset.width,
                height: inset.height + titleHeight)
        }

        let titleAnchor = CGPoint(x: frame.minX + padding, y: frame.minY + padding)
        let selfFrame = MermaidFlowLayout.SubgraphFrame(
            id: subgraph.id, title: subgraph.title, frame: frame, titleAnchor: titleAnchor,
            depth: depth)

        var emitted: [MermaidFlowLayout.SubgraphFrame] = [selfFrame]
        for child in childResults { emitted.append(contentsOf: child.emitted) }
        return (frame, emitted)
    }

    // MARK: - Canvas bounds

    private func canvasBounds(from rects: [CGRect]) -> CGSize {
        guard !rects.isEmpty else {
            return CGSize(width: metrics.margin * 2, height: metrics.margin * 2)
        }
        var union = rects[0]
        for rect in rects.dropFirst() { union = union.union(rect) }
        return CGSize(
            width: max(union.maxX + metrics.margin, metrics.margin * 2),
            height: max(union.maxY + metrics.margin, metrics.margin * 2))
    }

    // MARK: - Sequence layout

    func layout(_ sequence: MermaidSequence) -> MermaidSequenceLayout {
        var xByParticipant: [String: CGFloat] = [:]
        var headFrameByParticipant: [String: CGRect] = [:]
        for (index, name) in sequence.participants.enumerated() {
            let width = nodeWidth(for: name)
            let x = metrics.margin + width / 2 + CGFloat(index) * metrics.lifelineGap
            xByParticipant[name] = x
            headFrameByParticipant[name] = CGRect(
                x: x - width / 2, y: metrics.margin, width: width, height: metrics.headerHeight)
        }

        let headerBottom = metrics.margin + metrics.headerHeight
        var rows: [MermaidSequenceLayout.MessageRow] = []
        for (index, message) in sequence.messages.enumerated() {
            let y = headerBottom + metrics.topMargin + CGFloat(index) * metrics.messageGap
            let startX = xByParticipant[message.from] ?? metrics.margin
            let endX = xByParticipant[message.to] ?? metrics.margin
            rows.append(
                .init(
                    id: message.id, from: message.from, to: message.to, label: message.label, y: y,
                    startX: startX, endX: endX, isSelfMessage: message.from == message.to))
        }

        let bottomY = (rows.last?.y ?? headerBottom) + metrics.messageGap

        let lifelines: [MermaidSequenceLayout.Lifeline] = sequence.participants.map { name in
            .init(
                participant: name, x: xByParticipant[name] ?? metrics.margin,
                headFrame: headFrameByParticipant[name] ?? .zero, bottomY: bottomY)
        }

        let rightmostX = lifelines.map { $0.headFrame.maxX }.max() ?? metrics.margin
        let canvasSize = CGSize(
            width: max(rightmostX + metrics.margin, metrics.margin * 2),
            height: max(bottomY + metrics.margin, metrics.margin * 2))

        return MermaidSequenceLayout(
            lifelines: lifelines, messages: rows, activations: [], blocks: [],
            canvasSize: canvasSize)
    }
}
