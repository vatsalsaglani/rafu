import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas whiteboard kinds and compatibility")
struct CanvasWhiteboardTests {
    /// A board exactly as the pre-whiteboard Rafu wrote it (sorted keys), with
    /// one card of every original kind and one link.
    static let legacyBoard = #"""
        {"cards":[{"content":{"note":{"snapshot":"- [ ] ship"}},"id":{"rawValue":"00000000-0000-0000-0000-000000000001"},"rect":{"height":260,"width":380,"x":40,"y":40},"title":"Note"},{"content":{"file":{"path":"README.md"}},"id":{"rawValue":"00000000-0000-0000-0000-000000000002"},"rect":{"height":260,"width":380,"x":40,"y":40},"title":"Readme"},{"content":{"image":{"path":"docs\/shot.png"}},"id":{"rawValue":"00000000-0000-0000-0000-000000000003"},"rect":{"height":260,"width":380,"x":40,"y":40},"title":"Shot"},{"content":{"terminal":{"groupID":{"rawValue":"22222222-2222-2222-2222-222222222222"}}},"id":{"rawValue":"00000000-0000-0000-0000-000000000004"},"rect":{"height":260,"width":380,"x":40,"y":40},"title":"Shell"},{"content":{"web":{"destination":{"address":"http:\/\/localhost:3000\/"}}},"id":{"rawValue":"00000000-0000-0000-0000-000000000005"},"rect":{"height":260,"width":380,"x":40,"y":40},"title":"App"},{"content":{"nativeApp":{"bundleID":"com.apple.finder"}},"id":{"rawValue":"00000000-0000-0000-0000-000000000006"},"rect":{"height":260,"width":380,"x":40,"y":40},"title":"Finder"}],"connections":[{"behavior":"related","from":{"rawValue":"00000000-0000-0000-0000-000000000001"},"id":"33333333-3333-3333-3333-333333333333","label":"Related to","to":{"rawValue":"00000000-0000-0000-0000-000000000002"}}],"id":{"rawValue":"11111111-1111-1111-1111-111111111111"},"revision":3,"title":"Old board","version":1,"viewport":{"scale":1,"x":0,"y":0}}
        """#

    @Test("A board saved before the whiteboard kinds loads and re-encodes unchanged")
    func legacyBoardCompatibility() throws {
        let data = Data(Self.legacyBoard.utf8)
        let document = try JSONDecoder().decode(CanvasDocument.self, from: data)
        #expect(document.title == "Old board")
        #expect(document.revision == 3)
        #expect(
            document.cards.map(\.content.kindName) == [
                "Note", "File", "Image", "Terminal", "Local Web App", "Native App",
            ])
        #expect(document.cards[0].content == .note(snapshot: "- [ ] ship"))
        #expect(document.cards[2].content == .image(path: "docs/shot.png"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = try encoder.encode(document)
        let before = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let after = try #require(JSONSerialization.jsonObject(with: reencoded) as? NSDictionary)
        #expect(before == after)
    }

    @Test("Every new kind round-trips through a saved board")
    func newKindsRoundTrip() throws {
        var document = CanvasDocument(title: "Whiteboard")
        document.cards = [
            CanvasCard(title: "Diagram", content: .mermaid(source: "flowchart LR\n  A --> B")),
            CanvasCard(
                title: "Box",
                content: .shape(
                    CanvasShape(
                        kind: .diamond, stroke: .info, fill: .tint, weight: .bold, dashed: true,
                        label: "Decide"))),
            CanvasCard(
                title: "Arrow",
                content: .stroke(
                    CanvasStroke(
                        kind: .arrow,
                        points: [
                            CanvasUnitPoint(x: 0.1, y: 0.2), CanvasUnitPoint(x: 0.9, y: 0.8),
                        ]))),
            CanvasCard(
                title: "Words",
                content: .text(CanvasText(text: "**Bold** idea", size: .large, ink: .danger))),
        ]
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: data)
        #expect(decoded == document)
        if case .stroke(let stroke) = decoded.cards[2].content {
            #expect(stroke.endArrowhead == .arrow)
            #expect(stroke.startArrowhead == .none)
        } else {
            Issue.record("The arrow card lost its kind")
        }
    }

    @Test("Unit points quantize, clamp, and survive encoding exactly")
    func unitPoints() throws {
        let point = CanvasUnitPoint(x: 0.123_456_7, y: 1.7)
        #expect(point.x == 0.1235)
        #expect(point.y == 1)
        let data = try JSONEncoder().encode([point])
        #expect(String(decoding: data, as: UTF8.self) == "[[1235,10000]]")
        #expect(try JSONDecoder().decode([CanvasUnitPoint].self, from: data) == [point])
        #expect(throws: CanvasError.invalidDocument) {
            try JSONDecoder().decode(CanvasUnitPoint.self, from: Data("[1,20000]".utf8))
        }
        #expect(throws: CanvasError.invalidDocument) {
            try JSONDecoder().decode(CanvasUnitPoint.self, from: Data("[1,2,3]".utf8))
        }
    }

    @Test("Unknown style names fall back to defaults so newer boards still open")
    func lenientStyles() throws {
        let json = #"{"kind":"ellipse","stroke":"chartreuse","fill":"hatched","weight":"heavy"}"#
        let shape = try JSONDecoder().decode(CanvasShape.self, from: Data(json.utf8))
        #expect(shape == CanvasShape(kind: .ellipse))
        let text = try JSONDecoder().decode(
            CanvasText.self, from: Data(#"{"text":"Hi","size":"huge"}"#.utf8))
        #expect(text == CanvasText(text: "Hi"))
    }

    @Test("Whiteboard content stays within its limits")
    func contentLimits() throws {
        let long = String(repeating: "a", count: CanvasLimits.mermaidSourceBytes + 1)
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasCardContent.mermaid(source: long).validate()
        }
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasCardContent.mermaid(source: "  \n").validate()
        }
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasCardContent.text(
                CanvasText(
                    text: String(repeating: "b", count: CanvasLimits.whiteboardTextBytes + 1))
            ).validate()
        }
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasCardContent.shape(CanvasShape(kind: .rectangle, label: "a\0b")).validate()
        }
        let one = [CanvasUnitPoint(x: 0, y: 0)]
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasCardContent.stroke(CanvasStroke(kind: .freehand, points: one)).validate()
        }
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasCardContent.stroke(CanvasStroke(kind: .line, points: one + one + one))
                .validate()
        }
        let tooMany = (0...CanvasLimits.strokePoints).map { _ in [0, 0] }
        let json = try JSONSerialization.data(
            withJSONObject: ["kind": "freehand", "points": tooMany])
        #expect(throws: CanvasError.invalidDocument) {
            try JSONDecoder().decode(CanvasStroke.self, from: json)
        }
    }

    @Test("Simplification keeps the ends and drops collinear samples")
    func simplification() {
        let line = (0...100).map { CGPoint(x: Double($0), y: Double($0) * 0.5) }
        let simplified = CanvasWhiteboardGeometry.simplify(line, tolerance: 0.5)
        #expect(simplified == [line[0], line[100]])
        let corner = [
            CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0.1), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 100),
        ]
        #expect(
            CanvasWhiteboardGeometry.simplify(corner, tolerance: 1) == [
                corner[0], corner[2], corner[4],
            ])
    }

    @Test("A long, noisy stroke is bounded to the point limit")
    func boundedStroke() {
        let noisy = (0..<6_000).map { index in
            CGPoint(x: Double(index), y: index.isMultiple(of: 2) ? 0 : 40)
        }
        let bounded = CanvasWhiteboardGeometry.bounded(noisy)
        #expect(bounded.count <= CanvasLimits.strokePoints)
        #expect(bounded.first == noisy.first)
        #expect(bounded.last == noisy.last)
    }

    @Test("A stroke card fits its points, pads to the minimum, and stays valid")
    func strokeCard() throws {
        let samples = [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 100)]
        let made = try #require(
            CanvasWhiteboardGeometry.strokeCard(
                kind: .line, samples: samples, style: CanvasStroke(kind: .line, points: [])))
        #expect(made.rect.isValid)
        #expect(made.rect.width == CanvasRect.absoluteMinimumWidth)
        #expect(made.rect.height == CanvasRect.absoluteMinimumHeight)
        try CanvasCardContent.stroke(made.stroke).validate()
        let start = try #require(made.stroke.start)
        let end = try #require(made.stroke.end)
        #expect(abs((made.rect.x + start.x * made.rect.width) - 100) < 0.5)
        #expect(abs((made.rect.x + end.x * made.rect.width) - 140) < 0.5)
        #expect(abs((made.rect.y + start.y * made.rect.height) - 100) < 0.5)
    }

    @Test("A click makes a default line, and a still freehand stroke makes nothing")
    func strokeEdgeCases() throws {
        let click = [CGPoint(x: 10, y: 10)]
        let line = try #require(
            CanvasWhiteboardGeometry.strokeCard(
                kind: .arrow, samples: click, style: CanvasStroke(kind: .arrow, points: [])))
        #expect(line.stroke.points.count == 2)
        #expect(line.rect.width >= CanvasWhiteboardGeometry.defaultLineLength)
        #expect(
            CanvasWhiteboardGeometry.strokeCard(
                kind: .freehand, samples: click + click,
                style: CanvasStroke(kind: .freehand, points: [])) == nil)
    }

    @Test("A huge drawing scales down uniformly into the largest card")
    func hugeStroke() throws {
        let samples = (0...200).map { CGPoint(x: Double($0) * 40, y: Double($0 % 2) * 4_000) }
        let made = try #require(
            CanvasWhiteboardGeometry.strokeCard(
                kind: .freehand, samples: samples,
                style: CanvasStroke(kind: .freehand, points: [])))
        #expect(made.rect.isValid)
        #expect(made.rect.width <= CanvasWhiteboardGeometry.maximumSide)
        try CanvasCardContent.stroke(made.stroke).validate()
    }

    @Test("Shape rects normalize drags, force squares, and default on click")
    func shapeRects() {
        let drag = CanvasWhiteboardGeometry.shapeRect(
            from: CGPoint(x: 300, y: 300), to: CGPoint(x: 100, y: 150), square: false)
        #expect(drag == CanvasRect(x: 100, y: 150, width: 200, height: 150))
        let square = CanvasWhiteboardGeometry.shapeRect(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 120), square: true)
        #expect(square.width == 200 && square.height == 200)
        let click = CanvasWhiteboardGeometry.shapeRect(
            from: CGPoint(x: 500, y: 500), to: CGPoint(x: 502, y: 501), square: false)
        #expect(click == CanvasRect(x: 420, y: 450, width: 160, height: 100))
        let tiny = CanvasWhiteboardGeometry.shapeRect(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 30), square: false)
        #expect(tiny.isValid)
        let huge = CanvasWhiteboardGeometry.shapeRect(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 9_000, y: 9_000), square: false)
        #expect(huge.isValid)
    }

    @Test("Text cards size to their text within the card bounds")
    func textSize() {
        let short = CanvasWhiteboardGeometry.textCardSize(for: "Hi", size: .medium)
        let long = CanvasWhiteboardGeometry.textCardSize(
            for: String(repeating: "word ", count: 200), size: .medium)
        #expect(short.0 == 280)
        #expect(short.1 >= CanvasRect.absoluteMinimumHeight)
        #expect(long.1 > short.1)
        #expect(long.1 <= CanvasWhiteboardGeometry.maximumSide)
    }
}
