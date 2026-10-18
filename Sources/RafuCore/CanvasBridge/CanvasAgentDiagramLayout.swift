import Foundation

/// The layered layout behind `diagram_build`. Pure and deterministic: the
/// same spec always gives the same rects.
///
/// - Layers: each node goes one layer after its furthest predecessor. Cycles
///   are broken in node order.
/// - Main chain: the longest path sits on one axis (slot 0), so the main flow
///   reads as one straight line. Ties prefer an end that no skip edge reaches,
///   then node order.
/// - Branches: the other nodes of a layer take slots on both sides of the
///   axis (below and above for `right`, right and left for `down`), ordered by
///   the barycentre of their predecessors (forward sweep) and then of their
///   successors (backward sweep). This removes most crossings.
/// - Skip edges: a node that an edge reaches across two or more layers moves
///   outward (at most three slots) when the straight line from its source would
///   pass through a node in between, and the outer slot is free.
/// - Gaps: for `right`, the gap after a layer is
///   `max(96, label width + 56)`, at most 320, from the longest label on an
///   edge that crosses it. Rows are 64 pt apart, 96 pt when a labelled edge
///   runs between rows. For `down` the two roles swap. When the result would
///   not fit in one frame (2,000 pt per side), the gaps shrink, to 48 pt at
///   the least.
public nonisolated enum CanvasAgentDiagramLayout {
    /// The gap between layers without a label (`right`).
    public static let minimumGap = 96.0
    public static let maximumGap = 320.0
    /// Room around a label pill in a gap: arrowhead, port spread, clearance.
    public static let labelAllowance = 56.0
    /// The label font is 11 pt; 7.2 pt per character is a safe average.
    public static let characterWidth = 7.2
    /// Horizontal padding inside a label pill (8 pt per side).
    public static let pillPadding = 16.0
    /// The space between rows (nodes of one layer).
    public static let rowGap = 64.0
    /// The space between rows when a labelled edge runs between them.
    public static let labelledRowGap = 96.0
    /// The smallest gap when the layout shrinks to fit one frame.
    public static let compressedGap = 48.0
    /// The same values as the app's `CanvasFrameLayout`.
    public static let framePadding = 32.0
    public static let frameTitleBand = 36.0
    public static let maximumFrameSide = 2_000.0

    public static func size(of node: CanvasAgentDiagramSpec.Node) -> (width: Double, height: Double)
    {
        switch node.kind {
        case "service_icon": (160, 128)
        case "note": (260, 180)
        default: (200, 120)
        }
    }

    /// The estimated width of a label pill, or 0 for no label.
    public static func estimatedLabelWidth(_ label: String?) -> Double {
        guard let label, !label.isEmpty else { return 0 }
        return Double(label.count) * characterWidth + pillPadding
    }

    /// The gap that fits a label pill of `labelWidth` (0: no label).
    public static func gapWidth(forLabelWidth labelWidth: Double) -> Double {
        guard labelWidth > 0 else { return minimumGap }
        return min(maximumGap, max(minimumGap, labelWidth + labelAllowance))
    }

    /// Layer index per node id. Ready nodes are placed in rounds; when a
    /// cycle leaves no ready node, the earliest remaining node is placed.
    public static func layers(_ spec: CanvasAgentDiagramSpec) -> [String: Int] {
        var incoming: [String: Set<String>] = [:]
        for edge in spec.edges where edge.from != edge.to {
            incoming[edge.to, default: []].insert(edge.from)
        }
        var remaining = spec.nodes.map(\.id)
        var layer: [String: Int] = [:]
        while !remaining.isEmpty {
            let open = Set(remaining)
            var ready = remaining.filter { (incoming[$0] ?? []).isDisjoint(with: open) }
            if ready.isEmpty { ready = [remaining[0]] }
            for id in ready {
                layer[id] = (incoming[id] ?? []).compactMap { layer[$0] }.map { $0 + 1 }.max() ?? 0
            }
            let placed = Set(ready)
            remaining.removeAll { placed.contains($0) }
        }
        return layer
    }

    // MARK: Graph

    /// The spec as the layout sees it: unique nodes in spec order, their
    /// layers, and the forward edges (from a lower layer to a higher one).
    struct Graph {
        var ids: [String] = []
        var nodes: [String: CanvasAgentDiagramSpec.Node] = [:]
        var order: [String: Int] = [:]
        var layer: [String: Int] = [:]
        var predecessors: [String: [String]] = [:]
        var successors: [String: [String]] = [:]
        /// Node ids per layer, in spec order, by ascending layer.
        var layerLists: [[String]] = []

        init(_ spec: CanvasAgentDiagramSpec) {
            for node in spec.nodes where nodes[node.id] == nil {
                nodes[node.id] = node
                order[node.id] = ids.count
                ids.append(node.id)
            }
            layer = CanvasAgentDiagramLayout.layers(spec)
            for edge in spec.edges where edge.from != edge.to {
                guard let from = layer[edge.from], let to = layer[edge.to], from < to else {
                    continue
                }
                if !(predecessors[edge.to] ?? []).contains(edge.from) {
                    predecessors[edge.to, default: []].append(edge.from)
                    successors[edge.from, default: []].append(edge.to)
                }
            }
            var byLayer: [Int: [String]] = [:]
            for id in ids { byLayer[layer[id] ?? 0, default: []].append(id) }
            layerLists = byLayer.keys.sorted().map { byLayer[$0] ?? [] }
        }

        func rank(_ id: String) -> Int { order[id] ?? Int.max }
        func level(_ id: String) -> Int { layer[id] ?? 0 }

        /// Forward predecessors at least two layers back.
        func skipPredecessors(of id: String) -> [String] {
            (predecessors[id] ?? []).filter { level(id) - level($0) >= 2 }
        }
    }

    /// The longest path through the forward edges, as a set of node ids.
    static func mainChain(_ graph: Graph) -> Set<String> {
        let sorted = graph.ids.sorted { (graph.level($0), graph.rank($0)) < (graph.level($1), graph.rank($1)) }
        var length: [String: Int] = [:]
        var previous: [String: String] = [:]
        for id in sorted {
            var best = 0
            let candidates = (graph.predecessors[id] ?? []).sorted { graph.rank($0) < graph.rank($1) }
            for candidate in candidates {
                let value = length[candidate] ?? 0
                if value > best {
                    best = value
                    previous[id] = candidate
                }
            }
            length[id] = best + 1
        }
        let end = sorted.min { lhs, rhs in
            let l = (-(length[lhs] ?? 0), graph.skipPredecessors(of: lhs).count, graph.rank(lhs))
            let r = (-(length[rhs] ?? 0), graph.skipPredecessors(of: rhs).count, graph.rank(rhs))
            return l < r
        }
        var chain = Set<String>()
        var cursor = end
        while let id = cursor, chain.insert(id).inserted { cursor = previous[id] }
        return chain
    }

    // MARK: Slots

    /// Integer slots across the axis per node. The chain node of a layer is
    /// at 0; the others keep the order of `key` (their barycentre).
    static func placeLayer(
        _ ids: [String], chain: Set<String>, graph: Graph, key: (String) -> Double,
        into slot: inout [String: Int]
    ) {
        let keyed = ids.map { (id: $0, key: key($0)) }
            .sorted { ($0.key, graph.rank($0.id)) < ($1.key, graph.rank($1.id)) }
        if let axis = ids.first(where: { chain.contains($0) }) {
            var below: [String] = []
            var above: [String] = []
            var ties: [String] = []
            for item in keyed where item.id != axis {
                if item.key > 0.000_1 {
                    below.append(item.id)
                } else if item.key < -0.000_1 {
                    above.append(item.id)
                } else {
                    ties.append(item.id)
                }
            }
            // Ties with the axis alternate: one below, one above, nearest first.
            var tiesBelow: [String] = []
            var tiesAbove: [String] = []
            for (index, id) in ties.enumerated() {
                if index.isMultiple(of: 2) { tiesBelow.append(id) } else { tiesAbove.append(id) }
            }
            let positive = tiesBelow + below
            let negative = above + tiesAbove.reversed()
            slot[axis] = 0
            for (index, id) in positive.enumerated() { slot[id] = index + 1 }
            for (index, id) in negative.enumerated() { slot[id] = index - negative.count }
        } else if !keyed.isEmpty {
            let offsets = keyed.enumerated().map { $1.key - Double($0) }
            let start = Int((offsets.reduce(0, +) / Double(offsets.count)).rounded())
            for (index, item) in keyed.enumerated() { slot[item.id] = start + index }
        }
    }

    static func mean(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    /// True when the straight line from `source` to `target` passes within
    /// `clearance` slots of a node in a layer between them.
    static func lineIsBlocked(
        from source: String, to target: String, targetSlot: Int, graph: Graph,
        slot: [String: Int], members: [Int: [String]], clearance: Double
    ) -> Bool {
        let first = graph.level(source)
        let last = graph.level(target)
        guard last - first >= 2, let start = slot[source] else { return false }
        for level in (first + 1)..<last {
            let t = Double(level - first) / Double(last - first)
            let across = Double(start) + t * Double(targetSlot - start)
            for other in members[level] ?? [] {
                guard let occupied = slot[other] else { continue }
                if abs(across - Double(occupied)) < clearance { return true }
            }
        }
        return false
    }

    /// `clearance` is half a node plus 8 pt, in slots.
    static func slots(_ graph: Graph, chain: Set<String>, clearance: Double) -> [String: Int] {
        var slot: [String: Int] = [:]
        // Forward sweep: barycentre of predecessors.
        for ids in graph.layerLists {
            let current = slot
            placeLayer(ids, chain: chain, graph: graph, key: { id in
                mean((graph.predecessors[id] ?? []).compactMap { current[$0] })
                    ?? Double(current[id] ?? 0)
            }, into: &slot)
        }
        // Backward sweep: barycentre of successors.
        for ids in graph.layerLists.reversed() {
            let current = slot
            placeLayer(ids, chain: chain, graph: graph, key: { id in
                mean((graph.successors[id] ?? []).compactMap { current[$0] })
                    ?? Double(current[id] ?? 0)
            }, into: &slot)
        }
        // Skip edges: move an outermost node outward when its line is blocked.
        var members: [Int: [String]] = [:]
        for ids in graph.layerLists {
            for id in ids { members[graph.level(id), default: []].append(id) }
        }
        for ids in graph.layerLists {
            for id in ids where !chain.contains(id) {
                let sources = graph.skipPredecessors(of: id)
                guard let current = slot[id], !sources.isEmpty else { continue }
                func blocked(_ candidate: Int) -> Bool {
                    sources.contains {
                        lineIsBlocked(
                            from: $0, to: id, targetSlot: candidate, graph: graph, slot: slot,
                            members: members, clearance: clearance)
                    }
                }
                guard blocked(current) else { continue }
                let others = ids.filter { $0 != id }.compactMap { slot[$0] }
                let direction = current >= 0 ? 1 : -1
                let outermost =
                    direction > 0
                    ? others.allSatisfy { $0 < current } : others.allSatisfy { $0 > current }
                guard outermost else { continue }
                for step in 1...3 where !blocked(current + direction * step) {
                    slot[id] = current + direction * step
                    break
                }
            }
        }
        return slot
    }

    // MARK: Gaps

    /// Gaps after each layer (`gaps[i]` lies between layer lists i and i+1)
    /// and the gap between rows.
    static func gaps(_ spec: CanvasAgentDiagramSpec, graph: Graph, slot: [String: Int], down: Bool)
        -> (layers: [Double], row: Double)
    {
        let levels = graph.layerLists.map { graph.level($0[0]) }
        var position: [Int: Int] = [:]
        for (index, level) in levels.enumerated() { position[level] = index }
        var layerLabel = Array(repeating: 0.0, count: max(0, levels.count - 1))
        var rowLabel = 0.0
        for edge in spec.edges where edge.from != edge.to {
            let width = estimatedLabelWidth(edge.label)
            guard width > 0, let from = position[graph.level(edge.from)],
                let to = position[graph.level(edge.to)]
            else { continue }
            let low = min(from, to)
            let high = max(from, to)
            for index in low..<high { layerLabel[index] = max(layerLabel[index], width) }
            // Between rows: within one layer, or a steep step to the next one.
            let rows = abs((slot[edge.from] ?? 0) - (slot[edge.to] ?? 0))
            if high == low || (high - low == 1 && rows >= 2) {
                rowLabel = max(rowLabel, width)
            }
        }
        if down {
            // Layers stack vertically: a label needs height, rows need width.
            let layerGaps = layerLabel.map { $0 > 0 ? labelledRowGap : rowGap }
            let row = rowLabel > 0 ? max(rowGap, gapWidth(forLabelWidth: rowLabel)) : rowGap
            return (layerGaps, row)
        }
        return (layerLabel.map { gapWidth(forLabelWidth: $0) }, rowLabel > 0 ? labelledRowGap : rowGap)
    }

    /// `gaps` shrunk proportionally (to `compressedGap` at the least) so
    /// that `fixed + sum(gaps)` fits in `limit`.
    static func fitted(_ gaps: [Double], fixed: Double, limit: Double) -> [Double] {
        let total = gaps.reduce(0, +)
        guard !gaps.isEmpty, fixed + total > limit else { return gaps }
        let floor = Double(gaps.count) * compressedGap
        let available = limit - fixed
        guard available > floor, total > floor else {
            return gaps.map { min($0, compressedGap) }
        }
        let ratio = (available - floor) / (total - floor)
        return gaps.map { compressedGap + max(0, $0 - compressedGap) * ratio }
    }

    // MARK: Rects

    /// Top-left rects relative to the origin, keyed by local node id. The
    /// top-left corner of the whole layout is (`originX`, `originY`).
    public static func rects(
        for spec: CanvasAgentDiagramSpec, originX: Double = 0, originY: Double = 0
    ) -> [String: CanvasAgentRect] {
        let graph = Graph(spec)
        guard !graph.ids.isEmpty else { return [:] }
        let down = spec.direction == "down"
        func alongSize(_ id: String) -> Double {
            guard let node = graph.nodes[id] else { return 0 }
            return down ? size(of: node).height : size(of: node).width
        }
        func acrossSize(_ id: String) -> Double {
            guard let node = graph.nodes[id] else { return 0 }
            return down ? size(of: node).width : size(of: node).height
        }
        let thickest = graph.ids.map(acrossSize).max() ?? 0
        let chain = mainChain(graph)
        let clearance = min(0.5, (thickest / 2 + 8) / (thickest + rowGap))
        let slot = slots(graph, chain: chain, clearance: clearance)
        let thickness = graph.layerLists.map { ids in ids.map(alongSize).max() ?? 0 }
        let spacing = gaps(spec, graph: graph, slot: slot, down: down)
        // The frame adds padding on both sides and a title band at the top.
        let padding = 2 * framePadding
        let alongLimit = maximumFrameSide - padding - (down ? frameTitleBand : 0)
        let acrossLimit = maximumFrameSide - padding - (down ? 0 : frameTitleBand)
        let layerGaps = fitted(
            spacing.layers, fixed: thickness.reduce(0, +), limit: alongLimit)
        let slotValues = graph.ids.compactMap { slot[$0] }
        let rows = (slotValues.max() ?? 0) - (slotValues.min() ?? 0)
        let rowGap =
            fitted(
                Array(repeating: spacing.row, count: rows), fixed: thickest * Double(rows + 1),
                limit: acrossLimit
            ).first ?? spacing.row
        let pitch = thickest + rowGap

        var placed: [(id: String, along: Double, across: Double)] = []
        var start = 0.0
        for (index, ids) in graph.layerLists.enumerated() {
            for id in ids {
                let along = start + (thickness[index] - alongSize(id)) / 2
                let across = Double(slot[id] ?? 0) * pitch - acrossSize(id) / 2
                placed.append((id, along, across))
            }
            start += thickness[index] + (index < layerGaps.count ? layerGaps[index] : 0)
        }
        let minAlong = placed.map(\.along).min() ?? 0
        let minAcross = placed.map(\.across).min() ?? 0
        var result: [String: CanvasAgentRect] = [:]
        for item in placed {
            guard let node = graph.nodes[item.id] else { continue }
            let size = size(of: node)
            let along = (item.along - minAlong).rounded()
            let across = (item.across - minAcross).rounded()
            result[item.id] = CanvasAgentRect(
                x: originX + (down ? across : along), y: originY + (down ? along : across),
                width: size.width, height: size.height)
        }
        return result
    }

    /// The frame rect around `rects`, with the app's frame padding and title
    /// band (`CanvasFrameLayout.enclosingRect`), clamped to 2,000 pt per side.
    public static func bounds(
        _ rects: [CanvasAgentRect], padding: Double = framePadding,
        titleBand: Double = frameTitleBand
    ) -> CanvasAgentRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x)
            minY = min(minY, rect.y)
            maxX = max(maxX, rect.x + rect.width)
            maxY = max(maxY, rect.y + rect.height)
        }
        func clamp(_ value: Double) -> Double { min(50_000, max(-50_000, value)) }
        let width = min(maximumFrameSide, maxX - minX + 2 * padding)
        let height = min(maximumFrameSide, maxY - minY + 2 * padding + titleBand)
        return CanvasAgentRect(
            x: clamp((minX - padding).rounded()), y: clamp((minY - padding - titleBand).rounded()),
            width: max(96, width.rounded()), height: max(64, height.rounded()))
    }
}
