import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A scratch workspace folder, removed when the last fixture holding it goes.
final class CanvasTerminalScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-terminal-start-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// One workspace with an open, selected Ensemble. `presented` also gives the
/// board a visible presenter, as a mounted board view does. No test spawns a
/// shell: a started pane gets a controller but no terminal view.
@MainActor
struct CanvasTerminalStartFixture {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let disk: CanvasPersistenceStore
    let scratch = CanvasTerminalScratchFolder()

    init(presented: Bool = true) async throws {
        let scratch = scratch
        let disk = CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
        let session = Self.makeSession(disk)
        session.descriptor = WorkspaceDescriptor(
            displayName: "Terminal start test",
            location: .local(LocalWorkspaceReference(path: scratch.url.path)))
        session.spawnsHeadlessCanvasTerminals = false
        #expect(await session.canvas.configure(root: scratch.url))
        let board = try #require(await session.canvas.create(title: "Start"))
        session.presentCanvasBoard(board)
        if presented { session.canvasResources[board.id]?.present(owner: UUID()) }
        self.session = session
        self.board = board
        self.disk = disk
    }

    static func makeSession(_ disk: CanvasPersistenceStore) -> WorkspaceSession {
        WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-terminal-start-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(persistence: disk))
    }

    func groupID(of card: CanvasCard) throws -> TerminalGroupID {
        guard case .terminal(let id) = card.content else { throw CanvasError.unavailable }
        return id
    }

    func pane(of card: CanvasCard) throws -> TerminalPaneSnapshot {
        try #require(session.terminal.terminalGroup(groupID(of: card))?.panes.first)
    }

    func hasEditorTab(_ groupID: TerminalGroupID) -> Bool {
        session.editorLayout.tab(matching: .terminalGroup(groupID: groupID)) != nil
    }
}

@Suite("A terminal the user adds starts its shell")
@MainActor
struct CanvasTerminalAddStartTests {
    @Test(
        "Foreground only when the board presents, the zoom shows live content and the lease is held"
    )
    func modeTable() {
        for permits in [false, true] {
            for face in [false, true] {
                for lease in [false, true] {
                    let mode = CanvasTerminalAddStart.mode(
                        permitsLiveContent: permits, faceShowsLiveContent: face, holdsLease: lease)
                    #expect(mode == (permits && face && lease ? .foreground : .background))
                }
            }
        }
    }

