import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas edge geometry")
struct CanvasEdgeGeometryTests {
    private func near(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    private func nearPoint(_ a: CGPoint, _ b: CGPoint) -> Bool {
        near(a.x, b.x) && near(a.y, b.y)
    }

    private let edgeID = UUID()

    @Test("The facing side follows the centre-to-centre angle")
    func facingSide() {
        let origin = CGPoint.zero
        #expect(CanvasEdgeGeometry.facingSide(from: origin, to: CGPoint(x: 100, y: 10)) == .right)
        #expect(CanvasEdgeGeometry.facingSide(from: origin, to: CGPoint(x: -100, y: 10)) == .left)
        #expect(CanvasEdgeGeometry.facingSide(from: origin, to: CGPoint(x: 10, y: 100)) == .bottom)
        #expect(CanvasEdgeGeometry.facingSide(from: origin, to: CGPoint(x: 10, y: -100)) == .top)
        // A tie goes to the vertical sides, and the two ends of a tie stay opposite.
        #expect(CanvasEdgeGeometry.facingSide(from: origin, to: CGPoint(x: 50, y: 50)) == .bottom)
        #expect(CanvasEdgeGeometry.facingSide(from: CGPoint(x: 50, y: 50), to: origin) == .top)
    }

    @Test("Ports sit at side midpoints and shift along the side")
    func portPoints() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        #expect(CanvasEdgeGeometry.portPoint(on: rect, side: .top) == CGPoint(x: 110, y: 20))
        #expect(CanvasEdgeGeometry.portPoint(on: rect, side: .bottom) == CGPoint(x: 110, y: 120))
        #expect(CanvasEdgeGeometry.portPoint(on: rect, side: .left) == CGPoint(x: 10, y: 70))
        #expect(CanvasEdgeGeometry.portPoint(on: rect, side: .right) == CGPoint(x: 210, y: 70))
        #expect(
            CanvasEdgeGeometry.portPoint(on: rect, side: .right, offset: 8)
                == CGPoint(x: 210, y: 78))
        #expect(
            CanvasEdgeGeometry.portPoint(on: rect, side: .top, offset: -8) == CGPoint(x: 102, y: 20)
        )
    }

    @Test("Control distance is 0.4 of the length, clamped to 24...160")
    func controlDistance() {
        #expect(near(CanvasEdgeGeometry.controlDistance(forLength: 10), 24))
        #expect(near(CanvasEdgeGeometry.controlDistance(forLength: 200), 80))
        #expect(near(CanvasEdgeGeometry.controlDistance(forLength: 1_000), 160))
    }

    @Test("A horizontal pair leaves right and enters left with perpendicular controls")
    func horizontalRoute() throws {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let rects = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 300, y: 0, width: 100, height: 100),
        ]
        let routes = CanvasEdgeGeometry.routes(
            for: [CanvasEdgeInput(id: edgeID, from: a, to: b)], rects: rects)
        let route = try #require(routes.first)
        #expect(route.fromSide == .right)
        #expect(route.toSide == .left)
        #expect(route.curve.start == CGPoint(x: 100, y: 50))
        #expect(route.curve.end == CGPoint(x: 300, y: 50))
        #expect(nearPoint(route.curve.control1, CGPoint(x: 180, y: 50)))
        #expect(nearPoint(route.curve.control2, CGPoint(x: 220, y: 50)))
        #expect(nearPoint(route.midpoint, CGPoint(x: 200, y: 50)))
    }

    @Test("A vertical pair uses the bottom and top ports")
    func verticalRoute() throws {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let rects = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 20, y: 400, width: 100, height: 100),
        ]
        let routes = CanvasEdgeGeometry.routes(
            for: [CanvasEdgeInput(id: edgeID, from: a, to: b)], rects: rects)
        let route = try #require(routes.first)
        #expect(route.fromSide == .bottom)
        #expect(route.toSide == .top)
        #expect(route.curve.start == CGPoint(x: 50, y: 100))
        #expect(route.curve.end == CGPoint(x: 70, y: 400))
        #expect(route.curve.control1.y > route.curve.start.y)
        #expect(route.curve.control2.y < route.curve.end.y)
    }

    @Test("Edges that share a side spread 8 pt apart in the order of the other ends")
    func portSpreading() throws {
        let hub = CanvasCardID()
        let upper = CanvasCardID()
        let lower = CanvasCardID()
        let rects = [
            hub: CGRect(x: 0, y: 100, width: 100, height: 100),
            upper: CGRect(x: 400, y: 0, width: 100, height: 100),
            lower: CGRect(x: 400, y: 200, width: 100, height: 100),
        ]
        let toLower = UUID()
        let toUpper = UUID()
        // Listed in the "wrong" order on purpose: the other end decides the order.
        let routes = CanvasEdgeGeometry.routes(
            for: [
                CanvasEdgeInput(id: toLower, from: hub, to: lower),
                CanvasEdgeInput(id: toUpper, from: hub, to: upper),
            ], rects: rects)
        let upperRoute = try #require(routes.first { $0.id == toUpper })
        let lowerRoute = try #require(routes.first { $0.id == toLower })
        #expect(near(upperRoute.start.y, 146))
        #expect(near(lowerRoute.start.y, 154))
        #expect(near(lowerRoute.start.y - upperRoute.start.y, CanvasEdgeGeometry.portSpacing))
    }

    @Test("Many edges on a short side compress instead of leaving the side")
    func spreadingStaysOnTheSide() {
        let hub = CanvasCardID()
        var rects = [hub: CGRect(x: 0, y: 0, width: 100, height: 40)]
        var edges: [CanvasEdgeInput] = []
        for index in 0..<10 {
            let other = CanvasCardID()
            rects[other] = CGRect(x: 500, y: Double(index) * 20, width: 100, height: 100)
            edges.append(CanvasEdgeInput(id: UUID(), from: hub, to: other))
        }
        let routes = CanvasEdgeGeometry.routes(for: edges, rects: rects)
        #expect(routes.count == 10)
        #expect(routes.allSatisfy { $0.fromSide == .right })
        for route in routes {
            #expect(route.start.y >= 8 && route.start.y <= 32)
        }
        #expect(Set(routes.map { $0.start.y }).count == 10)
    }

    @Test("A third card on the straight segment adds a 24 pt bend away from its centre")
    func thirdNodeBend() throws {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let c = CanvasCardID()
        let edge = CanvasEdgeInput(id: edgeID, from: a, to: b)
        let base: [CanvasCardID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 400, y: 0, width: 100, height: 100),
        ]
        let straight = try #require(CanvasEdgeGeometry.routes(for: [edge], rects: base).first)

        var below = base
        below[c] = CGRect(x: 200, y: 40, width: 100, height: 100)  // centre below the line
        let bentUp = try #require(CanvasEdgeGeometry.routes(for: [edge], rects: below).first)
        #expect(near(bentUp.curve.control1.y, straight.curve.control1.y - 24))
        #expect(near(bentUp.curve.control2.y, straight.curve.control2.y - 24))

        var above = base
        above[c] = CGRect(x: 200, y: -10, width: 100, height: 100)  // centre above the line
        let bentDown = try #require(CanvasEdgeGeometry.routes(for: [edge], rects: above).first)
        #expect(near(bentDown.curve.control1.y, straight.curve.control1.y + 24))

        var clear = base
        clear[c] = CGRect(x: 200, y: 200, width: 100, height: 100)
        let unchanged = try #require(CanvasEdgeGeometry.routes(for: [edge], rects: clear).first)
        #expect(unchanged == straight)
        #expect(bentUp.curve.start == straight.curve.start)
        #expect(bentUp.curve.end == straight.curve.end)
    }

    @Test("Edges with a missing card or a single card are skipped")
    func invalidEdges() {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let rects = [a: CGRect(x: 0, y: 0, width: 100, height: 100)]
        #expect(
            CanvasEdgeGeometry.routes(
                for: [
                    CanvasEdgeInput(id: UUID(), from: a, to: b),
                    CanvasEdgeInput(id: UUID(), from: a, to: a),
                ], rects: rects
            ).isEmpty)
    }

    @Test("Curve evaluation, tangent and midpoint")
    func curve() {
        let curve = CanvasEdgeCurve(
            start: CGPoint(x: 0, y: 0), control1: CGPoint(x: 0, y: 100),
            control2: CGPoint(x: 100, y: 100), end: CGPoint(x: 100, y: 0))
        #expect(curve.point(at: 0) == CGPoint(x: 0, y: 0))
        #expect(nearPoint(curve.point(at: 1), CGPoint(x: 100, y: 0)))
        #expect(nearPoint(curve.midpoint, CGPoint(x: 50, y: 75)))
        let tangent = curve.tangent(at: 0)
        #expect(near(tangent.x, 0) && tangent.y > 0)
        #expect(curve.sampled(segments: 8).count == 9)
    }

    @Test("Hit testing accepts points within 6 screen points of the curve")
    func hitTesting() throws {
        let a = CanvasCardID()
        let b = CanvasCardID()
        let rects = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 300, y: 0, width: 100, height: 100),
        ]
        let routes = CanvasEdgeGeometry.routes(
            for: [CanvasEdgeInput(id: edgeID, from: a, to: b)], rects: rects)
        let route = try #require(routes.first)
        #expect(route.curve.hit(at: CGPoint(x: 200, y: 50)))
        #expect(route.curve.hit(at: CGPoint(x: 200, y: 55.9)))
        #expect(!route.curve.hit(at: CGPoint(x: 200, y: 57)))
        #expect(CanvasEdgeGeometry.hitRoute(at: CGPoint(x: 150, y: 52), in: routes)?.id == edgeID)
        #expect(CanvasEdgeGeometry.hitRoute(at: CGPoint(x: 150, y: 90), in: routes) == nil)
    }

    @Test("Segment and rectangle intersection")
    func segmentIntersection() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(
            CanvasEdgeGeometry.segment(
                CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20), intersects: rect))
        #expect(
            !CanvasEdgeGeometry.segment(
                CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), intersects: rect))
        #expect(
            !CanvasEdgeGeometry.segment(
                CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 40), intersects: rect))
        #expect(
            CanvasEdgeGeometry.segment(
                CGPoint(x: 15, y: 15), CGPoint(x: 20, y: 20), intersects: rect))
    }

    @Test("Zoom tiers map the review thresholds")
    func zoomTiers() {
        #expect(CanvasEdgeZoomTier(scale: 2) == .full)
        #expect(CanvasEdgeZoomTier(scale: 1) == .full)
        #expect(CanvasEdgeZoomTier(scale: 0.75) == .full)
        #expect(CanvasEdgeZoomTier(scale: 0.74) == .noLabels)
        #expect(CanvasEdgeZoomTier(scale: 0.5) == .noLabels)
        #expect(CanvasEdgeZoomTier(scale: 0.49) == .glyphOnly)
        #expect(CanvasEdgeZoomTier(scale: 0.25) == .glyphOnly)
        #expect(CanvasEdgeZoomTier(scale: 0.24) == .minimal)

        #expect(CanvasEdgeZoomTier.full.showsLabels)
        #expect(!CanvasEdgeZoomTier.noLabels.showsLabels)
        #expect(CanvasEdgeZoomTier.noLabels.badgeStyle == .wordAndGlyph)
        #expect(CanvasEdgeZoomTier.glyphOnly.badgeStyle == .glyphOnly)
        #expect(CanvasEdgeZoomTier.glyphOnly.showsRelationships)
        #expect(!CanvasEdgeZoomTier.minimal.showsRelationships)
        #expect(CanvasEdgeZoomTier.minimal.badgeStyle == .hidden)
    }

    @Test("Port snapping uses the nearest side midpoint within 24 points")
    func snapping() throws {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let snapped = try #require(
            CanvasEdgeGeometry.snappedPort(on: rect, to: CGPoint(x: 215, y: 60)))
        #expect(snapped.side == .right)
        #expect(snapped.point == CGPoint(x: 200, y: 50))
        #expect(CanvasEdgeGeometry.snappedPort(on: rect, to: CGPoint(x: 260, y: 50)) == nil)
        #expect(CanvasEdgeGeometry.snappedPort(on: rect, to: CGPoint(x: 100, y: -23))?.side == .top)
        #expect(CanvasEdgeGeometry.snappedPort(on: rect, to: CGPoint(x: 100, y: -25)) == nil)
    }

    @Test("The dot eases in and out and reverses for the other direction")
    func dotTravel() {
        #expect(near(CanvasEdgeGeometry.easeInOut(0), 0))
        #expect(near(CanvasEdgeGeometry.easeInOut(0.5), 0.5))
        #expect(near(CanvasEdgeGeometry.easeInOut(1), 1))
        #expect(CanvasEdgeGeometry.easeInOut(0.25) < 0.25)
        #expect(near(CanvasEdgeGeometry.dotParameter(progress: 0, forward: true), 0))
        #expect(near(CanvasEdgeGeometry.dotParameter(progress: 0, forward: false), 1))
        #expect(near(CanvasEdgeGeometry.dotParameter(progress: 1, forward: false), 0))
    }
}
