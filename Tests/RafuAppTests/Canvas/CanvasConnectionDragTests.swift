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

    @Test("The preview starts at the source port that faces the target")
    func facingPort() throws {
        let source = card("Source", x: 400, y: 400)
        let above = card("Above", x: 400, y: 0)
        let left = card("Left", x: 0, y: 400)
        for (target, side, point) in [
            (above, CanvasPortSide.top, CGPoint(x: 520, y: 400)),
            (left, CanvasPortSide.left, CGPoint(x: 400, y: 480)),
        ] {
            var drag = CanvasConnectionDrag()
            let center = CGPoint(x: target.rect.x + 120, y: target.rect.y + 80)
            drag.update(from: source.id, at: center)
            let port = try #require(drag.startPort(in: [source, target], viewport: .init()))
            #expect(port.side == side)
            #expect(port.point == point)
            #expect(drag.start(in: [source, target], viewport: .init()) == point)
        }
        // Over empty board the pointer direction decides.
        var drag = CanvasConnectionDrag()
        drag.update(from: source.id, at: CGPoint(x: 520, y: 900))
        #expect(drag.startPort(in: [source], viewport: .init())?.side == .bottom)
    }

    @Test("A pointer within 24 points of a target port snaps to it and targets that card")
    func snapsToPort() throws {
        let source = card("Source", x: 20, y: 40)
        let target = card("Target", x: 500, y: 100)  // left port at (500, 180)
        let cards = [source, target]
        var drag = CanvasConnectionDrag()
        drag.update(from: source.id, at: CGPoint(x: 480, y: 190))
        let snap = try #require(drag.snap(in: cards, viewport: .init()))
        #expect(snap.card == target.id)
        #expect(snap.side == .left)
        #expect(snap.point == CGPoint(x: 500, y: 180))
        #expect(drag.target(in: cards, viewport: .init()) == target.id)
        // A target that does not accept a connection never snaps.
        #expect(drag.snap(in: cards, viewport: .init(), accepts: { _ in false }) == nil)

        var far = CanvasConnectionDrag()
        far.update(from: source.id, at: CGPoint(x: 450, y: 190))
        #expect(far.snap(in: cards, viewport: .init()) == nil)
        #expect(far.target(in: cards, viewport: .init()) == nil)

        // The radius is in screen points, so zoom does not widen it.
        let zoomed = CanvasViewport(scale: 0.5, x: 0, y: 0)
        var small = CanvasConnectionDrag()
        small.update(from: source.id, at: CGPoint(x: 250 - 20, y: 90))
        #expect(small.snap(in: cards, viewport: zoomed)?.card == target.id)
        small.update(from: source.id, at: CGPoint(x: 250 - 30, y: 90))
        #expect(small.snap(in: cards, viewport: zoomed) == nil)
    }

    @Test("Finishing records how the drag ended")
    func outcomes() throws {
        let source = card("Source", x: 20, y: 40)
        let target = card("Target", x: 500, y: 100)
        let cards = [source, target]

        var drag = CanvasConnectionDrag()
        #expect(drag.outcome == nil)
        let overTarget = CGPoint(x: 600, y: 160)
        drag.update(from: source.id, at: overTarget)
        _ = drag.finish(from: source.id, at: overTarget, cards: cards, viewport: .init())
        let dropped = try #require(drag.outcome)
        #expect(dropped.kind == .dropped(CanvasConnectionDrop(from: source.id, to: target.id)))
        #expect(dropped.serial == 1)
        #expect(drag.source == nil)

        let empty = CGPoint(x: 900, y: 900)
        drag.update(from: source.id, at: empty)
        #expect(
            drag.finish(from: source.id, at: empty, cards: cards, viewport: .init()) == nil)
        let emptyOutcome = try #require(drag.outcome)
        #expect(emptyOutcome.kind == .emptyBoard(source: source.id, point: empty))
        #expect(emptyOutcome.serial == 2)

        let onSource = CGPoint(x: 50, y: 60)
        drag.update(from: source.id, at: onSource)
        _ = drag.finish(from: source.id, at: onSource, cards: cards, viewport: .init())
        #expect(drag.outcome?.kind == .cancelled)

        // Escape wins even if the pointer is released over a target.
        drag.update(from: source.id, at: overTarget)
        drag.cancel()
        #expect(!drag.isActive)
        #expect(
            drag.finish(from: source.id, at: overTarget, cards: cards, viewport: .init()) == nil)
        #expect(drag.outcome?.kind == .cancelled)
        #expect(drag.outcome?.serial == 4)

        // Resetting keeps the last outcome, so the overlay cannot miss it.
        drag.reset()
        #expect(drag.outcome?.serial == 4)
        #expect(!drag.isActive)
    }

    private func card(_ name: String, x: Double, y: Double) -> CanvasCard {
        CanvasCard(
            title: name, rect: .init(x: x, y: y, width: 240, height: 160),
            content: .note(snapshot: ""))
    }
}
