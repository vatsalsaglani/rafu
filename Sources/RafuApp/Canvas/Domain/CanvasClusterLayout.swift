import Foundation

/// Tidy Up for an Ensemble: groups related cards into clusters instead of
/// flowing every card into rows. Pure geometry on values; nothing here touches
/// UI or document state.
///
/// The rules, in order:
/// 1. A frame and its members (transitively) are one rigid unit. Members keep
///    their offsets; a frame is never returned, because the board derives its
///    rect from its members (`CanvasFrameLayout.fitted`).
/// 2. A loose drawing (no link, not in a frame) within `attachDistance` of a
///    unit moves rigidly with that unit. Other drawings that sit close to
///    each other move as one group and are placed last.
/// 3. A cluster is a set of units joined by links.
/// 4. In a cluster the most attended unit is the hub. Its linked units sit
///    around it; units one more link away sit beyond those. A bounded
///    separation pass then removes any overlap.
/// 5. Clusters go in order of recent focus, then attention, then size, and are
///    packed into shelves as wide as the visible board's shape.
///
/// Every sort ends on board position and then id, so the result does not
/// depend on the order of `nodes`. Sizes are read, never written.
nonisolated enum CanvasClusterLayout {
    struct Node: Equatable, Sendable {
        let id: CanvasCardID
        var rect: CanvasRect
        /// The members of a frame; nil for every other card.
        var frameMembers: [CanvasCardID]?
        /// A whiteboard item: shape, stroke, text or icon.
        var isDrawing: Bool

        init(
            id: CanvasCardID, rect: CanvasRect, frameMembers: [CanvasCardID]? = nil,
            isDrawing: Bool = false
        ) {
            self.id = id
            self.rect = rect
            self.frameMembers = frameMembers
            self.isDrawing = isDrawing
        }
    }

    /// A loose drawing this close to a unit travels with it.
    static let attachDistance = 120.0
    private static let maximumSweeps = 80

    /// New rects for the cards that move. A frame that has members is not in
    /// the result. `attention` is decayed seconds per card; empty means
    /// links only. `targetAspect` is the visible board's width over height.
    static func clustered(
        nodes: [Node], edges: [(CanvasCardID, CanvasCardID)],
        attention: [CanvasCardID: Double], lastFocused: [CanvasCardID: Date],
        targetAspect: Double, gap: Double = 24, clusterGap: Double = 72
    ) -> [CanvasCardID: CanvasRect] {
        var builder = Builder(
            nodes: nodes, edges: edges, attention: attention, lastFocused: lastFocused,
            gap: gap)
        return builder.run(targetAspect: targetAspect, clusterGap: clusterGap)
    }

    // MARK: Builder

    private struct Unit {
        var members: [Int]
        /// Bounds before loose drawings joined; distance is measured to this.
        var core: CGRect
        var bounds: CGRect
        var isLoose = false
        var attention = 0.0
        var lastFocused: Date?
        var neighbours: Set<Int> = []
    }

    private struct Builder {
        let ordered: [Node]
        let edges: [(Int, Int)]
        let attention: [CanvasCardID: Double]
        let lastFocused: [CanvasCardID: Date]
        let gap: Double
        var units: [Unit] = []

        init(
            nodes: [Node], edges rawEdges: [(CanvasCardID, CanvasCardID)],
            attention: [CanvasCardID: Double], lastFocused: [CanvasCardID: Date], gap: Double
        ) {
            var seen = Set<CanvasCardID>()
            ordered = nodes.filter { seen.insert($0.id).inserted }.sorted {
                if $0.rect.y != $1.rect.y { return $0.rect.y < $1.rect.y }
                if $0.rect.x != $1.rect.x { return $0.rect.x < $1.rect.x }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            let index = Dictionary(
                uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
            edges = rawEdges.compactMap { pair in
                guard let a = index[pair.0], let b = index[pair.1], a != b else { return nil }
                return (a, b)
            }
            self.attention = attention
            self.lastFocused = lastFocused
            self.gap = max(0, gap)
        }

        mutating func run(targetAspect: Double, clusterGap: Double) -> [CanvasCardID: CanvasRect] {
            guard !ordered.isEmpty else { return [:] }
            let derivedFrames = buildUnits()
            let clusters = buildClusters()
            let aspect = targetAspect.isFinite ? min(3, max(0.5, targetAspect)) : 1.6
            return place(
                clusters, derivedFrames: derivedFrames, aspect: aspect,
                clusterGap: max(0, clusterGap))
        }

        // MARK: Units

        /// Fills `units`; returns the node indices that are frames with members.
        private mutating func buildUnits() -> Set<Int> {
            let index = Dictionary(
                uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
            var derived = Set<Int>()
            var membership = DisjointSet(count: ordered.count)
            for (position, node) in ordered.enumerated() {
                let members = (node.frameMembers ?? []).compactMap { index[$0] }.filter {
                    $0 != position
                }
                guard !members.isEmpty else { continue }
                derived.insert(position)
                for member in members { membership.union(position, member) }
            }
            var linked = Set<Int>()
            for (a, b) in edges {
                linked.insert(a)
                linked.insert(b)
            }
            func isLooseDrawing(_ position: Int, _ membership: inout DisjointSet) -> Bool {
                ordered[position].isDrawing && !linked.contains(position)
                    && membership.size(of: position) == 1
            }
            var unitOfRoot: [Int: Int] = [:]
            var drawings: [Int] = []
            for position in ordered.indices {
                if isLooseDrawing(position, &membership) {
                    drawings.append(position)
                    continue
                }
                let root = membership.find(position)
                if let unit = unitOfRoot[root] {
                    units[unit].members.append(position)
                    units[unit].core = units[unit].core.union(ordered[position].rect.cgRect)
                } else {
                    unitOfRoot[root] = units.count
                    let rect = ordered[position].rect.cgRect
                    units.append(Unit(members: [position], core: rect, bounds: rect))
                }
            }
            let primaryCount = units.count
            var unattached: [Int] = []
            for drawing in drawings {
                let rect = ordered[drawing].rect.cgRect
                var best: (unit: Int, distance: Double)?
                for unit in 0..<primaryCount {
                    let distance = Self.distance(units[unit].core, rect)
                    guard distance <= CanvasClusterLayout.attachDistance else { continue }
                    if best == nil || distance < best!.distance { best = (unit, distance) }
                }
                if let best {
                    units[best.unit].members.append(drawing)
                } else {
                    unattached.append(drawing)
                }
            }
            for unit in 0..<primaryCount {
                units[unit].bounds = units[unit].members.map { ordered[$0].rect.cgRect }
                    .reduce(units[unit].core) { $0.union($1) }
            }
            var groups = DisjointSet(count: unattached.count)
            for first in unattached.indices {
                for second in unattached.indices where second > first {
                    if Self.distance(
                        ordered[unattached[first]].rect.cgRect,
                        ordered[unattached[second]].rect.cgRect)
                        <= CanvasClusterLayout.attachDistance
                    {
                        groups.union(first, second)
                    }
                }
            }
            var looseOfRoot: [Int: Int] = [:]
            for (slot, drawing) in unattached.enumerated() {
                let rect = ordered[drawing].rect.cgRect
                let root = groups.find(slot)
                if let unit = looseOfRoot[root] {
                    units[unit].members.append(drawing)
                    units[unit].core = units[unit].core.union(rect)
                    units[unit].bounds = units[unit].core
                } else {
                    looseOfRoot[root] = units.count
                    units.append(Unit(members: [drawing], core: rect, bounds: rect, isLoose: true))
                }
            }
            var unitOf = [Int](repeating: 0, count: ordered.count)
            for (unit, value) in units.enumerated() {
                for member in value.members { unitOf[member] = unit }
                units[unit].attention = value.members.reduce(0) {
                    $0 + max(0, attention[ordered[$1].id] ?? 0)
                }
                units[unit].lastFocused = value.members.compactMap { lastFocused[ordered[$0].id] }
                    .max()
            }
            for (a, b) in edges where unitOf[a] != unitOf[b] {
                units[unitOf[a]].neighbours.insert(unitOf[b])
                units[unitOf[b]].neighbours.insert(unitOf[a])
            }
            return derived
        }

        /// Gap between two rects; zero when they touch or overlap.
        private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
            let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
            let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
            return (dx * dx + dy * dy).squareRoot()
        }

        // MARK: Clusters

        private struct Cluster {
            var units: [Int]
            var origins: [Int: CGPoint] = [:]
            var size = CGSize.zero
            var attention = 0.0
            var lastFocused: Date?
            var isLoose = false
        }

        private func buildClusters() -> [Cluster] {
            var components = DisjointSet(count: units.count)
            for (unit, value) in units.enumerated() {
                for other in value.neighbours { components.union(unit, other) }
            }
            var byRoot: [Int: Int] = [:]
            var clusters: [Cluster] = []
            for unit in units.indices {
                let root = components.find(unit)
                if let cluster = byRoot[root] {
                    clusters[cluster].units.append(unit)
                } else {
                    byRoot[root] = clusters.count
                    clusters.append(Cluster(units: [unit]))
                }
            }
            for position in clusters.indices {
                let members = clusters[position].units
                clusters[position].attention = members.reduce(0) { $0 + units[$1].attention }
                clusters[position].lastFocused = members.compactMap { units[$0].lastFocused }.max()
                clusters[position].isLoose = members.allSatisfy { units[$0].isLoose }
                layout(&clusters[position])
            }
            clusters.sort { a, b in
                if a.isLoose != b.isLoose { return !a.isLoose }
                if a.lastFocused != b.lastFocused {
                    guard let first = a.lastFocused else { return false }
                    guard let second = b.lastFocused else { return true }
                    return first > second
                }
                if a.attention != b.attention { return a.attention > b.attention }
                if a.units.count != b.units.count { return a.units.count > b.units.count }
                return (a.units.min() ?? 0) < (b.units.min() ?? 0)
            }
            return clusters
        }

        /// Hub first: more attention, then more links, then board position.
        private func ranks(_ a: Int, before b: Int) -> Bool {
            if units[a].attention != units[b].attention {
                return units[a].attention > units[b].attention
            }
            if units[a].neighbours.count != units[b].neighbours.count {
                return units[a].neighbours.count > units[b].neighbours.count
            }
            return a < b
        }

        /// Fills `origins` (unit top-left, relative to the cluster) and `size`.
        private func layout(_ cluster: inout Cluster) {
            let members = cluster.units.sorted()
            guard members.count > 1, let hub = members.min(by: { ranks($0, before: $1) }) else {
                if let only = members.first {
                    cluster.origins[only] = .zero
                    cluster.size = units[only].bounds.size
                }
                return
            }
            var centre: [Int: CGPoint] = [hub: .zero]
            var heading: [Int: Double] = [:]
            var queue = [hub]
            var head = 0
            var seen: Set<Int> = [hub]
            while head < queue.count {
                let parent = queue[head]
                head += 1
                let children = units[parent].neighbours.filter { !seen.contains($0) }.sorted {
                    ranks($0, before: $1)
                }
                seen.formUnion(children)
                for (position, child) in children.enumerated() {
                    let count = Double(children.count)
                    let theta: Double
                    if parent == hub {
                        let start = children.count <= 2 ? 0 : -Double.pi / 2
                        theta = start + 2 * Double.pi * Double(position) / count
                    } else {
                        let spread = min(0.7, 2.0 / count)
                        theta =
                            (heading[parent] ?? 0) + (Double(position) - (count - 1) / 2) * spread
                    }
                    let direction = CGPoint(x: cos(theta), y: sin(theta))
                    let distance =
                        Self.reach(units[parent].bounds.size, direction)
                        + Self.reach(units[child].bounds.size, direction) + gap
                    let origin = centre[parent] ?? .zero
                    centre[child] = CGPoint(
                        x: origin.x + direction.x * distance, y: origin.y + direction.y * distance)
                    heading[child] = theta
                }
                queue.append(contentsOf: children)
            }
            separate(members, centre: &centre, hub: hub)
            guard !hasOverlap(members, centre: centre) else {
                // The separation budget ran out: shelf the units, hub first.
                let order = members.sorted { ranks($0, before: $1) }
                let sizes = order.map { units[$0].bounds.size }
                let area = sizes.reduce(0.0) {
                    $0 + (Double($1.width) + gap) * (Double($1.height) + gap)
                }
                let widest = Double(sizes.map(\.width).max() ?? 0)
                let packed = Self.shelves(sizes, width: max(widest, area.squareRoot()), gap: gap)
                for (slot, unit) in order.enumerated() {
                    cluster.origins[unit] = packed.origins[slot]
                }
                cluster.size = packed.size
                return
            }
            var minX = Double.infinity
            var minY = Double.infinity
            var maxX = -Double.infinity
            var maxY = -Double.infinity
            for unit in members {
                guard let point = centre[unit] else { continue }
                let size = units[unit].bounds.size
                minX = min(minX, point.x - size.width / 2)
                minY = min(minY, point.y - size.height / 2)
                maxX = max(maxX, point.x + size.width / 2)
                maxY = max(maxY, point.y + size.height / 2)
            }
            for unit in members {
                guard let point = centre[unit] else { continue }
                let size = units[unit].bounds.size
                cluster.origins[unit] = CGPoint(
                    x: point.x - size.width / 2 - minX, y: point.y - size.height / 2 - minY)
            }
            cluster.size = CGSize(width: maxX - minX, height: maxY - minY)
        }

        /// Distance from a rect's centre to its edge along a unit direction.
        private static func reach(_ size: CGSize, _ direction: CGPoint) -> Double {
            let across = abs(Double(direction.x))
            let down = abs(Double(direction.y))
            let horizontal = across > 1e-9 ? Double(size.width) / 2 / across : .infinity
            let vertical = down > 1e-9 ? Double(size.height) / 2 / down : .infinity
            return min(horizontal, vertical)
        }

        /// Pushes overlapping units apart along the axis of least overlap.
        /// The hub never moves. Pairs run in unit order; the sweep count is bounded.
        private func separate(_ members: [Int], centre: inout [Int: CGPoint], hub: Int) {
            for _ in 0..<CanvasClusterLayout.maximumSweeps {
                var moved = false
                for first in members.indices {
                    for second in members.indices where second > first {
                        let a = members[first]
                        let b = members[second]
                        guard let pa = centre[a], let pb = centre[b] else { continue }
                        let sa = units[a].bounds.size
                        let sb = units[b].bounds.size
                        let dx = Double(pb.x - pa.x)
                        let dy = Double(pb.y - pa.y)
                        let overlapX = Double(sa.width + sb.width) / 2 + gap - abs(dx)
                        let overlapY = Double(sa.height + sb.height) / 2 + gap - abs(dy)
                        guard overlapX > 1e-6, overlapY > 1e-6 else { continue }
                        moved = true
                        var push = CGPoint.zero
                        if overlapX <= overlapY {
                            push.x = overlapX * (dx >= 0 ? 1 : -1)
                        } else {
                            push.y = overlapY * (dy >= 0 ? 1 : -1)
                        }
                        let shareA = a == hub ? 0.0 : (b == hub ? 1.0 : 0.5)
                        let shareB = 1 - shareA
                        centre[a] = CGPoint(x: pa.x - push.x * shareA, y: pa.y - push.y * shareA)
                        centre[b] = CGPoint(x: pb.x + push.x * shareB, y: pb.y + push.y * shareB)
                    }
                }
                if !moved { return }
            }
        }

        private func hasOverlap(_ members: [Int], centre: [Int: CGPoint]) -> Bool {
            for first in members.indices {
                for second in members.indices where second > first {
                    guard let pa = centre[members[first]], let pb = centre[members[second]]
                    else { continue }
                    let sa = units[members[first]].bounds.size
                    let sb = units[members[second]].bounds.size
                    let overlapX = Double(sa.width + sb.width) / 2 + gap - abs(Double(pb.x - pa.x))
                    let overlapY =
                        Double(sa.height + sb.height) / 2 + gap - abs(Double(pb.y - pa.y))
                    if overlapX > 1e-6, overlapY > 1e-6 { return true }
                }
            }
            return false
        }

        // MARK: Packing

        /// Left-to-right shelves no wider than `width` (a single wider item
        /// still gets a shelf of its own).
        private static func shelves(_ sizes: [CGSize], width: Double, gap: Double)
            -> (origins: [CGPoint], size: CGSize)
        {
            var origins: [CGPoint] = []
            var x = 0.0
            var y = 0.0
            var rowHeight = 0.0
            var maxX = 0.0
            for size in sizes {
                if x > 0, x + Double(size.width) > width {
                    x = 0
                    y += rowHeight + gap
                    rowHeight = 0
                }
                origins.append(CGPoint(x: x, y: y))
                x += Double(size.width)
                maxX = max(maxX, x)
                x += gap
                rowHeight = max(rowHeight, Double(size.height))
            }
            return (origins, CGSize(width: maxX, height: y + rowHeight))
        }

        private func place(
            _ clusters: [Cluster], derivedFrames: Set<Int>, aspect: Double, clusterGap: Double
        ) -> [CanvasCardID: CanvasRect] {
            let sizes = clusters.map(\.size)
            let area = sizes.reduce(0.0) {
                $0 + (Double($1.width) + clusterGap) * (Double($1.height) + clusterGap)
            }
            let widest = Double(sizes.map(\.width).max() ?? 0)
            let packed = Self.shelves(
                sizes, width: max(widest, (area * aspect).squareRoot()), gap: clusterGap)
            // The layout keeps the top-left of the board's current content.
            let originX = Double(ordered.map(\.rect.x).min() ?? 0)
            let originY = Double(ordered.map(\.rect.y).min() ?? 0)
            let startX = min(
                max(originX, -50_000), max(-50_000, 50_000 - Double(packed.size.width)))
            let startY = min(
                max(originY, -50_000), max(-50_000, 50_000 - Double(packed.size.height)))
            var result: [CanvasCardID: CanvasRect] = [:]
            for (slot, cluster) in clusters.enumerated() {
                for unit in cluster.units {
                    guard let local = cluster.origins[unit] else { continue }
                    let bounds = units[unit].bounds
                    let dx = (startX + Double(packed.origins[slot].x + local.x) - bounds.minX)
                        .rounded()
                    let dy = (startY + Double(packed.origins[slot].y + local.y) - bounds.minY)
                        .rounded()
                    for member in units[unit].members where !derivedFrames.contains(member) {
                        var rect = ordered[member].rect
                        rect.x = min(50_000, max(-50_000, rect.x + dx))
                        rect.y = min(50_000, max(-50_000, rect.y + dy))
                        result[ordered[member].id] = rect
                    }
                }
            }
            return result
        }
    }

    private struct DisjointSet {
        private var parent: [Int]
        private var counts: [Int]

        init(count: Int) {
            parent = Array(0..<count)
            counts = Array(repeating: 1, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            var current = value
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        mutating func size(of value: Int) -> Int { counts[find(value)] }

        /// The smaller index becomes the root, so roots are deterministic.
        mutating func union(_ a: Int, _ b: Int) {
            let first = find(a)
            let second = find(b)
            guard first != second else { return }
            let root = min(first, second)
            let child = max(first, second)
            parent[child] = root
            counts[root] += counts[child]
        }
    }
}
