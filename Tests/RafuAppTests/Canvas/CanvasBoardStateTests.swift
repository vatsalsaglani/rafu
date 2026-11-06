import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas board transactions")
@MainActor
struct CanvasBoardStateTests {
    @Test("Focus enters content once and returning to the board releases input")
    func directFocus() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Task"))
        try board.add(title: "Terminal", content: .terminal(groupID: TerminalGroupID()))
        let id = try #require(board.cards.first?.id)
        #expect(!board.contentIsActive)
        board.focus(id)
        #expect(board.selection == [id])
        #expect(board.focusedCardID == id)
        #expect(board.contentIsActive)
        board.backToBoard()
        #expect(!board.contentIsActive)
        #expect(board.focusedCardID == nil)
        board.focus(CanvasCardID())
        #expect(!board.contentIsActive)
        #expect(board.focusedCardID == nil)
    }

    @Test("Changing card focus keeps live surfaces attached")
    func focusDoesNotStopOtherCards() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Task"))
        try board.add(title: "First", content: .terminal(groupID: TerminalGroupID()))
        try board.add(title: "Second", content: .terminal(groupID: TerminalGroupID()))
        var stops = 0
        board.stopLiveContent = { stops += 1 }
        board.focus(board.cards[0].id)
        board.focus(board.cards[1].id)
        #expect(stops == 0)
        #expect(board.focusedCardID == board.cards[1].id)
        #expect(board.contentIsActive)
    }

    @Test("A drag is one undo transaction and undo retains the current storage revision")
    func gestureUndo() throws {
        var document = CanvasDocument(title: "Task")
        let card = CanvasCard(title: "File", content: .file(path: "README.md"))
        document.cards = [card]
        let board = CanvasBoardState(document: document)
        board.beginGesture()
        board.setRect(.init(x: 50, y: 50), for: card.id)
        board.setRect(.init(x: 80, y: 90), for: card.id)
        board.endGesture()
        #expect(board.canUndo)
        var saved = try board.snapshot()
        saved.revision = 1
        board.acceptSaved(saved, stamp: board.changeStamp)
        board.performUndo()
        #expect(board.cards[0].rect == card.rect)
        #expect(board.revision == 1)
        #expect(!board.canUndo && board.canRedo)
        board.performRedo()
        #expect(board.cards[0].rect.x == 80)
        #expect(board.revision == 1)
    }

    @Test("Native note edits are snapshotted only for save and changes during writes stay dirty")
    func noteSnapshotsAndSaveGeneration() throws {
        var document = CanvasDocument(title: "Task")
        let card = CanvasCard(title: "Note", content: .note(snapshot: "stored"))
        document.cards = [card]
        let board = CanvasBoardState(document: document)
        board.noteSnapshots[card.id] = { "native owner text" }
        board.markNoteEdited()
        let stamp = board.changeStamp
        var saved = try board.snapshot()
        #expect(saved.cards[0].content == .note(snapshot: "native owner text"))
        #expect(board.cards[0].content == .note(snapshot: "stored"))
        board.markNoteEdited()
        saved.revision = 1
        board.acceptSaved(saved, stamp: stamp)
        #expect(board.isDirty)
        #expect(board.revision == 1)
    }

    @Test("Removing a card removes its connections; undo restores references without live work")
    func removeAndUndo() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Task"))
        try board.add(title: "One", content: .terminal(groupID: TerminalGroupID()))
        try board.add(title: "Two", content: .note(snapshot: "two"))
        board.connectingFrom = board.cards[0].id
        try board.connect(to: board.cards[1].id)
        #expect(board.connections.count == 1)
        let removing = board.cards[0].id
        board.selection = [removing]
        try board.removeSelection()
        #expect(board.cards.count == 1 && board.connections.isEmpty)
        board.performUndo()
        #expect(board.cards.count == 2 && board.connections.count == 1)
        #expect(!board.contentIsActive)
        #expect(board.focusedCardID == nil)
    }
}

/// UX Round A: arrival (B1), landing (S1) and keyboard creation without motion.
@Suite("Ensemble arrival and landing")
@MainActor
struct CanvasBoardArrivalTests {
    private func board(scale: Double, x: Double = 0, y: Double = 0, cards: Int = 2)
        -> CanvasBoardState
    {
        var document = CanvasDocument(title: "Arrival")
        document.cards = (0..<cards).map {
            CanvasCard(
                title: "C\($0)", rect: CanvasRect(x: Double($0) * 500, y: 0),
                content: .note(snapshot: ""))
        }
        document.viewport = CanvasViewport(scale: scale, x: x, y: y)
        return CanvasBoardState(document: document)
    }

    @Test("A board saved at 10 % fits once on its first size and stays clean")
    func arrivalFitsOnceWithoutDirtying() {
        let board = board(scale: 0.1)
        var saves = 0
        board.requestSave = { saves += 1 }
        #expect(board.arrivalPending)
        board.arriveIfNeeded()  // no size yet: nothing happens
        #expect(board.arrivalPending)
        #expect(board.viewport.scale == 0.1)
        board.visibleSize = CGSize(width: 1_200, height: 800)
        board.arriveIfNeeded()
        #expect(!board.arrivalPending)
        #expect(board.viewport.scale > 0.25)
        #expect(
            !CanvasArrival.anyCardOutOfView(
                cards: board.cards.map(\.rect), viewport: board.viewport,
                visible: board.visibleSize))
        #expect(board.isDirty == false)
        #expect(saves == 0)
        // A second call is a no-op, even after the user zooms out again.
        board.setViewport(CanvasViewport(scale: 0.1, x: 0, y: 0))
        board.arriveIfNeeded()
        #expect(board.viewport.scale == 0.1)
    }

    @Test("A board with a card in view keeps its parked viewport")
    func parkedViewportKept() {
        let board = board(scale: 0.8, x: 40, y: 30)
        board.visibleSize = CGSize(width: 1_200, height: 800)
        board.arriveIfNeeded()
        #expect(board.viewport == CanvasViewport(scale: 0.8, x: 40, y: 30))
        #expect(board.isDirty == false)
    }

    @Test("A drop sets the landing; a menu add does not; animated false still adds")
    func landing() throws {
        let board = board(scale: 1, cards: 0)
        let dropped = try board.add(
            title: "Dropped", content: .note(snapshot: ""), center: CGPoint(x: 300, y: 300))
        #expect(board.landing?.ids == [dropped])
        board.landing = nil
        try board.add(title: "Menu", content: .note(snapshot: ""))
        #expect(board.landing == nil)
        try board.add(title: "Key", content: .note(snapshot: ""), animated: false)
        #expect(board.cards.count == 3)
        var added = 0
        board.withoutCreationMotion {
            #expect(!board.creationIsAnimated)
            added += 1
        }
        #expect(added == 1)
        #expect(board.creationIsAnimated)
    }
}
