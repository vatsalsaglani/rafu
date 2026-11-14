import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// The ADR 0025 presentation lease follows the card: a running terminal that
/// is in view is shown, never behind a "Show Terminal" button.
@Suite("Ensemble terminal lease follows the card")
@MainActor
struct CanvasTerminalLeaseTests {
    @Test("decide: stopped first, then holder, then whether this board view can present")
    func decideTable() {
        let holders: [CanvasTerminalLeaseHolder] = [.none, .thisBoard, .otherBoard, .editorTab]
        for holder in holders {
            for canPresent in [false, true] {
                #expect(
                    CanvasTerminalCardBlock.decide(
                        isRunning: false, holder: holder, boardCanPresent: canPresent)
                        == .notRunning)
            }
        }
        func running(_ holder: CanvasTerminalLeaseHolder, _ canPresent: Bool)
            -> CanvasTerminalCardBlock
        {
            CanvasTerminalCardBlock.decide(
                isRunning: true, holder: holder, boardCanPresent: canPresent)
        }
        #expect(running(.thisBoard, true) == .live)
        #expect(running(.none, true) == .claim)
        #expect(running(.otherBoard, true) == .heldElsewhere(.otherBoard))
        #expect(running(.editorTab, true) == .heldElsewhere(.editorTab))
        #expect(running(.thisBoard, false) == .heldElsewhere(.thisBoard))
        #expect(running(.none, false) == .heldElsewhere(.none))
        #expect(running(.otherBoard, false) == .heldElsewhere(.otherBoard))
        #expect(running(.editorTab, false) == .heldElsewhere(.editorTab))
    }

    @Test("A focused terminal stays live down to 25 %; an unfocused one below 50 % does not")
    func liveRule() {
        #expect(CanvasTerminalLiveRule.isLive(scale: 0.5, isContentActive: false))
        #expect(!CanvasTerminalLiveRule.isLive(scale: 0.49, isContentActive: false))
        #expect(CanvasTerminalLiveRule.isLive(scale: 0.49, isContentActive: true))
        #expect(CanvasTerminalLiveRule.isLive(scale: 0.25, isContentActive: true))
        #expect(!CanvasTerminalLiveRule.isLive(scale: 0.24, isContentActive: true))
        #expect(CanvasTerminalLiveRule.isLive(scale: 1, isContentActive: false))
    }

    @Test("Undo of an add leaves a parked running group; prune drops the board's lease on it")
    func pruneReleasesLeaseOfRemovedCard() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        #expect(session.canvasTerminalOwners[groupID] == board.id)
        board.performUndo()
        #expect(board.cards.isEmpty)
        session.canvasResources[board.id]?.prune()
        #expect(session.canvasTerminalOwners[groupID] == nil)
        // The shell keeps running, parked, like an agent terminal.
        #expect(session.terminal.terminalGroup(groupID)?.panes.first?.status == .live)
        session.teardownTerminalGroups()
    }

    @Test("prune keeps the lease of a card still on the board")
    func pruneKeepsLeaseOfPresentCard() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        fixture.session.addCanvasTerminal(fixture.board.id)
        let groupID = try fixture.groupID(of: try #require(fixture.board.cards.first))
        fixture.session.canvasResources[fixture.board.id]?.prune()
        #expect(fixture.session.canvasTerminalOwners[groupID] == fixture.board.id)
        fixture.session.teardownTerminalGroups()
    }

    @Test(
        "Hiding a card's terminal group (⌃`) frees the lease and the mounted card claims it again")
    func hideThenClaim() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let groupID = try fixture.groupID(of: try #require(board.cards.first))
        #expect(session.selectedTerminalGroupID == groupID)
        session.toggleTerminal()
        #expect(session.canvasTerminalOwners[groupID] == nil)
        let holder = session.canvasTerminalLeaseHolder(groupID, board: board.id)
        #expect(holder == CanvasTerminalLeaseHolder.none)
        #expect(
            CanvasTerminalCardBlock.decide(isRunning: true, holder: holder, boardCanPresent: true)
                == .claim)
        #expect(!fixture.hasEditorTab(groupID))
        session.teardownTerminalGroups()
    }

    @Test(
        "After Transfer Here the selected editor tab holds the terminal; the card does not take it back"
    )
    func transferHereIsEditorTabHolder() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let groupID = try fixture.groupID(of: try #require(board.cards.first))
        // The group's tab opens, and the user chooses Transfer Here on it.
        session.revealTerminalGroup(groupID)
        #expect(session.canvasTerminalLeaseHolder(groupID, board: board.id) == .thisBoard)
        session.canvasTerminalOwners[groupID] = nil
        let holder = session.canvasTerminalLeaseHolder(groupID, board: board.id)
        #expect(holder == .editorTab)
        #expect(
            CanvasTerminalCardBlock.decide(isRunning: true, holder: holder, boardCanPresent: true)
                == .heldElsewhere(.editorTab))
        session.teardownTerminalGroups()
    }

    @Test("Another board's lease reads as held by another board")
    func otherBoardHolder() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let groupID = TerminalGroupID()
        fixture.session.canvasTerminalOwners[groupID] = CanvasID()
        #expect(
            fixture.session.canvasTerminalLeaseHolder(groupID, board: fixture.board.id)
                == .otherBoard)
    }

    @Test("Reveal from the Terminals list focuses the card on its Ensemble and opens no editor tab")
    func revealWhereItLivesFocusesCard() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        board.backToBoard()
        let other = try #require(await session.canvas.create(title: "Other"))
        session.presentCanvasBoard(other)
        #expect(session.selectedCanvasID == other.id)

        session.revealTerminalGroupWhereItLives(groupID)
        #expect(session.selectedCanvasID == board.id)
        #expect(board.focusedCardID == card.id)
        #expect(board.contentIsActive)
        #expect(!fixture.hasEditorTab(groupID))
        session.teardownTerminalGroups()
    }

    @Test("Reveal of a session whose group is on an Ensemble goes to the card too")
    func revealSessionGoesToCard() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        session.addCanvasTerminal(board.id)
        let card = try #require(board.cards.first)
        let groupID = try fixture.groupID(of: card)
        let sessionID = try #require(try fixture.pane(of: card).sessionID)
        board.backToBoard()
        session.revealTerminalSession(sessionID)
        #expect(board.focusedCardID == card.id)
        #expect(!fixture.hasEditorTab(groupID))
        session.teardownTerminalGroups()
    }

    @Test("Reveal of a group with no card reveals it as an editor tab")
    func revealWithoutCardOpensTab() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let group = try session.terminal.createLiveGroup(
            instantiation: .ordinaryShell(
                startingDirectory: fixture.scratch.url.path, shell: shell, profile: profile))
        session.revealTerminalGroupWhereItLives(group.id)
        #expect(fixture.hasEditorTab(group.id))
        session.teardownTerminalGroups()
    }

    @Test("A card on a presented board reads as on an Ensemble with no lease")
    func cardGroupsCountAsOnEnsemble() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let cardID = try #require(fixture.session.addCanvasStoppedTerminal(fixture.board.id))
        let card = try #require(fixture.board.cards.first { $0.id == cardID })
        let groupID = try fixture.groupID(of: card)
        #expect(fixture.session.canvasTerminalOwners[groupID] == nil)
        #expect(fixture.session.canvasCardTerminalGroupIDs.contains(groupID))
    }

    @Test("Undo of a moved terminal card releases the lease before the tab returns")
    func undoMoveReleasesLease() async throws {
        let fixture = try await CanvasTerminalStartFixture()
        let session = fixture.session
        let board = fixture.board
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let group = try session.terminal.createLiveGroup(
            instantiation: .ordinaryShell(
                startingDirectory: fixture.scratch.url.path, shell: shell, profile: profile))
        session.revealTerminalGroup(group.id)
        #expect(session.moveTerminalGroupToEnsemble(group.id, board: board, center: nil))
        // The mounted card claims the lease.
        #expect(session.claimCanvasTerminalLease(group.id, for: board.id))
        board.performUndo()
        #expect(session.canvasTerminalOwners[group.id] == nil)
        #expect(fixture.hasEditorTab(group.id))
        session.teardownTerminalGroups()
    }
}
