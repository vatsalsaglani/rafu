import Foundation
import Testing

@testable import RafuApp

@MainActor
@Suite("Canvas connection dragging")
struct CanvasConnectionDragTests {
    @Test("Drop hit testing applies both pan and zoom")
    func transformedDrop() throws {
        let source = card("Source", x: 20, y: 40)
        let target = card("Target", x: 500, y: 100)
        for scale in [0.25, 0.5, 1.0, 2.0] {
            let viewport = CanvasViewport(scale: scale, x: -180, y: 230)
            let point = CGPoint(x: 620 * scale + viewport.x, y: 170 * scale + viewport.y)
            var drag = CanvasConnectionDrag()
            drag.update(from: source.id, at: point)
            #expect(drag.target(in: [source, target], viewport: viewport) == target.id)
            #expect(
                drag.start(in: [source, target], viewport: viewport)
                    == CGPoint(
                        x: 260 * scale + viewport.x, y: 120 * scale + viewport.y))
            #expect(
                drag.finish(
                    from: source.id, at: point, cards: [source, target], viewport: viewport)
                    == CanvasConnectionDrop(from: source.id, to: target.id))
            #expect(drag.source == nil)
        }
    }

    @Test("Self, background, missing-source, and cancelled drops create no connection")
    func invalidDrops() {
        let source = card("Source", x: 20, y: 40)
        let target = card("Target", x: 500, y: 100)
        let cards = [source, target]
        for point in [CGPoint(x: 50, y: 60), CGPoint(x: 900, y: 900)] {
            var drag = CanvasConnectionDrag()
            drag.update(from: source.id, at: point)
            #expect(drag.finish(from: source.id, at: point, cards: cards, viewport: .init()) == nil)
        }
        var drag = CanvasConnectionDrag()
        let point = CGPoint(x: 600, y: 160)
        drag.update(from: source.id, at: point)
        drag.cancel()
        drag.update(from: source.id, at: point)
        #expect(drag.start(in: cards, viewport: .init()) == nil)
        #expect(drag.finish(from: source.id, at: point, cards: cards, viewport: .init()) == nil)
        drag.update(from: source.id, at: point)
        #expect(drag.finish(from: source.id, at: point, cards: [target], viewport: .init()) == nil)
        drag.update(from: source.id, at: point)
        drag.reset()
        #expect(drag.finish(from: source.id, at: point, cards: cards, viewport: .init()) == nil)
    }

    @Test("The front card wins and a self-drop does not connect through it")
    func overlapOrder() {
        let source = card("Source", x: 20, y: 40)
        let behind = card("Behind", x: 500, y: 100)
        let front = card("Front", x: 500, y: 100)
        let point = CGPoint(x: 600, y: 160)
        var drag = CanvasConnectionDrag()
        drag.update(from: source.id, at: point)
        #expect(drag.target(in: [source, behind, front], viewport: .init()) == front.id)
        drag.reset()
        drag.update(from: front.id, at: point)
        #expect(drag.target(in: [source, behind, front], viewport: .init()) == nil)
    }

    @Test("Preview and cancellation leave document layout and undo unchanged")
    func previewDoesNotEdit() {
        let source = card("Source", x: 20, y: 40)
        let target = card("Target", x: 500, y: 100)
        var document = CanvasDocument(title: "Connections")
        document.cards = [source, target]
        let board = CanvasBoardState(document: document)
        var drag = CanvasConnectionDrag()
        drag.update(from: source.id, at: CGPoint(x: 600, y: 160))
        #expect(drag.target(in: board.cards, viewport: board.viewport) == target.id)
        drag.cancel()
        drag.reset()
        #expect(board.connections.isEmpty)
        #expect(board.cards == document.cards)
        #expect(board.changeStamp == 0)
        #expect(!board.canUndo)
    }

    @Test("A valid drop uses the shared connection action for terminal and ordinary cards")
    func connectionKinds() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WorkspaceSession(
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: folder)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Connections"))
        let source = CanvasCard(
            title: "Claude", rect: .init(x: 20, y: 40, width: 240, height: 160),
            content: .terminal(groupID: TerminalGroupID()))
        let target = CanvasCard(
            title: "Codex", rect: .init(x: 500, y: 100, width: 240, height: 160),
            content: .terminal(groupID: TerminalGroupID()))
        let note = card("Note", x: 900, y: 100)
        try board.edit { $0.cards = [source, target, note] }
        for (destination, point, kind) in [
            (target.id, CGPoint(x: 600, y: 160), CanvasConnectionBehavior.session),
            (note.id, CGPoint(x: 1000, y: 160), CanvasConnectionBehavior.related),
        ] {
            var drag = CanvasConnectionDrag()
            drag.update(from: source.id, at: point)
            let result = drag.finish(
                from: source.id, at: point, cards: board.cards, viewport: board.viewport)
            let drop = try #require(result)
            #expect(drop.to == destination)
            session.connectCanvasCards(boardID: board.id, from: drop.from, to: drop.to)
            #expect(board.connections.last?.behavior == kind)
        }
        #expect(board.connections.count == 2)
        #expect(session.terminal.sessions.isEmpty)
        #expect(await session.canvas.flushAll())
    }

    private func card(_ name: String, x: Double, y: Double) -> CanvasCard {
        CanvasCard(
            title: name, rect: .init(x: x, y: y, width: 240, height: 160),
            content: .note(snapshot: ""))
    }
}
