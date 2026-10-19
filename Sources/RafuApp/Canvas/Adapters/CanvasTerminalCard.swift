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
                if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
                    exitedStrip(pane, id: id)
                }
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
                        notRunningBlock(pane, id: id)
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
            .onChange(of: board.terminalStartRequest, initial: true) { _, request in
                guard request == card.id else { return }
                board.terminalStartRequest = nil
                startOrRestart(id)
            }
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

    /// Not running: one centred block with the next step (review C6).
    private func notRunningBlock(_ pane: TerminalPaneSnapshot, id: TerminalGroupID) -> some View {
        let shell = pane.launchProfile.map { CanvasCardPresentation.shellName($0.shell) }
        let folder = pane.launchProfile.map {
            CanvasCardPresentation.folderName($0.startingFolder.rawValue)
        }
        return VStack(spacing: 10) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 28)).foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            if let shell {
                Text(shell).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            if let folder {
                Text(folder).font(.system(size: 12)).foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            if pane.status == .stopped, pane.startAvailability == .available {
                Button("Start Shell") { startOrRestart(id) }
                    .buttonStyle(RafuProminentButtonStyle())
                    .help("Start a shell in this card. Nothing runs until you start it.")
            } else {
                Text("Terminal unavailable").font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitedStrip(_ pane: TerminalPaneSnapshot, id: TerminalGroupID) -> some View {
        HStack {
            Text("The shell has exited.").font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer()
            Button("Restart Shell") { startOrRestart(id) }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.palette.cardBackground)
    }

    /// Start Shell and Restart Shell are explicit user actions: the button,
    /// the header, the menu, or Return on the selected card.
    private func startOrRestart(_ id: TerminalGroupID) {
        guard focus(id), let pane = session.terminal.terminalGroup(id)?.panes.first else {
            return
        }
        if pane.status == .stopped, pane.startAvailability == .available {
            session.performTerminalGroupViewAction(.start(pane.id))
        } else if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
            session.performTerminalGroupViewAction(.restart(pane.id))
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
