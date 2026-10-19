import CoreGraphics
import Foundation

/// Moving an open Terminal Group onto an Ensemble board, and routing a tab
/// that is dropped on a visible board. The move is an explicit user action
/// (a drag, or "Move to Ensemble" in the tab menu). It starts no process: the
/// group keeps running if it ran, and a stopped group stays stopped.
extension WorkspaceSession {
    /// The editor group whose selected tab is this board, if any. A tab
    /// dropped on a visible board is forwarded to this group for edge splits.
    func editorGroupShowingCanvas(_ boardID: CanvasID) -> EditorGroupID? {
        editorLayout.groupIDs.first { groupID in
            guard let group = editorLayout.group(id: groupID), let selected = group.selectedTabID,
                let tab = group.tabs.first(where: { $0.id == selected })
            else { return false }
            return tab.resource == .canvas(boardID)
        }
    }

    /// Whether "Move to Ensemble" can work for this group now: it has one
    /// pane and there is an Ensemble to receive it.
    func canMoveTerminalGroupToEnsemble(_ groupID: TerminalGroupID) -> Bool {
        agentResumeEnsembleBoard != nil && terminal.terminalGroup(groupID)?.panes.count == 1
    }

    /// The tab menu path: moves the group to the Ensemble on screen (or the
    /// first Ensemble tab) and shows that Ensemble.
    func moveTerminalGroupToCurrentEnsemble(_ groupID: TerminalGroupID) {
        guard let board = agentResumeEnsembleBoard else { return }
        if moveTerminalGroupToEnsemble(groupID, board: board, center: nil) {
            presentCanvasBoard(board)
        }
    }

    /// Moves one open Terminal Group onto `board` as a terminal card, centred
    /// on `center` (board units) when given. The tab leaves the editor and the
    /// group is parked, so its process keeps running and the card takes over
    /// the same terminal view. One undoable board edit: undo removes only the
    /// card; the group stays parked and is reachable from the Terminals list.
    ///
    /// Refuses, with a message on the board and the tab left in place, when
    /// the group is not open in this window, has more than one pane, is on a
    /// loaded Ensemble already, or the board is full.
    @discardableResult
    func moveTerminalGroupToEnsemble(
        _ groupID: TerminalGroupID, board: CanvasBoardState, center: CGPoint?
    ) -> Bool {
        guard let group = terminal.terminalGroup(groupID),
            editorLayout.tab(matching: .terminalGroup(groupID: groupID)) != nil
        else {
            board.errorMessage = "Drag a terminal onto an Ensemble in its own window."
            return false
        }
        guard group.panes.count == 1 else {
            board.errorMessage = "Only a terminal with one pane can move to an Ensemble."
            return false
        }
        let content = CanvasCardContent.terminal(groupID: groupID)
        guard
            !canvas.boards.values.contains(where: { loaded in
                loaded.cards.contains { $0.content == content }
            })
        else {
            board.errorMessage = "This terminal is already on an Ensemble."
            return false
        }
        guard board.cards.count < CanvasLimits.cards else {
            board.errorMessage = "This Ensemble is full. Remove a card, then try again."
            return false
        }
        var cardID: CanvasCardID?
        performCanvasEdit(board) {
            try board.add(title: group.name.rawValue, content: content, center: center)
            cardID = board.cards.first(where: { $0.content == content })?.id
        }
        guard let cardID else { return false }
        hideTerminalGroup(groupID)
        guard parkedTerminalGroupIDs.contains(groupID) else {
            // The group could not be parked: undo the card so the terminal
            // is not shown twice.
            board.performUndo()
            return false
        }
        board.focus(cardID)
        board.revealCard(cardID)
        return true
    }

    /// A tab dropped on a visible board (shared by the SwiftUI delegate and
    /// the AppKit bridge). A Terminal Group tab dropped in the centre moves
    /// onto the board; every other drop is the editor group's own, so an edge
    /// band still splits the group under the board. `point` and `surface` are
    /// in the board view's top-left space. The drop is always handled once:
    /// the return value is `false` only when the board is gone.
    @discardableResult
    func dropEditorTabOnCanvas(
        _ value: String, boardID: CanvasID, at point: CGPoint, surface: CGSize
    ) -> Bool {
        clearEditorDrag()
        guard let board = canvas.boards[boardID] else { return false }
        guard let uuid = UUID(uuidString: value) else { return true }
        let tabID = EditorTabID(rawValue: uuid)
        guard let tab = editorLayout.group(containing: tabID)?.tabs.first(where: { $0.id == tabID })
        else {
            board.errorMessage = "Drag a tab onto an Ensemble in its own window."
            return true
        }
        var terminalGroupID: TerminalGroupID?
        if case .terminalGroup(let id) = tab.resource { terminalGroupID = id }
        let edge = EditorDropGeometry.target(at: point, in: surface)
        switch CanvasBoardTabDrop.decide(edge: edge, isTerminalGroupTab: terminalGroupID != nil) {
        case .moveTerminalToBoard:
            guard let terminalGroupID else { return true }
            let center = CanvasBoardDropGeometry.boardPoint(point, viewport: board.viewport)
            if moveTerminalGroupToEnsemble(terminalGroupID, board: board, center: center) {
                presentCanvasBoard(board)
            }
            return true
        case .forwardToGroup(let edge):
            guard let groupID = editorGroupShowingCanvas(boardID) else { return true }
            handleEditorTabDrop(value, on: groupID, edge: edge)
            return true
        }
    }
}
