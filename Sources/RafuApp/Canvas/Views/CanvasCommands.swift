import SwiftUI

struct CanvasCommands: Commands {
    @FocusedValue(\.workspaceSession) private var session
    private var board: CanvasBoardState? { session?.selectedCanvas }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Ensemble…") { session?.requestNewCanvas() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(session?.rootURL == nil)
            Button("Open Ensemble…") { session?.requestCanvasLibrary() }.disabled(
                session?.rootURL == nil)
            CanvasEnsembleFileCommandItems(session: session, board: board)  // X5 ensemble file
        }
        CommandMenu("Ensemble") {
            if let board, let session {
                Menu("Add to Ensemble") { CanvasAddMenuItems(board: board, session: session) }
                terminalShellShortcutItems(board: board, session: session)
                // X9 diagrams
                CanvasDiagramMenuItems(board: board, session: session, showsShortcut: true)
                Divider()
                cardNavigationItems(board: board, session: session)
            }
            Divider()
            Button("Zoom to Fit") { board?.fitAll() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(board == nil)
            Button("Zoom to Selection") { board?.zoomToSelection() }
                .keyboardShortcut("9", modifiers: [.command, .option])
                .disabled(board?.selection.isEmpty != false)
            Button("Actual Size") { board?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(board == nil)
            Button("Zoom In") { board?.zoom(1.2) }.disabled(board == nil)
            Button("Zoom Out") { board?.zoom(1 / 1.2) }.disabled(board == nil)
            Divider()
            Menu("Arrange") {
                Button("Tidy Up") {
                    if let board { session?.performCanvasEdit(board) { try board.arrange() } }
                }
                .disabled(board == nil)
                Divider()
                ForEach(CanvasAlignment.allCases, id: \.self) { alignment in
                    Button(alignment.title) {
                        if let board {
                            session?.performCanvasEdit(board) { try board.align(alignment) }
                        }
                    }
                    .disabled((board?.selection.count ?? 0) < 2)
                }
                Divider()
                ForEach(CanvasDistribution.allCases, id: \.self) { distribution in
                    Button(distribution.title) {
                        if let board {
                            session?.performCanvasEdit(board) { try board.distribute(distribution) }
                        }
                    }
                    .disabled((board?.selection.count ?? 0) < 3)
                }
                Divider()
                Button("Bring to Front") {
                    if let board {
                        session?.performCanvasEdit(board) { try board.bringSelectionToFront() }
                    }
                }
                .disabled(board?.selection.isEmpty != false)
                Button("Send to Back") {
                    if let board {
                        session?.performCanvasEdit(board) { try board.sendSelectionToBack() }
                    }
                }
                .disabled(board?.selection.isEmpty != false)
            }
            .disabled(board == nil)
            Menu("Show Links") {
                ForEach(CanvasLinkVisibility.allCases, id: \.self) { choice in
                    Button {
                        board?.linkVisibility = choice
                    } label: {
                        if board?.linkVisibility == choice {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            }
            .disabled(board == nil)
            Button("Pause All Links") {
                if let board { CanvasLiveBridge.shared.pauseAll(in: board) }
            }
            .disabled(board?.connections.contains { $0.behavior == .session } != true)
            Button("Resume All Links") {
                if let board { CanvasLiveBridge.shared.resumeAll(in: board) }
            }
            .disabled(board?.connections.contains { $0.behavior == .session } != true)
            Button("Connect Selected Cards…") {
                if let board { session?.requestCanvasConnection(board.id) }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(board?.selection.count != 2)
            // The menu path for deleting a selected link. Plain Backspace is
            // never a menu key: it would take the key from text input. The
            // item is off while card content has the keys, so Command-Delete
            // still deletes to the line start in a note or a terminal.
            Button("Delete Link") { board?.deleteSelectedConnectionIfAny() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(
                    board?.selectedConnection == nil || board?.contentIsActive != false
                        || board?.renamingCardID != nil)
            Divider()
            Button("Zoom to Card") {
                if let id = board?.selection.first { board?.zoomToCard(id) }
            }
            .disabled(board?.selection.count != 1)
            Button("Return to Board") {
                board?.backToBoard()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(board?.contentIsActive != true)
            Divider()
            Button("Undo Ensemble Layout") { board?.performUndo() }.disabled(board?.canUndo != true)
            Button("Redo Ensemble Layout") { board?.performRedo() }.disabled(board?.canRedo != true)
            Button("Select All Cards") {
                if let board { board.select(Set(board.cards.map(\.id))) }
            }
            .disabled(board?.cards.isEmpty != false)
            Button("Close Selected Cards") { session?.closeSelectedCanvasNodes() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(session?.canCloseSelectedCanvasNodes != true)
            Button("Remove Selected Cards…") {
                if let board { session?.requestCanvasCardRemoval(board.id) }
            }.disabled(board?.selection.isEmpty != false)
        }
        CommandGroup(after: .help) {
            Button("Ensemble Shortcuts") { session?.canvasDialog = .shortcuts }
                .disabled(session == nil)
        }
    }

    /// ⌃⌥1…⌃⌥9: one shortcut per discovered-shell catalog position (1 = the
    /// default shell), so every shell has its own key without opening the
    /// nested "Terminal with Shell" menu. Exists only while an Ensemble
    /// board is the focused tab (this is inside the `if let board, session`
    /// block above), so the key is never a live app-wide equivalent
    /// otherwise. With exactly one shell there is nothing to choose between,
    /// so ⌃⌥1 instead adds a plain terminal.
    @ViewBuilder
    private func terminalShellShortcutItems(board: CanvasBoardState, session: WorkspaceSession)
        -> some View
    {
        let shells = session.availableTerminalShells
        if shells.count >= 2 {
            ForEach(Array(shells.prefix(9).enumerated()), id: \.element.id) { offset, shell in
                Button(
                    "Terminal — \(TerminalNaming.shellMenuTitle(for: shell, among: shells))"
                ) {
                    session.addCanvasStoppedTerminal(board.id, shell: shell)
                }
                .keyboardShortcut(CanvasNavigationShortcuts.shellShortcut(forPosition: offset + 1))
            }
        } else {
            Button("Add Terminal") { session.addCanvasStoppedTerminal(board.id) }
                .keyboardShortcut(CanvasNavigationShortcuts.shellShortcut(forPosition: 1))
        }
    }

    /// ⌃⌘←↑→↓ move focus to the spatially adjacent card; ⌃⌘] and ⌃⌘[ move to
    /// the next/previous card in reading order. All six live only while an
    /// Ensemble board is focused (the surrounding `if let board, session`),
    /// and the four directional ones additionally stay disabled whenever
    /// "Focus Terminal Pane" in that same direction is enabled — the two
    /// features share ⌃⌘←↑→↓ by design, but a canvas terminal card is always
    /// one pane (`moveTerminalGroupToEnsemble` only accepts a one-pane
    /// group), so pane-direction focus can never actually be enabled while
    /// an Ensemble board is the focused tab. The guard exists for safety if
    /// that invariant ever changes.
    @ViewBuilder
    private func cardNavigationItems(board: CanvasBoardState, session: WorkspaceSession)
        -> some View
    {
        let keys = CanvasNavigationShortcuts.cardNavigation
        Button("Focus Card Left") { session.focusCanvasCard(direction: .left) }
            .keyboardShortcut(keys[0])
            .disabled(directionalFocusUnavailable(.left, session: session))
        Button("Focus Card Right") { session.focusCanvasCard(direction: .right) }
            .keyboardShortcut(keys[1])
            .disabled(directionalFocusUnavailable(.right, session: session))
        Button("Focus Card Up") { session.focusCanvasCard(direction: .up) }
            .keyboardShortcut(keys[2])
            .disabled(directionalFocusUnavailable(.up, session: session))
        Button("Focus Card Down") { session.focusCanvasCard(direction: .down) }
            .keyboardShortcut(keys[3])
            .disabled(directionalFocusUnavailable(.down, session: session))
        Button("Focus Next Card") { session.focusNextCanvasCard(forward: true) }
            .keyboardShortcut(keys[4])
        Button("Focus Previous Card") { session.focusNextCanvasCard(forward: false) }
            .keyboardShortcut(keys[5])
    }

    private func directionalFocusUnavailable(
        _ direction: CanvasCardDirection, session: WorkspaceSession
    ) -> Bool {
        let paneDirection: TerminalPaneFocusDirection
        switch direction {
        case .left: paneDirection = .left
        case .right: paneDirection = .right
        case .up: paneDirection = .up
        case .down: paneDirection = .down
        }
        return session.terminalGroupPresentationAvailability(.focus(paneDirection)).isEnabled
    }
}
