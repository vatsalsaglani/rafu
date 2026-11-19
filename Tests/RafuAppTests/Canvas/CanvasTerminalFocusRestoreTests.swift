import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Regression: the user typed in an Ensemble terminal, switched to another
/// Space or app, and came back. Hiding the window had released the terminal
/// (`CanvasBoardResources.pause`) and ended the card's content focus, so the
/// board took the keys and the next letter ran a board tool. The terminal
/// card that had the keys now gets them back, and the board's letter keys
/// stay off until it does.
@Suite("Ensemble terminal keeps the keys across a hidden window")
@MainActor
struct CanvasTerminalFocusRestoreTests {
    @Test("Remember the focused terminal card; keep an earlier one; restore only a terminal card")
    func decisionTable() {
        typealias R = CanvasContentFocusRestore
        let card = CanvasCardID()
        let earlier = CanvasCardID()
        #expect(
            R.remembered(
                contentIsActive: true, focusedCardID: card, focusedCardIsTerminal: true,
                pending: nil) == card)
        // A note or web card is not restored.
        #expect(
            R.remembered(
                contentIsActive: true, focusedCardID: card, focusedCardIsTerminal: false,
                pending: nil) == nil)
        // The board had the keys: nothing to give back.
        #expect(
            R.remembered(
                contentIsActive: false, focusedCardID: card, focusedCardIsTerminal: true,
                pending: nil) == nil)
        // A second hide notification keeps what the first remembered.
        #expect(
            R.remembered(
                contentIsActive: false, focusedCardID: nil, focusedCardIsTerminal: false,
                pending: earlier) == earlier)
        #expect(R.restored(pending: card, isTerminalCardOnBoard: true) == card)
        #expect(R.restored(pending: card, isTerminalCardOnBoard: false) == nil)
        #expect(R.restored(pending: nil, isTerminalCardOnBoard: true) == nil)
        #expect(R.contentHoldsKeys(contentIsActive: true, pending: nil))
        #expect(R.contentHoldsKeys(contentIsActive: false, pending: card))
        #expect(!R.contentHoldsKeys(contentIsActive: false, pending: nil))
    }

    @Test("Hide and show the window: the terminal card gets the keys back, board letters stay off")
    func hiddenWindowGivesTheKeysBack() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        #expect(board.contentIsActive)
        #expect(board.focusedCardID == card.id)
        let resources = try #require(session.canvasResources[board.id])

        resources.pause()
        #expect(!board.contentIsActive)
        #expect(board.contentFocusToRestore == card.id)
        // Even with the board focused, a letter must not pick a tool or add a node.
        #expect(!CanvasToolKeyHandler.keysActive(boardFocused: true, board: board))
        // A second hide notification (screen lock after a Space switch) keeps it.
        resources.pause()
        #expect(board.contentFocusToRestore == card.id)

        resources.windowBecameAvailable()
        #expect(resources.permitsLiveContent)
        #expect(board.contentIsActive)
        #expect(board.focusedCardID == card.id)
        #expect(board.contentFocusToRestore == nil)
        #expect(!CanvasToolKeyHandler.keysActive(boardFocused: true, board: board))
        session.teardownTerminalGroups()
    }

    @Test("When the board had the keys, showing the window gives them to the board")
    func boardFocusIsNotChanged() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        board.backToBoard()
        let resources = try #require(session.canvasResources[board.id])

        resources.pause()
        #expect(board.contentFocusToRestore == nil)
        resources.windowBecameAvailable()
        #expect(!board.contentIsActive)
        #expect(CanvasToolKeyHandler.keysActive(boardFocused: true, board: board))
        session.teardownTerminalGroups()
    }

    @Test("Hiding the board, or removing the card, while the window is hidden ends the restore")
    func restoreEndsWithTheBoardOrTheCard() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let resources = try #require(session.canvasResources[board.id])

        resources.pause()
        #expect(board.contentFocusToRestore != nil)
        // The board leaves view (another tab, a closed board).
        resources.stopAll()
        #expect(board.contentFocusToRestore == nil)
        #expect(CanvasToolKeyHandler.keysActive(boardFocused: true, board: board))

        // Undo of the add removes the card while the window is hidden.
        let card = try #require(board.cards.first)
        board.focus(card.id)
        resources.pause()
        #expect(board.contentFocusToRestore == card.id)
        board.performUndo()
        #expect(board.cards.isEmpty)
        resources.windowBecameAvailable()
        #expect(!board.contentIsActive)
        #expect(board.contentFocusToRestore == nil)
        session.teardownTerminalGroups()
    }
}