    @Test(
        "Add Terminal starts the shell, gives the card the lease and keyboard focus, no editor tab")
    func addStartsInForeground() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(try fixture.pane(of: card).status == .live)
        #expect(session.canvasTerminalOwners[groupID] == board.id)
        #expect(board.focusedCardID == card.id)
        #expect(board.contentIsActive)
        #expect(session.selectedTerminalGroupID == groupID)
        #expect(!fixture.hasEditorTab(groupID))
        #expect(session.selectedCanvasID == board.id)
        session.teardownTerminalGroups()
    }

    @Test("The Add menu kind and a shell row start the shell too")
    func addKindStarts() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        CanvasAddKind.terminal.perform(
            on: fixture.board, session: fixture.session, animated: false)
        let card = try #require(fixture.board.cards.first)
        #expect(try fixture.pane(of: card).status == .live)
        fixture.session.teardownTerminalGroups()
    }

    @Test("Zoomed out below 50 %, the shell starts in the background and the view does not move")
    func addZoomedOutStartsInBackground() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        board.setViewport(CanvasViewport(scale: 0.4, x: 0, y: 0))
        let viewportBefore = board.viewport
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(try fixture.pane(of: card).status == .live)
        #expect(!board.contentIsActive)
        #expect(board.selection == [card.id])
        #expect(board.viewport == viewportBefore)
        // The board presents, so the card holds the lease and shows the
        // terminal once the user zooms in.
        #expect(session.canvasTerminalOwners[groupID] == board.id)
        #expect(!fixture.hasEditorTab(groupID))
        session.teardownTerminalGroups()
    }

    @Test("A board with no presenter starts the shell in the background and takes no lease")
    func addOnHiddenBoardStartsInBackground() async throws {
        let fixture = try await CanvasTerminalStartFixture(presented: false)
        let session = fixture.session
        session.addCanvasTerminal(fixture.board.id)
        let card = try #require(fixture.board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(try fixture.pane(of: card).status == .live)
        #expect(session.canvasTerminalOwners[groupID] == nil)
        #expect(!fixture.board.contentIsActive)
        #expect(!fixture.hasEditorTab(groupID))
        session.teardownTerminalGroups()
    }

    @Test("A presented board that is not the focused tab never opens an editor tab for the start")
    func addOnUnfocusedBoardOpensNoEditorTab() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        // Another Ensemble becomes the focused group's tab; the first board
        // keeps its presenter, as a board in a second editor group does.
        let other = try #require(await session.canvas.create(title: "Other"))
        session.presentCanvasBoard(other)
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(try fixture.pane(of: card).status == .live)
        #expect(!fixture.hasEditorTab(groupID))
        #expect(!board.contentIsActive)
        #expect(board.selection == [card.id])
        #expect(session.selectedCanvasID == other.id)
        session.teardownTerminalGroups()
    }

    @Test("addCanvasStoppedTerminal still starts nothing")
    func stoppedAddStaysStopped() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let cardID = try #require(fixture.session.addCanvasStoppedTerminal(fixture.board.id))
        let card = try #require(fixture.board.cards.first)
        #expect(card.id == cardID)
        #expect(try fixture.pane(of: card).status == .stopped)
        #expect(fixture.session.terminal.sessions.isEmpty)
    }

    @Test("A saved board with a started terminal reopens with stopped panes")
    func reopenedBoardIsInert() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        fixture.session.addCanvasTerminal(fixture.board.id)
        let card = try #require(fixture.board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(try fixture.pane(of: card).status == .live)
        #expect(await fixture.session.canvas.save(fixture.board.id))

        let other = CanvasTerminalStartFixture.makeSession(fixture.disk)
        other.descriptor = fixture.session.descriptor
        other.spawnsHeadlessCanvasTerminals = false
        #expect(await other.canvas.configure(root: fixture.scratch.url))
        let reopened = try #require(await other.canvas.open(fixture.board.id))
        other.restoreCanvasTerminalReferences(reopened)
        other.presentCanvasBoard(reopened)
        let group = try #require(other.terminal.terminalGroup(groupID))
        #expect(group.panes.allSatisfy { $0.status == .stopped && $0.sessionID == nil })
        #expect(other.terminal.sessions.isEmpty)
        fixture.session.teardownTerminalGroups()
    }

    @Test("Duplicate starts the copy's shell at its final place")
    func duplicateStarts() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        let originalID = try #require(session.addCanvasStoppedTerminal(board.id))
        let original = try #require(board.cards.first)
        session.duplicateCanvasCard(board.id, originalID)
        #expect(board.cards.count == 2)
        let copy = try #require(board.cards.last)
        #expect(copy.rect.x == original.rect.x + 24)
        #expect(try fixture.pane(of: copy).status == .live)
        #expect(try fixture.pane(of: original).status == .stopped)
        #expect(board.focusedCardID == copy.id)
        session.teardownTerminalGroups()
    }

    @Test("Connect to new terminal starts the new card's shell")
    func connectToNewStarts() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasNote(board.id)
        let note = try #require(board.cards.first)
        session.connectCanvasToNew(
            .terminal, boardID: board.id, from: note.id, at: CGPoint(x: 600, y: 0))
        let created = try #require(board.cards.last)
        #expect(try fixture.pane(of: created).status == .live)
        #expect(board.hasConnection(from: note.id, to: created.id))
        session.teardownTerminalGroups()
    }

    @Test("Start Terminal Here on a presented board starts in the card with its lease")
    func startTerminalHereStartsInForeground() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        try board.add(title: "Orphan", content: .terminal(groupID: TerminalGroupID()))
        let orphan = try #require(board.cards.first)
        session.startTerminalHere(orphan.id, on: board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(try fixture.pane(of: card).status == .live)
        #expect(session.canvasTerminalOwners[groupID] == board.id)
        #expect(!fixture.hasEditorTab(groupID))
        session.teardownTerminalGroups()
    }
}
