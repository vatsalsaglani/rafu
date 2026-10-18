import CoreGraphics
import Foundation

/// Pure edge geometry for the Canvas (review 7.5 and 7.6). Everything here works
/// in one coordinate space chosen by the caller; the edge layer passes screen
/// points so the 8 pt, 24 pt and 6 pt distances are screen distances.

nonisolated enum CanvasPortSide: Int, CaseIterable, Sendable {
    case top, right, bottom, left

    var opposite: CanvasPortSide {
        switch self {
        case .top: .bottom
        case .right: .left
        case .bottom: .top
        case .left: .right
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }

    /// Unit vector that points out of the card through this side (y grows down).
    var normal: CGPoint {
        switch self {
        case .top: CGPoint(x: 0, y: -1)
        case .right: CGPoint(x: 1, y: 0)
        case .bottom: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: -1, y: 0)
        }
    }
}

/// A cubic Bézier from one port to another.
nonisolated struct CanvasEdgeCurve: Equatable, Sendable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    func point(at t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(
            x: a * start.x + b * control1.x + c * control2.x + d * end.x,
            y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// The derivative at `t`. It is not normalized and can be zero for a degenerate curve.
    func tangent(at t: Double) -> CGPoint {
        let u = 1 - t
        let a = 3 * u * u
        let b = 6 * u * t
        let c = 3 * t * t
        return CGPoint(
            x: a * (control1.x - start.x) + b * (control2.x - control1.x)
                + c * (end.x - control2.x),
            y: a * (control1.y - start.y) + b * (control2.y - control1.y)
                + c * (end.y - control2.y))
    }

    /// Label placement point (t = 0.5).
    var midpoint: CGPoint { point(at: 0.5) }

    func sampled(segments: Int = 32) -> [CGPoint] {
        let count = max(1, segments)
        return (0...count).map { point(at: Double($0) / Double(count)) }
    }

    /// Distance from `target` to the sampled curve.
    func distance(to target: CGPoint, segments: Int = 32) -> Double {
        let points = sampled(segments: segments)
        var best = Double.infinity
        for index in 1..<points.count {
            best = min(
                best,
                CanvasEdgeGeometry.distance(from: target, toSegment: points[index - 1], points[index]))
        }
        return best
    }

    func hit(at target: CGPoint, tolerance: Double = CanvasEdgeGeometry.hitTolerance) -> Bool {
        distance(to: target) <= tolerance
    }

    /// Unit direction that points from the curve into the start port.
    var startInward: CGPoint {
        let t = tangent(at: 0)
        return CanvasEdgeGeometry.normalized(CGPoint(x: -t.x, y: -t.y)) ?? CGPoint(x: 1, y: 0)
    }

    /// Unit direction that points from the curve into the end port.
    var endInward: CGPoint {
        CanvasEdgeGeometry.normalized(tangent(at: 1)) ?? CGPoint(x: 1, y: 0)
    }
}

nonisolated struct CanvasEdgeInput: Equatable, Sendable {
    let id: UUID
    let from: CanvasCardID
    let to: CanvasCardID
}

nonisolated struct CanvasEdgeRoute: Equatable, Identifiable, Sendable {
    let id: UUID
    let fromSide: CanvasPortSide
    let toSide: CanvasPortSide
    let curve: CanvasEdgeCurve

    var start: CGPoint { curve.start }
    var end: CGPoint { curve.end }
    var midpoint: CGPoint { curve.midpoint }
}

nonisolated struct CanvasPortCandidate: Equatable, Sendable {
    let side: CanvasPortSide
    let point: CGPoint
    let distance: Double
}

/// Zoom readability tiers (review 7.6, "Readability when zoomed out").
nonisolated enum CanvasEdgeZoomTier: Equatable, Sendable {
    /// 75% and above: labels, badges and arrowheads.
    case full
    /// 50% up to 75%: relationship labels hidden, message badges keep glyph and word.
    case noLabels
    /// 25% up to 50%: badges are 16 pt glyph-only circles.
    case glyphOnly
    /// Below 25%: relationships hidden, message links without badges.
    case minimal

    enum BadgeStyle: Equatable, Sendable { case wordAndGlyph, glyphOnly, hidden }

    init(scale: Double) {
        if scale >= 0.75 {
            self = .full
        } else if scale >= 0.5 {
            self = .noLabels
        } else if scale >= 0.25 {
            self = .glyphOnly
        } else {
            self = .minimal
        }
    }

    var showsRelationships: Bool { self != .minimal }
    var showsLabels: Bool { self == .full }
    var badgeStyle: BadgeStyle {
        switch self {
        case .full, .noLabels: .wordAndGlyph
        case .glyphOnly: .glyphOnly
        case .minimal: .hidden
        }
    }
}

nonisolated enum CanvasEdgeGeometry {
    static let portSpacing = 8.0
    static let minimumControlDistance = 24.0
    static let maximumControlDistance = 160.0
    static let controlFraction = 0.4
    static let bendClearance = 24.0
    static let hitTolerance = 6.0
    static let snapRadius = 24.0

    // MARK: Vector helpers

    static func normalized(_ vector: CGPoint) -> CGPoint? {
        let length = hypot(vector.x, vector.y)
        guard length.isFinite, length > 0.000_001 else { return nil }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    // MARK: Ports

    static func center(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// The side of a card that faces `target`: compare the centre-to-centre
    /// angle, |dx| > |dy| picks left/right, otherwise top/bottom.
    static func facingSide(from origin: CGPoint, to target: CGPoint) -> CanvasPortSide {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        if abs(dx) > abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .bottom : .top
    }

    /// A port on `side`, `offset` points along the side from its midpoint
    /// (positive: down for left/right sides, right for top/bottom sides).
    static func portPoint(on rect: CGRect, side: CanvasPortSide, offset: Double = 0) -> CGPoint {
        switch side {
        case .top: CGPoint(x: rect.midX + offset, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX + offset, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY + offset)
        case .right: CGPoint(x: rect.maxX, y: rect.midY + offset)
        }
    }

    /// The side midpoint nearest to `point`.
    static func nearestPort(on rect: CGRect, to point: CGPoint) -> CanvasPortCandidate {
        var best: CanvasPortCandidate?
        for side in CanvasPortSide.allCases {
            let port = portPoint(on: rect, side: side)
            let candidate = CanvasPortCandidate(
                side: side, point: port, distance: hypot(port.x - point.x, port.y - point.y))
            if best == nil || candidate.distance < (best?.distance ?? .infinity) {
                best = candidate
            }
        }
        return best ?? CanvasPortCandidate(side: .right, point: center(of: rect), distance: 0)
    }

    /// The nearest side midpoint when it lies within `radius` of `point`.
    static func snappedPort(
        on rect: CGRect, to point: CGPoint, radius: Double = snapRadius
    ) -> CanvasPortCandidate? {
        let candidate = nearestPort(on: rect, to: point)
        return candidate.distance <= radius ? candidate : nil
    }

    static func controlDistance(forLength length: Double) -> Double {
        min(maximumControlDistance, max(minimumControlDistance, controlFraction * length))
    }

    // MARK: Routing

    private struct PortKey: Hashable {
        let card: CanvasCardID
        let side: CanvasPortSide
    }

    private struct AnchorKey: Hashable {
        let edge: UUID
        let isFrom: Bool
    }

    private struct PortUse {
        let anchor: AnchorKey
        let other: CGPoint
        let tie: String
    }

    /// Routes every edge whose two cards are in `rects`. Edges that share a
    /// side spread 8 pt apart, ordered by the other end's position, so they do
    /// not cross at the port.
    static func routes(
        for edges: [CanvasEdgeInput], rects: [CanvasCardID: CGRect]
    ) -> [CanvasEdgeRoute] {
        struct Resolved {
            let edge: CanvasEdgeInput
            let fromRect: CGRect
            let toRect: CGRect
            let fromSide: CanvasPortSide
            let toSide: CanvasPortSide
        }
        var resolved: [Resolved] = []
        for edge in edges where edge.from != edge.to {
            guard let fromRect = rects[edge.from], let toRect = rects[edge.to] else { continue }
            let fromCenter = center(of: fromRect)
            let toCenter = center(of: toRect)
            resolved.append(
                Resolved(
                    edge: edge, fromRect: fromRect, toRect: toRect,
                    fromSide: facingSide(from: fromCenter, to: toCenter),
                    toSide: facingSide(from: toCenter, to: fromCenter)))
        }

        var uses: [PortKey: [PortUse]] = [:]
        for item in resolved {
            let fromKey = PortKey(card: item.edge.from, side: item.fromSide)
            uses[fromKey, default: []].append(
                PortUse(
                    anchor: AnchorKey(edge: item.edge.id, isFrom: true),
                    other: center(of: item.toRect), tie: item.edge.id.uuidString))
            let toKey = PortKey(card: item.edge.to, side: item.toSide)
            uses[toKey, default: []].append(
                PortUse(
                    anchor: AnchorKey(edge: item.edge.id, isFrom: false),
                    other: center(of: item.fromRect), tie: item.edge.id.uuidString))
        }

        var anchors: [AnchorKey: CGPoint] = [:]
        for (key, group) in uses {
            guard let rect = rects[key.card] else { continue }
            let ordered = group.sorted { lhs, rhs in
                let l = key.side.isHorizontal ? (lhs.other.y, lhs.other.x) : (lhs.other.x, lhs.other.y)
                let r = key.side.isHorizontal ? (rhs.other.y, rhs.other.x) : (rhs.other.x, rhs.other.y)
                if l.0 != r.0 { return l.0 < r.0 }
                if l.1 != r.1 { return l.1 < r.1 }
                if lhs.tie != rhs.tie { return lhs.tie < rhs.tie }
                return !lhs.anchor.isFrom && rhs.anchor.isFrom
            }
            let length = key.side.isHorizontal ? rect.height : rect.width
            let room = max(0, length / 2 - portSpacing)
            let step =
                ordered.count > 1 ? min(portSpacing, 2 * room / Double(ordered.count - 1)) : 0
            for (index, use) in ordered.enumerated() {
                let offset = (Double(index) - Double(ordered.count - 1) / 2) * step
                anchors[use.anchor] = portPoint(on: rect, side: key.side, offset: offset)
            }
        }

        var routes: [CanvasEdgeRoute] = []
        for item in resolved {
            guard let start = anchors[AnchorKey(edge: item.edge.id, isFrom: true)],
                let end = anchors[AnchorKey(edge: item.edge.id, isFrom: false)]
            else { continue }
            let length = hypot(end.x - start.x, end.y - start.y)
            let reach = controlDistance(forLength: length)
            let startNormal = item.fromSide.normal
            let endNormal = item.toSide.normal
            var control1 = CGPoint(
                x: start.x + startNormal.x * reach, y: start.y + startNormal.y * reach)
            var control2 = CGPoint(x: end.x + endNormal.x * reach, y: end.y + endNormal.y * reach)
            let others = rects.filter { $0.key != item.edge.from && $0.key != item.edge.to }
            if let bend = bendVector(from: start, to: end, avoiding: others) {
                control1 = CGPoint(x: control1.x + bend.x, y: control1.y + bend.y)
                control2 = CGPoint(x: control2.x + bend.x, y: control2.y + bend.y)
            }
            routes.append(
                CanvasEdgeRoute(
                    id: item.edge.id, fromSide: item.fromSide, toSide: item.toSide,
                    curve: CanvasEdgeCurve(
                        start: start, control1: control1, control2: control2, end: end)))
        }
        return routes
    }

    /// One pass, no path finding: when the straight segment crosses a third
    /// card, bend 24 pt away from that card's centre.
    static func bendVector(
        from start: CGPoint, to end: CGPoint, avoiding others: [CanvasCardID: CGRect]
    ) -> CGPoint? {
        let crossed = others.filter { segment(start, end, intersects: $0.value) }
        guard !crossed.isEmpty,
            let direction = normalized(CGPoint(x: end.x - start.x, y: end.y - start.y))
        else { return nil }
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let nearest = crossed.min { lhs, rhs in
            let l = hypot(center(of: lhs.value).x - middle.x, center(of: lhs.value).y - middle.y)
            let r = hypot(center(of: rhs.value).x - middle.x, center(of: rhs.value).y - middle.y)
            if l != r { return l < r }
            return lhs.key.rawValue.uuidString < rhs.key.rawValue.uuidString
        }
        guard let node = nearest else { return nil }
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        let away = CGPoint(
            x: middle.x - center(of: node.value).x, y: middle.y - center(of: node.value).y)
        let sign: Double = (away.x * perpendicular.x + away.y * perpendicular.y) >= 0 ? 1 : -1
        return CGPoint(
            x: perpendicular.x * sign * bendClearance, y: perpendicular.y * sign * bendClearance)
    }

    /// Liang–Barsky clip of the segment against `rect`.
    static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        let dx = b.x - a.x
        let dy = b.y - a.y
        var t0 = 0.0
        var t1 = 1.0
        let checks: [(Double, Double)] = [
            (-dx, a.x - rect.minX), (dx, rect.maxX - a.x),
            (-dy, a.y - rect.minY), (dy, rect.maxY - a.y),
        ]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let r = q / p
                if p < 0 {
                    if r > t1 { return false }
                    t0 = max(t0, r)
                } else {
                    if r < t0 { return false }
                    t1 = min(t1, r)
                }
            }
        }
        return t0 <= t1
    }

    // MARK: Hit testing

    /// The topmost route within `tolerance` of `point` (nearest wins).
    static func hitRoute(
        at point: CGPoint, in routes: [CanvasEdgeRoute], tolerance: Double = hitTolerance
    ) -> CanvasEdgeRoute? {
        var best: (route: CanvasEdgeRoute, distance: Double)?
        for route in routes {
            let distance = route.curve.distance(to: point)
            guard distance <= tolerance else { continue }
            if best == nil || distance < (best?.distance ?? .infinity) {
                best = (route, distance)
            }
        }
        return best?.route
    }

    // MARK: Timing curves
    // Close approximations of the SwiftUI curves named in RafuMotion, used where
    // a pure time-to-progress function drives a travelling dot.

    static func easeInOut(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }

    /// Position along the curve for a message that has run `progress` of its travel.
    static func dotParameter(progress: Double, forward: Bool) -> Double {
        let eased = easeInOut(progress)
        return forward ? eased : 1 - eased
    }
}
