import Foundation
import Testing

@testable import RafuCore

private typealias Spec = CanvasAgentDiagramSpec
private typealias Layout = CanvasAgentDiagramLayout

private func icon(_ id: String) -> Spec.Node {
    Spec.Node(id: id, label: id, packID: "aws", iconID: id)
}

private func centre(_ rect: CanvasAgentRect) -> (x: Double, y: Double) {
    (rect.x + rect.width / 2, rect.y + rect.height / 2)
}

private func overlaps(_ a: CanvasAgentRect, _ b: CanvasAgentRect) -> Bool {
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

/// True when the segment from `a` to `b` passes through `rect` (sampled).
private func segment(
    _ a: (x: Double, y: Double), _ b: (x: Double, y: Double), crosses rect: CanvasAgentRect
) -> Bool {
    for step in 0...200 {
        let t = Double(step) / 200
        let x = a.x + (b.x - a.x) * t
        let y = a.y + (b.y - a.y) * t
        if x > rect.x, x < rect.x + rect.width, y > rect.y, y < rect.y + rect.height {
            return true
        }
    }
    return false
}

/// The serverless image service from the user report.
private let serverless = Spec(
    nodes: ["cloudfront", "cognito", "apigw", "upload", "uploads", "thumbnail", "thumbs", "dynamo"]
        .map(icon),
    edges: [
        .init(from: "cloudfront", to: "apigw", label: "HTTPS"),
        .init(from: "cognito", to: "apigw", label: "auth"),
        .init(from: "apigw", to: "upload", label: "POST /upload"),
        .init(from: "upload", to: "uploads", label: "presigned URL"),
        .init(from: "uploads", to: "thumbnail", label: "S3 event"),
        .init(from: "thumbnail", to: "thumbs", label: "resized image"),
        .init(from: "thumbnail", to: "dynamo", label: "metadata"),
        .init(from: "cloudfront", to: "thumbs", label: "origin"),
    ],
    frame: "Serverless Image Service (AWS)")

@Test func layoutGapGrowsWithTheLongestLabel() throws {
    func gap(_ label: String?) throws -> Double {
        let spec = Spec(
            nodes: [icon("a"), icon("b")], edges: [.init(from: "a", to: "b", label: label)])
        let rects = Layout.rects(for: spec)
        let a = try #require(rects["a"])
        let b = try #require(rects["b"])
        return b.x - (a.x + a.width)
    }
    #expect(try gap(nil) == 96)
    #expect(try gap("ok") == 96)
    // 12 characters: 12 x 7.2 + 16 pill padding + 56 = 158.4, rounded.
    #expect(try gap("POST /upload") == 158)
    #expect(try gap("presigned URL") > gap("POST /upload"))
    #expect(try gap(String(repeating: "x", count: 80)) == 320)
    #expect(Layout.gapWidth(forLabelWidth: 0) == 96)
    #expect(Layout.estimatedLabelWidth("") == 0)
}

@Test func layoutKeepsTheMainChainOnOneLineWithoutOverlaps() throws {
    let rects = Layout.rects(for: serverless, originX: 40, originY: 40)
    #expect(rects.count == 8)
    let chain = ["cloudfront", "apigw", "upload", "uploads", "thumbnail", "dynamo"]
    let axis = centre(try #require(rects["cloudfront"])).y
    var previousX = -Double.infinity
    for id in chain {
        let rect = try #require(rects[id])
        #expect(centre(rect).y == axis)
        #expect(rect.x > previousX)
        previousX = rect.x
    }
    // Branches sit off the axis.
    #expect(centre(try #require(rects["cognito"])).y != axis)
    #expect(centre(try #require(rects["thumbs"])).y != axis)
    let all = Array(rects.values)
    for (index, a) in all.enumerated() {
        for b in all[(index + 1)...] { #expect(!overlaps(a, b)) }
    }
    // Rows are at least 64 pt apart.
    let cognito = try #require(rects["cognito"])
    let cloudfront = try #require(rects["cloudfront"])
    #expect(cognito.y - (cloudfront.y + cloudfront.height) >= 64)
    // The layout starts at the origin, and the whole diagram fits in one frame.
    #expect(all.map(\.x).min() == 40)
    #expect(all.map(\.y).min() == 40)
    let bounds = try #require(Layout.bounds(all))
    #expect(bounds.width < 2_000 && bounds.height < 2_000)
}

@Test func layoutMovesASkipEdgeTargetOffTheLineThroughIntermediateNodes() throws {
    let rects = Layout.rects(for: serverless)
    let source = centre(try #require(rects["cloudfront"]))
    let target = centre(try #require(rects["thumbs"]))
    // The skip edge "origin" reaches the thumbnails bucket, so the chain ends
    // at DynamoDB instead, and the bucket is not in the next row (Cognito's
    // row): from there the line from CloudFront would cross API Gateway.
    let nextRow = centre(try #require(rects["cognito"])).y - source.y
    #expect(nextRow > 0)
    #expect(target.y - source.y > nextRow)
    #expect(centre(try #require(rects["dynamo"])).y == source.y)
    // The line clears the nodes it skips after the first one.
    for id in ["upload", "uploads", "thumbnail"] {
        #expect(!segment(source, target, crosses: try #require(rects[id])))
    }
}

@Test func layoutOrdersLayersByBarycentreToAvoidCrossings() throws {
    // The spec lists the children in the opposite order of their parents.
    let spec = Spec(
        nodes: ["root", "a", "b", "main", "bChild", "aChild", "next", "end"].map(icon),
        edges: [
            .init(from: "root", to: "a"), .init(from: "root", to: "b"),
            .init(from: "root", to: "main"), .init(from: "main", to: "next"),
            .init(from: "next", to: "end"), .init(from: "a", to: "aChild"),
            .init(from: "b", to: "bChild"),
        ])
    let rects = Layout.rects(for: spec)
    func across(_ id: String) -> Double { rects[id].map { centre($0).y } ?? .nan }
    // The edges between layer 1 and layer 2.
    let pairs = [("a", "aChild"), ("b", "bChild"), ("main", "next")]
    func crossings(_ position: (String) -> Double) -> Int {
        var count = 0
        for (index, first) in pairs.enumerated() {
            for second in pairs[(index + 1)...] {
                let top = position(first.0) - position(second.0)
                let bottom = position(first.1) - position(second.1)
                if top * bottom < 0 { count += 1 }
            }
        }
        return count
    }
    #expect(crossings(across) == 0)
    // Stacking each layer in spec order (the old layout) crosses.
    let specOrder = ["a": 0.0, "b": 1, "main": 2, "bChild": 0, "aChild": 1, "next": 2]
    #expect(crossings { specOrder[$0] ?? 0 } > 0)
}

@Test func layoutIsDeterministicAndFlowsDown() throws {
    var spec = serverless
    spec.direction = "down"
    let first = Layout.rects(for: spec)
    #expect(first == Layout.rects(for: spec))
    let a = try #require(first["cloudfront"])
    let b = try #require(first["apigw"])
    #expect(b.y > a.y + a.height)
    #expect(centre(a).x == centre(b).x)
    // Layers stack vertically, so a labelled edge between them needs height only.
    #expect(b.y - (a.y + a.height) == Layout.labelledRowGap)
}

@Test func layoutShrinksGapsToFitOneFrame() throws {
    let ids = (0..<8).map { "n\($0)" }
    let edges = zip(ids, ids.dropFirst()).map {
        Spec.Edge(from: $0, to: $1, label: "a fairly long relationship label")
    }
    let rects = Layout.rects(for: Spec(nodes: ids.map(icon), edges: edges))
    let all = Array(rects.values)
    let bounds = try #require(Layout.bounds(all))
    let last = try #require(rects["n7"])
    #expect(last.x + last.width + Layout.framePadding <= bounds.x + bounds.width)
    #expect(bounds.width <= 2_000)
    // Unshrunk, each gap would be 295 pt and the frame 3,409 pt wide.
    let first = try #require(rects["n0"])
    let second = try #require(rects["n1"])
    #expect(second.x - (first.x + first.width) < 295)
    #expect(second.x - (first.x + first.width) >= Layout.compressedGap)
    for (index, a) in all.enumerated() {
        for b in all[(index + 1)...] { #expect(!overlaps(a, b)) }
    }
}

@Test func layoutBoundsUseTheFramePaddingAndTitleBand() throws {
    let bounds = try #require(
        Layout.bounds([
            CanvasAgentRect(x: 100, y: 200, width: 120, height: 100),
            CanvasAgentRect(x: 300, y: 260, width: 100, height: 80),
        ]))
    #expect(bounds == CanvasAgentRect(x: 68, y: 132, width: 364, height: 240))
    #expect(Layout.bounds([]) == nil)
    let huge = try #require(
        Layout.bounds([
            CanvasAgentRect(x: 0, y: 0, width: 100, height: 100),
            CanvasAgentRect(x: 5_000, y: 5_000, width: 100, height: 100),
        ]))
    #expect(huge.width == 2_000 && huge.height == 2_000)
}
