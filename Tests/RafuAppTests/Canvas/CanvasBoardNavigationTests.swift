import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Ensemble card-navigation shortcuts (⌃⌘←↑→↓, ⌃⌘], ⌃⌘[ in `CanvasCommands`):
/// `WorkspaceSession.focusCanvasCard` and its six entry points.
@Suite("Canvas board navigation")
@MainActor
struct CanvasBoardNavigationTests {
    @Test("Landing on a terminal card enters it; landing elsewhere only selects it")
    func focusSemanticsDifferByContentKind() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)

        try board.add(title: "Note", content: .note(snapshot: ""))
        let noteID = try #require(board.cards.first?.id)
        session.addCanvasStoppedTerminal(board.id)
        let terminalCard = try #require(board.cards.last)
        guard case .terminal(let groupID) = terminalCard.content else {
            Issue.record("Expected a terminal card")
            return
        }

        // Landing on the terminal card enters it.
        session.focusCanvasCard(terminalCard.id, in: board)
        #expect(board.contentIsActive)
        #expect(board.focusedCardID == terminalCard.id)
        #expect(board.selection == [terminalCard.id])

        // Landing on the note leaves content (it does not auto-enter a
        // note) but still tracks the note as the current card.
        session.focusCanvasCard(noteID, in: board)
        #expect(!board.contentIsActive)
        #expect(board.focusedCardID == noteID)
        #expect(board.selection == [noteID])

        session.canvasResources[board.id]?.stopAll()
        _ = groupID
        #expect(await session.canvas.flushAll())
    }

    @Test("focusCanvasCard does nothing for a card id not on the board")
    func focusCanvasCardIgnoresUnknownID() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        try board.add(title: "Note", content: .note(snapshot: ""))
        let before = board.selection

        session.focusCanvasCard(CanvasCardID(), in: board)

        #expect(board.selection == before)
        #expect(!board.contentIsActive)
        #expect(await session.canvas.flushAll())
    }

    @Test("Directional and reading-order focus move between cards on the selected Ensemble")
    func directionalAndReadingOrderFocusMoveBetweenCards() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)

        try board.add(title: "Left", content: .note(snapshot: ""))
        try board.add(title: "Right", content: .note(snapshot: ""))
        let left = board.cards[0]
        let right = board.cards[1]
        try board.edit { value in
            value.cards[0].rect = CanvasRect(x: 0, y: 0, width: 100, height: 80)
            value.cards[1].rect = CanvasRect(x: 300, y: 0, width: 100, height: 80)
        }
        board.focus(left.id)

        session.focusCanvasCard(direction: .right)
        #expect(board.selection == [right.id])

        session.focusCanvasCard(direction: .left)
        #expect(board.selection == [left.id])

        session.focusCanvasCard(direction: .up)
        #expect(board.selection == [left.id], "No card above: nothing moves")

        board.select([left.id])
        board.focusedCardID = nil
        session.focusNextCanvasCard(forward: true)
        #expect(board.selection == [right.id])

        session.focusNextCanvasCard(forward: false)
        #expect(board.selection == [left.id])

        #expect(await session.canvas.flushAll())
    }

    @Test("Every entry point returns silently without a selected Ensemble board")
    func noSelectedBoardIsANoOp() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        try board.add(title: "Note", content: .note(snapshot: ""))
        // The board is never presented, so `selectedCanvasID` is nil.
        #expect(session.selectedCanvasID == nil)
        let before = board.selection

        session.focusCanvasCard(direction: .left)
        session.focusCanvasCard(direction: .right)
        session.focusCanvasCard(direction: .up)
        session.focusCanvasCard(direction: .down)
        session.focusNextCanvasCard(forward: true)
        session.focusNextCanvasCard(forward: false)

        #expect(board.selection == before)
        #expect(!board.contentIsActive)
        #expect(await session.canvas.flushAll())
    }

    @Test("Directional focus is a no-op on an empty board, with or without a current card")
    func emptyBoardIsANoOp() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)

        session.focusCanvasCard(direction: .right)
        session.focusNextCanvasCard(forward: true)

        #expect(board.selection.isEmpty)
        #expect(await session.canvas.flushAll())
    }

    private func fixture(_ root: URL) async throws -> (WorkspaceSession, CanvasBoardState) {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-board-navigation-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: "saved-boards"))
            ))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: root.path)))
        #expect(await session.canvas.configure(root: root))
        return (session, try #require(await session.canvas.create(title: "Navigation")))
    }
}
