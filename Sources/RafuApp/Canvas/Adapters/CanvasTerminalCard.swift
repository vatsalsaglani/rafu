import SwiftUI

struct CanvasTerminalCard: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.canvasPresentationID) private var presentationID
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    var body: some View {
        if case .terminal(let id) = card.content, let snapshot = session.terminal.terminalGroup(id)
        {
            VStack(spacing: 0) {
                if board.contentIsActive, session.canvasTerminalOwners[id] == board.id,
                    session.canvasResources[board.id]?.canPresent(owner: presentationID) == true
                {
                    TerminalGroupView(
                        snapshot: snapshot,
                        controllerForPane: { session.terminal.terminalController(for: $0) },
                        action: session.performTerminalGroupViewAction, theme: theme,
                        requestFocusToken: session.terminalGroupFocusRequest
                    )
                    .environment(
                        \.terminalSurfaceCanMount,
                        { [weak session] in
                            session?.canvasTerminalOwners[id] == board.id
                                && session?.canvasResources[board.id]?.canPresent(
                                    owner: presentationID) == true
                        })
                } else {
                    ContentUnavailableView {
                        Label(snapshot.name.rawValue, systemImage: "terminal")
                    } description: {
                        Text(
                            "\(snapshot.panes.count) panes. Enter Content to transfer the existing terminal view here. Stopped panes need a separate Start action."
                        )
                    } actions: {
                        Button("Enter Content") { enter(id) }
                        Button("Reveal Terminal Group") {
                            board.leaveContent()
                            session.revealTerminalGroup(id)
                        }
                    }
                }
            }
            .onChange(of: board.contentIsActive, initial: true) { _, active in
                if active { enter(id) }
            }
        } else {
            ContentUnavailableView(
                "Terminal Group Unavailable", systemImage: "terminal",
                description: Text("The group was closed. Add another group to this Canvas."))
        }
    }
    private func enter(_ id: TerminalGroupID) {
        guard session.canvasResources[board.id]?.permitsLiveContent == true,
            session.canvasResources[board.id]?.canPresent(owner: presentationID) == true
        else { return }
        guard session.canvasTerminalOwners[id] != nil || session.canvasTerminalOwners.count < 4
        else {
            board.errorMessage = "Four terminal card surfaces are already active. Leave one first."
            board.contentIsActive = false
            return
        }
        _ = try? session.terminal.perform(.revealGroup(id))
        session.canvasTerminalOwners[id] = board.id
        board.contentIsActive = true
        session.requestCanvasTerminalFocus()
    }
}

extension WorkspaceSession {
    func addCanvasTerminal(_ id: TerminalGroupID, to boardID: CanvasID) {
        guard let board = canvas.boards[boardID], let group = terminal.terminalGroup(id) else {
            return
        }
        performCanvasEdit(board) {
            try board.add(title: group.name.rawValue, content: .terminal(groupID: id))
        }
    }
    func addCanvasStoppedTerminal(_ id: CanvasID) {
        guard let board = canvas.boards[id], board.cards.count < CanvasLimits.cards,
            let name = TerminalGroupName("Canvas Terminal")
        else { return }
        performCanvasEdit(board) {
            let paneID = SavedTerminalPaneID()
            let pane = try SavedTerminalPaneRecord(
                id: paneID, explicitUserName: nil, themeColor: nil,
                kind: .ordinaryShell,
                launchProfile: .init(shell: .preferredShell, startingFolder: .root))
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: name,
                root: .pane(paneID), focusedPaneID: paneID, panes: [pane])
            let snapshot = try terminal.insertStoppedSavedGroup(record)
            _ = try terminal.perform(.detachDeletedSavedLayout(record.id))
            _ = try terminal.perform(.parkGroup(snapshot.id))
            try board.add(title: snapshot.name.rawValue, content: .terminal(groupID: snapshot.id))
        }
    }
    func closeCanvasTerminalCard(_ id: CanvasID) {
        guard let board = canvas.boards[id], board.selection.count == 1,
            let card = board.cards.first(where: { board.selection.contains($0.id) }),
            case .terminal(let groupID) = card.content
        else { return }
        pendingCanvasRemoval = nil
        pendingCanvasTerminalRemoval = (id, card.id, groupID)
        requestTerminalGroupClose(groupID)
        finishCanvasTerminalRemoval()
    }
    func finishCanvasTerminalRemoval() {
        guard let (id, cardID, groupID) = pendingCanvasTerminalRemoval,
            terminal.terminalGroup(groupID) == nil
        else { return }
        pendingCanvasTerminalRemoval = nil
        guard let board = canvas.boards[id] else { return }
        board.selection = [cardID]
        removeCanvasCards(id)
    }
}
