import CoreGraphics
import Foundation
import SwiftUI

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
            let tab = editorLayout.tab(matching: .terminalGroup(groupID: groupID)),
            let sourceGroupID = editorLayout.group(containing: tab.id)?.id
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
            // The card stores the group name, automatic or not. A pane the
            // user named shows by that name through
            // `TerminalNaming.resolvedGroupTitle`, on the card and on the tab
            // an undo restores, so the stored name never has to change.
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
        movedTerminalCardSourceGroups[groupID] = sourceGroupID
        observeCanvasTerminalUndoRedo(board)
        AccessibilityNotification.Announcement("Terminal moved to Ensemble").post()
        return true
    }

    /// Wires `board.undoRedoObserver` once per board (idempotent), so an
    /// undo that removes a moved Terminal Group's card returns it to its
    /// source editor group, and a redo re-parks it. Attached lazily, the
    /// first time a move lands on this board, rather than at board creation,
    /// because only `WorkspaceSession` (not `WorkspaceCanvasStore`) knows
    /// about editor groups and terminals.
    private func observeCanvasTerminalUndoRedo(_ board: CanvasBoardState) {
        guard board.undoRedoObserver == nil else { return }
        board.undoRedoObserver = { [weak self, weak board] removed, added in
            guard let self, let board else { return }
            self.handleCanvasTerminalUndoRedo(board: board, removed: removed, added: added)
        }
    }

    private func handleCanvasTerminalUndoRedo(
        board: CanvasBoardState, removed: [CanvasCard], added: [CanvasCard]
    ) {
        for card in removed {
            guard case .terminal(let groupID) = card.content,
                let sourceGroupID = movedTerminalCardSourceGroups[groupID]
            else { continue }
            revealTerminalGroup(groupID, preferredGroupID: sourceGroupID)
            AccessibilityNotification.Announcement("Terminal moved back to its tab").post()
        }
        for card in added {
            guard case .terminal(let groupID) = card.content,
                movedTerminalCardSourceGroups[groupID] != nil,
                terminal.terminalGroup(groupID) != nil
            else { continue }
            hideTerminalGroup(groupID)
            guard parkedTerminalGroupIDs.contains(groupID) else { continue }
            board.focus(card.id)
            board.revealCard(card.id)
        }
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

    /// A Terminal Group dropped from the Terminals panel (`rafuEnsembleDrag`,
    /// `CanvasBoardDragPayload.terminalGroup`), named by id rather than an
    /// `EditorTabID` — unlike a dragged editor tab, a PARKED group has no tab
    /// to name. Always lands in the centre (a panel row carries no edge
    /// geometry); the same one-pane/not-already-on-a-board/board-capacity
    /// refusals as any other move apply. The drop is always handled once the
    /// board exists: the return value is `false` only when it is gone.
    @discardableResult
    func dropTerminalGroupOnCanvas(
        _ groupID: TerminalGroupID, boardID: CanvasID, at point: CGPoint
    ) -> Bool {
        guard let board = canvas.boards[boardID] else { return false }
        let center = CanvasBoardDropGeometry.boardPoint(point, viewport: board.viewport)
        if moveTerminalGroupToEnsemble(groupID, board: board, center: center) {
            presentCanvasBoard(board)
        }
        return true
    }
}
