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
        board.showsList = true
        board.focus(id)
        #expect(!board.showsList)
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
        try board.add(title: "Two", content: .nativeApp(bundleID: "com.apple.TextEdit"))
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
