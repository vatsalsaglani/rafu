import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// Edges draw below every card, the hovered and selected edge included. A
/// hovered edge used to be redrawn by `CanvasEdgeOverlay` above all cards, so
/// a pointer resting on an edge's visible part painted the whole edge over
/// every card between its ends.
@Suite("Canvas edge layering")
@MainActor
struct CanvasEdgeLayeringTests {
    private func display(_ id: UUID = UUID(), message: Bool = false) -> CanvasEdgeDisplay {
        let curve = CanvasEdgeCurve(
            start: .zero, control1: CGPoint(x: 40, y: 0), control2: CGPoint(x: 60, y: 100),
            end: CGPoint(x: 100, y: 100))
        return CanvasEdgeDisplay(
            connection: CanvasConnection(
                id: id, from: CanvasCardID(), to: CanvasCardID(),
                behavior: message ? .session : .related),
            route: CanvasEdgeRoute(id: id, fromSide: .right, toSide: .left, curve: curve),
            state: message ? .paused : nil, fromTitle: "A", toTitle: "B",
            label: CanvasEdgeLabelPlacement(center: CGPoint(x: 50, y: 50), maximumWidth: 160))
    }

    private func card(_ title: String, _ x: Double, _ y: Double) -> CanvasCard {
        CanvasCard(
            title: title, rect: CanvasRect(x: x, y: y, width: 200, height: 100),
            content: .file(path: "\(title).swift"))
    }

    // MARK: Draw order inside the layer

