import SwiftUI

/// A Canvas terminal is one native terminal surface. The existing terminal
/// manager remains the runtime owner; no second PTY or process model is added.
struct CanvasTerminalCard: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.canvasPresentationID) private var presentationID
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    private var active: Bool { board.contentIsActive && board.focusedCardID == card.id }

    var body: some View {
        if case .terminal(let id) = card.content, let group = session.terminal.terminalGroup(id),
            let pane = group.panes.first
        {
            VStack(spacing: 0) {
                HStack {
                    Text(
                        TerminalPanePresentation.statusLabel(
                            for: pane,
                            controllerStatus: session.terminal.terminalController(for: pane.id)?
                                .status)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if pane.status == .stopped, pane.startAvailability == .available {
                        Button("Start") {
                            guard focus(id) else { return }
                            session.performTerminalGroupViewAction(.start(pane.id))
                        }
                    }
                    if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
                        Button("Restart") {
                            guard focus(id) else { return }
                            session.performTerminalGroupViewAction(.restart(pane.id))
                        }
                    }
                }.padding(6).buttonStyle(.bordered).controlSize(.small)
                if session.canvasTerminalOwners[id] == board.id,
                    session.canvasResources[board.id]?.canPresent(owner: presentationID) == true
                {
                    if let controller = session.terminal.terminalController(for: pane.id) {
                        TerminalHostView(
                            controller: controller, theme: theme, paneID: pane.id,
                            isFocusedPane: active,
                            requestFocusToken: session.terminalGroupFocusRequest,
                            onDidBecomeFirstResponder: { paneID in
                                if !active { board.focus(card.id) }
                                session.performTerminalGroupViewAction(.focus(paneID))
                            }
                        )
                        .environment(
                            \.terminalSurfaceCanMount,
                            { [weak session] in
                                session?.canvasTerminalOwners[id] == board.id
                                    && session?.canvasResources[board.id]?.canPresent(
                                        owner: presentationID) == true
                            })
                    } else {
                        Button {
                            focus(id)
                        } label: {
                            Text(
                                pane.status == .stopped
                                    ? "Start this terminal when you are ready."
                                    : "Terminal unavailable"
                            )
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("Terminal view is not attached.").font(.caption)
                        Button("Show Terminal") { acquire(id) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(
                of: session.canvasResources[board.id]?.canPresent(owner: presentationID) == true,
                initial: true
            ) { _, available in if available { acquire(id) } }
            .onChange(of: active) { _, value in if value { focus(id) } }
            .onDisappear {
                guard session.canvasResources[board.id]?.canPresent(owner: presentationID) == true,
                    session.canvasTerminalOwners[id] == board.id
                else { return }
                session.canvasTerminalOwners[id] = nil
            }
        } else {
            Text("Terminal unavailable. Add another terminal.")
                .font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func acquire(_ id: TerminalGroupID) {
        guard session.canvasResources[board.id]?.permitsLiveContent == true,
            session.canvasResources[board.id]?.canPresent(owner: presentationID) == true,
            board.cards.first(where: { $0.content == .terminal(groupID: id) })?.id == card.id
        else { return }
        guard
            session.canvasTerminalOwners[id] == board.id
                || (session.canvasTerminalOwners[id] == nil
                    && session.canvasTerminalOwners.count < 4)
        else { return }
        session.canvasTerminalOwners[id] = board.id
    }

    @discardableResult
    private func focus(_ id: TerminalGroupID) -> Bool {
        acquire(id)
        guard session.canvasTerminalOwners[id] == board.id else { return false }
        if !active { board.focus(card.id) }
        _ = try? session.terminal.perform(.revealGroup(id))
        if let pane = session.terminal.terminalGroup(id)?.panes.first {
            session.focusTerminalPane(pane.id, in: id)
        }
        session.requestCanvasTerminalFocus()
        return true
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
            let name = TerminalGroupName("Terminal")
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