    @Test("Emphasis only reorders edges inside the layer: hovered, then selected, last")
    func emphasizedEdgesDrawLastInsideTheLayer() {
        let edges = (0..<4).map { _ in display() }
        let ids = edges.map(\.id)
        #expect(
            CanvasEdgeLayering.drawOrder(edges, selected: nil, hovered: nil).map(\.id) == ids)
        #expect(
            CanvasEdgeLayering.drawOrder(edges, selected: nil, hovered: ids[1]).map(\.id)
                == [ids[0], ids[2], ids[3], ids[1]])
        #expect(
            CanvasEdgeLayering.drawOrder(edges, selected: ids[0], hovered: ids[2]).map(\.id)
                == [ids[1], ids[3], ids[2], ids[0]])
        // One edge both hovered and selected appears once.
        #expect(
            CanvasEdgeLayering.drawOrder(edges, selected: ids[3], hovered: ids[3]).map(\.id)
                == ids)
        // An id that is not displayed changes nothing.
        #expect(
            CanvasEdgeLayering.drawOrder(edges, selected: UUID(), hovered: UUID()).map(\.id)
                == ids)
    }

    // MARK: End handles under a covering card

    @Test("A port under a third card is covered; a port on its own card's border is not")
    func coveredPorts() {
        let from = card("from", 0, 0)
        let middle = card("middle", 150, 50)
        let to = card("to", 400, 0)
        let cards = [from, middle, to]
        let viewport = CanvasViewport()
        let ends: Set<CanvasCardID> = [from.id, to.id]
        // The bottom-right of `from` lies inside `middle`.
        #expect(
            CanvasEdgeLayering.isCovered(
                CGPoint(x: 180, y: 90), cards: cards, live: [:], viewport: viewport,
                excluding: ends))
        // The left-middle port of `to` is on its own border, clear of others.
        #expect(
            !CanvasEdgeLayering.isCovered(
                CGPoint(x: 400, y: 50), cards: cards, live: [:], viewport: viewport,
                excluding: ends))
        // A point exactly on `middle`'s border is still visible.
        #expect(
            !CanvasEdgeLayering.isCovered(
                CGPoint(x: 150, y: 90), cards: cards, live: [:], viewport: viewport,
                excluding: ends))
        // The edge's own end cards never cover its handles.
        #expect(
            !CanvasEdgeLayering.isCovered(
                CGPoint(x: 100, y: 50), cards: cards, live: [:], viewport: viewport,
                excluding: ends))
    }

    @Test("Coverage follows the zoomed viewport and live drag rects")
    func coverageUsesShownGeometry() {
        let from = card("from", 0, 0)
        let middle = card("middle", 1_000, 1_000)
        let to = card("to", 400, 0)
        let cards = [from, middle, to]
        let ends: Set<CanvasCardID> = [from.id, to.id]
        let point = CGPoint(x: 260, y: 30)
        #expect(
            !CanvasEdgeLayering.isCovered(
                point, cards: cards, live: [:], viewport: CanvasViewport(), excluding: ends))
        // Mid-drag, `middle` shows over the point before anything is stored.
        let live = [middle.id: CanvasRect(x: 250, y: 0, width: 200, height: 100)]
        #expect(
            CanvasEdgeLayering.isCovered(
                point, cards: cards, live: live, viewport: CanvasViewport(), excluding: ends))
        // At 50% zoom, board (520, 60) shows at (260, 30): a card at board
        // x 500 covers it only through the scale.
        let zoomed = CanvasViewport(scale: 0.5)
        let shifted = [middle.id: CanvasRect(x: 500, y: 0, width: 200, height: 100)]
        #expect(
            !CanvasEdgeLayering.isCovered(
                point, cards: cards, live: shifted, viewport: CanvasViewport(), excluding: ends))
        #expect(
            CanvasEdgeLayering.isCovered(
                point, cards: cards, live: shifted, viewport: zoomed, excluding: ends))
    }

    @Test("A frame does not cover the edges inside it")
    func framesDoNotCover() throws {
        let a = card("a", 0, 0)
        let b = card("b", 400, 0)
        var document = CanvasDocument(title: "Frames")
        document.cards = [a, b]
        let board = CanvasBoardState(document: document)
        let frame = try #require(try board.createFrame(title: "Group", memberIDs: [a.id, b.id]))
        let frameRect = try #require(board.cards.first { $0.id == frame }?.rect)
        let inside = CGPoint(x: frameRect.x + frameRect.width / 2, y: frameRect.y + 4)
        #expect(
            !CanvasEdgeLayering.isCovered(
                inside, cards: board.cards, live: [:], viewport: CanvasViewport(),
                excluding: [a.id, b.id]))
    }

    // MARK: Undo of raise plus drag restores the z-order

    @Test("Undo of each raise-and-drag restores the exact stacking order and rects")
    func undoRestoresZOrder() throws {
        // The board of the report: a terminal group above a shell, a file
        // card at the end of a link from the shell.
        var document = CanvasDocument(title: "Layering")
        let shell = card("Default shell", 400, 0)
        let group = card("Terminal Group 1", 300, 150)
        let html = card("out.html", 0, 100)
        let one = card("one", 100, 500)
        let docker = card(".dockerignore", 700, 500)
        document.cards = [html, shell, group, one, docker]
        document.connections = [CanvasConnection(from: shell.id, to: docker.id)]
        let board = CanvasBoardState(document: document)
        let original = board.cards

        func drag(_ id: CanvasCardID, dx: Double, dy: Double) throws {
            board.raiseDuringGesture([id])
            board.beginGesture()
            var rect = try #require(board.cards.first { $0.id == id }?.rect)
            rect.x += dx
            rect.y += dy
            board.showLiveRects([id: rect])
            board.commitLiveRects([id: rect])
            board.endGesture()
        }

        try drag(group.id, dx: 80, dy: 53)
        #expect(board.cards.last?.id == group.id)
        board.performUndo()
        #expect(board.cards == original)

        try drag(docker.id, dx: -40, dy: 16)
        try drag(docker.id, dx: 24, dy: -8)
        board.performUndo()
        board.performUndo()
        #expect(board.cards == original)
        #expect(board.connections == document.connections)
        #expect(!board.canUndo)
        #expect(board.liveGeometry.rects.isEmpty)

        // Redo brings the raise back with the move, as one step.
        board.performRedo()
        #expect(board.cards.last?.id == docker.id)
        #expect(board.cards.map(\.id) == [html, shell, group, one, docker].map(\.id))
        board.performUndo()
        #expect(board.cards == original)
    }

    @Test("A raise that moves a buried card is undone with its move, not left behind")
    func undoRestoresBuriedCardOrder() throws {
        var document = CanvasDocument(title: "Buried")
        document.cards = (0..<4).map { card("card-\($0)", Double($0) * 50, 0) }
        let board = CanvasBoardState(document: document)
        let original = board.cards
        let buried = original[1].id

        board.raiseDuringGesture([buried])
        board.beginGesture()
        var rect = original[1].rect
        rect.y = 300
        board.showLiveRects([buried: rect])
        board.commitLiveRects([buried: rect])
        board.endGesture()
        #expect(
            board.cards.map(\.id) == [original[0], original[2], original[3], original[1]].map(\.id))

        board.performUndo()
        #expect(board.cards.map(\.id) == original.map(\.id))
        #expect(board.cards == original)
    }

    // MARK: Layer contract

    @Test("Cards draw above the whole edge layer; the overlay draws no edge")
    func layerContract() throws {
        let board = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        let start = try #require(board.range(of: "private func boardLayers("))
        let layers = String(board[start.upperBound...])
        let edges = try #require(layers.range(of: "CanvasEdgeLayer("))
        let cards = try #require(layers.range(of: "ForEach(visibleCards(in: geometry.size))"))
        let overlay = try #require(layers.range(of: "CanvasEdgeOverlay("))
        #expect(edges.lowerBound < cards.lowerBound)
        #expect(cards.lowerBound < overlay.lowerBound)

        let overlaySource = try Self.source(
            "Sources/RafuApp/Canvas/Views/CanvasEdgeOverlay.swift")
        // No stroke, halo or arrowhead of an existing edge above the cards.
        #expect(!overlaySource.contains("CanvasEdgeCurveShape(curve: display.route.curve)"))
        #expect(!overlaySource.contains("CanvasArrowDrawing.draw"))
        #expect(!overlaySource.contains("lineWidth: 6"))
        // End handles hide where another card covers the port.
        #expect(overlaySource.contains("CanvasEdgeLayering.isCovered("))

        let layerSource = try Self.source("Sources/RafuApp/Canvas/Views/CanvasEdgeLayer.swift")
        #expect(layerSource.contains("CanvasArrowDrawing.draw"))
        #expect(layerSource.contains("lineWidth: 6"))
        #expect(layerSource.contains("CanvasEdgeLayering.drawOrder("))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
