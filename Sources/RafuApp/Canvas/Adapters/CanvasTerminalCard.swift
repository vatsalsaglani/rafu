import SwiftUI

/// Who shows a running terminal's one SwiftTerm view now (ADR 0025 lease).
/// `.editorTab` is only when no board holds the lease and the group's editor
/// tab is the selected tab of an editor group (after Transfer Here).
nonisolated enum CanvasTerminalLeaseHolder: Equatable, Sendable {
    case none
    case thisBoard
    case otherBoard
    case editorTab
}

/// Which block a terminal card's body shows. The lease follows the card: a
/// running terminal whose lease is free is claimed at once (`.claim`), so a
/// card that comes back into view, that the user zooms in to, or that a
/// resize mounts again shows its terminal with no click. Only a terminal that
/// another surface shows asks the user (`.heldElsewhere`). A stopped pane has
/// nothing to show and is always `.notRunning`.
nonisolated enum CanvasTerminalCardBlock: Equatable, Sendable {
    case live
    /// Running, lease free: take it now.
    case claim
    case heldElsewhere(CanvasTerminalLeaseHolder)
    case notRunning

    /// `boardCanPresent` is true when this card's board view is the visible
    /// presenter of the board and its window is visible. When it is false
    /// the board cannot take the lease, so even a free or own lease reads as
    /// `.heldElsewhere` (another view of the board presents it).
    static func decide(
        isRunning: Bool, holder: CanvasTerminalLeaseHolder, boardCanPresent: Bool
    ) -> CanvasTerminalCardBlock {
        guard isRunning else { return .notRunning }
        switch holder {
        case .thisBoard: return boardCanPresent ? .live : .heldElsewhere(.thisBoard)
        case .none: return boardCanPresent ? .claim : .heldElsewhere(.none)
        case .otherBoard, .editorTab: return .heldElsewhere(holder)
        }
    }
}

/// When a terminal card shows its live face. Other card kinds keep
/// `CanvasZoomFace.showsLiveContent` (live at 50 % and above). A terminal the
/// user is working in (content-active) stays live down to 25 %, so zooming
/// out does not take the shell away from under the keyboard.
nonisolated enum CanvasTerminalLiveRule {
    static let readableScale = 0.5
    static let focusedFloor = 0.25

    static func isLive(scale: Double, isContentActive: Bool) -> Bool {
        scale >= readableScale || (isContentActive && scale >= focusedFloor)
    }
}

/// How a terminal the user adds starts its shell (`startCanvasTerminalCard`).
nonisolated enum CanvasTerminalAddStart: Equatable, Sendable {
    /// The card can host the view: focus it, start, the keyboard goes to the shell.
    case foreground
    /// The card cannot host the view now (board not presentable, zoomed out
    /// below 50 %, or no lease): start without moving the view or focus.
    case background

    static func mode(permitsLiveContent: Bool, faceShowsLiveContent: Bool, holdsLease: Bool)
        -> CanvasTerminalAddStart
    {
        permitsLiveContent && faceShowsLiveContent && holdsLease ? .foreground : .background
    }
}

/// A Canvas terminal is one native terminal surface. The existing terminal
/// manager remains the runtime owner; no second PTY or process model is added.
struct CanvasTerminalCard: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuWindowSurface) private var windowSurface
    @Environment(\.canvasPresentationID) private var presentationID
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    private var active: Bool { board.contentIsActive && board.focusedCardID == card.id }

    var body: some View {
        if case .terminal(let id) = card.content, let group = session.terminal.terminalGroup(id),
            let pane = group.panes.first
        {
            let controller = session.terminal.terminalController(for: pane.id)
            let block = CanvasTerminalCardBlock.decide(
                isRunning: controller != nil,
                holder: session.canvasTerminalLeaseHolder(id, board: board.id),
                boardCanPresent: boardCanPresent)
            VStack(spacing: 0) {
                if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
                    exitedStrip(pane, id: id)
                }
                switch block {
                case .live:
                    if let controller {
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
                    }
                case .claim:
                    // The claim lands in `onChange(of: block)` below; until
                    // then draw the terminal's background, not a button.
                    windowSurface.fill(theme.palette.editorBackground, .cardContent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .heldElsewhere(let holder):
                    heldElsewhereBlock(holder, id: id)
                case .notRunning:
                    notRunningBlock(pane, id: id)
                }
            }
            // Level-triggered: whenever the terminal runs and its lease is
            // free while this card is on screen, the card takes it. This
            // covers a card that comes back into view, zooms in, remounts
            // during a resize, or loses the lease to ⌃` while mounted.
            .onChange(of: block, initial: true) { _, block in
                if block == .claim { acquire(id, forStart: false) }
            }
            .onChange(of: active) { _, value in if value { focus(id) } }
            .onChange(of: board.terminalStartRequest, initial: true) { _, request in
                guard request == card.id else { return }
                board.terminalStartRequest = nil
                startOrRestart(id)
            }
            // Lines an agent queued while the shell was stopped: type them once
            // this card's shell runs, so a later Start (the agent's terminal_start
            // or the user's button) delivers them. The drain is idempotent.
            .task(id: pane.sessionID) {
                guard pane.sessionID != nil else { return }
                guard board.pendingTerminalLines[card.id] != nil else { return }
                await CanvasTerminalStarter.drain(
                    card: card.id, groupID: id, board: board, session: session)
            }
            // No release on disappear: the lease follows the card, not its
            // view. A cull, a zoom-out or a resize remount keeps it, so the
            // card shows its terminal again at once. Board hide, window hide,
            // card removal, Transfer Here and group close release it.
        } else {
            // The referenced Terminal Group no longer exists (e.g. a saved
            // board reopened with ADR 0025 inert restore, before any process
            // started). Offer to create a fresh stopped group for this same
            // card — same id and frame — rather than a dead end.
            VStack(spacing: 10) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 28)).foregroundStyle(theme.palette.textSecondary)
                    .accessibilityHidden(true)
                Text("No terminal yet").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Button("Start Terminal Here") { session.startTerminalHere(card.id, on: board.id) }
                    .buttonStyle(RafuProminentButtonStyle())
                    .help("Create a terminal for this card and start its shell.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// This board view is the visible presenter of the board, in a visible window.
    private var boardCanPresent: Bool {
        session.canvasResources[board.id].map {
            $0.permitsLiveContent && $0.canPresent(owner: presentationID)
        } == true
    }

    /// A running terminal that another surface shows. "Show Here" moves the
    /// one view to this card; the other surface then shows its own notice.
    private func heldElsewhereBlock(_ holder: CanvasTerminalLeaseHolder, id: TerminalGroupID)
        -> some View
    {
        VStack(spacing: 8) {
            Text(Self.heldElsewhereMessage(holder)).font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
            if boardCanPresent {
                Button("Show Here") {
                    session.canvasTerminalOwners[id] = board.id
                    focus(id)
                }
                .help("Show this terminal on this card.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func heldElsewhereMessage(_ holder: CanvasTerminalLeaseHolder) -> String {
        switch holder {
        case .editorTab: "This terminal is shown in an editor tab."
        case .otherBoard: "This terminal is shown on another Ensemble."
        case .none, .thisBoard: "This terminal is shown in another view."
        }
    }

    /// Not running: one centred block with the next step (review C6).
    private func notRunningBlock(_ pane: TerminalPaneSnapshot, id: TerminalGroupID) -> some View {
        let shell = pane.launchProfile.map { CanvasCardPresentation.shellName($0.shell) }
        // The folder Start Shell uses: the last working folder, else the
        // starting folder (restoration already dropped a missing one), else
        // the workspace folder when both are gone.
        let fallback = session.terminalPanesStartingInWorkspaceFolder.contains(pane.id)
        let folder = pane.launchProfile.map {
            CanvasCardPresentation.terminalStartFolderLine($0, startsInWorkspaceFolder: fallback)
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
                    .lineLimit(fallback ? 2 : 1)
                    .multilineTextAlignment(.center)
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
    /// the header, the menu, or Return on the selected card. A stopped card
    /// holds no lease, so the start takes one first.
    private func startOrRestart(_ id: TerminalGroupID) {
        guard focus(id, forStart: true), let pane = session.terminal.terminalGroup(id)?.panes.first
        else {
            return
        }
        if pane.status == .stopped, pane.startAvailability == .available {
            session.performTerminalGroupViewAction(.start(pane.id))
        } else if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
            session.performTerminalGroupViewAction(.restart(pane.id))
        }
    }

    /// Takes the presentation lease (ADR 0025) for a card that has a terminal
    /// to show, or that is about to start one (`forStart`). A stopped card
    /// takes none. There is no limit on how many terminals a board holds.
    private func acquire(_ id: TerminalGroupID, forStart: Bool) {
        guard session.canvasResources[board.id]?.permitsLiveContent == true,
            session.canvasResources[board.id]?.canPresent(owner: presentationID) == true,
            board.cards.first(where: { $0.content == .terminal(groupID: id) })?.id == card.id
        else { return }
        guard forStart || hasTerminalToShow(id) else { return }
        session.claimCanvasTerminalLease(id, for: board.id)
    }

    private func hasTerminalToShow(_ id: TerminalGroupID) -> Bool {
        guard let pane = session.terminal.terminalGroup(id)?.panes.first else { return false }
        return session.terminal.terminalController(for: pane.id) != nil
    }

    @discardableResult
    private func focus(_ id: TerminalGroupID, forStart: Bool = false) -> Bool {
        acquire(id, forStart: forStart)
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
    /// Adds one terminal card for the user and starts its shell: an add is
    /// the explicit user action, so no second "Start Shell" click is needed.
    /// See `startCanvasTerminalCard` for where the view and focus go.
    func addCanvasTerminal(_ id: CanvasID, shell: TerminalShell? = nil) {
        guard let cardID = addCanvasStoppedTerminal(id, shell: shell) else { return }
        startCanvasTerminalCard(cardID, on: id)
    }

    /// Adds one stopped terminal card and returns its id. With `shell` the
    /// card's one pane starts with that shell (and `shell` becomes the
    /// recorded preferred shell, same as choosing a shell for a new Terminal
    /// Group); `nil` keeps the preferred shell. Nothing starts: user add paths
    /// use `addCanvasTerminal`, or call `startCanvasTerminalCard` once the
    /// card has its final place.
    @discardableResult
    func addCanvasStoppedTerminal(_ id: CanvasID, shell: TerminalShell? = nil) -> CanvasCardID? {
        guard let board = canvas.boards[id], board.cards.count < CanvasLimits.cards,
            let name = TerminalGroupName("Terminal")
        else { return nil }
        var cardID: CanvasCardID?
        performCanvasEdit(board) {
            let paneID = SavedTerminalPaneID()
            let pane = try SavedTerminalPaneRecord(
                id: paneID, explicitUserName: nil, themeColor: nil,
                kind: .ordinaryShell,
                launchProfile: newOrdinaryShellLaunchProfile(shell: shell))
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: name,
                root: .pane(paneID), focusedPaneID: paneID, panes: [pane])
            let snapshot = try terminal.insertStoppedSavedGroup(record, ensemble: true)
            _ = try terminal.perform(.detachDeletedSavedLayout(record.id))
            _ = try terminal.perform(.parkGroup(snapshot.id))
            cardID = try board.add(
                title: snapshot.name.rawValue, content: .terminal(groupID: snapshot.id))
        }
        return cardID
    }

    /// Starts the shell of a stopped terminal card the user just added (or
    /// made with Start Terminal Here), doing what the card's Start Shell does
    /// but with no card view. When the card can show the terminal now (its
    /// board is the visible presenter and the zoom shows live content) the
    /// card takes the lease and keyboard focus, and the shell starts in it.
    /// Otherwise the shell starts in the background, the card is selected,
    /// and the view and focus do not move; the card shows the terminal when
    /// it is next in view. A pane that is not stopped and available is left.
    func startCanvasTerminalCard(_ cardID: CanvasCardID, on boardID: CanvasID) {
        guard let board = canvas.boards[boardID],
            let card = board.cards.first(where: { $0.id == cardID }),
            case .terminal(let groupID) = card.content,
            let pane = terminal.terminalGroup(groupID)?.panes.first,
            pane.status == .stopped, pane.startAvailability == .available
        else { return }
        let permits = canvasResources[boardID]?.permitsLiveContent == true
        if permits { claimCanvasTerminalLease(groupID, for: boardID) }
        let mode = CanvasTerminalAddStart.mode(
            permitsLiveContent: permits,
            faceShowsLiveContent: CanvasZoomFace(scale: board.viewport.scale).showsLiveContent,
            holdsLease: canvasTerminalOwners[groupID] == boardID)
        if mode == .foreground {
            let focusedBefore = board.focusedCardID
            let activeBefore = board.contentIsActive
            board.focus(cardID)
            // Only when the board is the focused editor group's tab: a
            // foreground start otherwise reveals the group as an editor tab.
            if selectedTerminalGroupID == groupID {
                _ = try? terminal.perform(.revealGroup(groupID))
                startTerminalPane(pane.id)
                return
            }
            board.focusedCardID = focusedBefore
            board.contentIsActive = activeBefore
        }
        board.select([cardID])
        startTerminalPane(pane.id, background: true)
    }
    /// Creates a fresh stopped ordinary-shell Terminal Group for a card whose
    /// previously referenced group no longer exists, keeping the card's `id`
    /// and `rect` (so its position is preserved) and only replacing its
    /// content and title. Mirrors `addCanvasStoppedTerminal`'s record
    /// construction, but updates the existing card in place instead of
    /// adding a new one. The button is an explicit user action, so the
    /// shell then starts (`startCanvasTerminalCard`).
    func startTerminalHere(_ cardID: CanvasCardID, on boardID: CanvasID) {
        guard let board = canvas.boards[boardID],
            let name = TerminalGroupName("Terminal")
        else { return }
        performCanvasEdit(board) {
            let paneID = SavedTerminalPaneID()
            let pane = try SavedTerminalPaneRecord(
                id: paneID, explicitUserName: nil, themeColor: nil,
                kind: .ordinaryShell,
                launchProfile: newOrdinaryShellLaunchProfile(shell: nil))
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: name,
                root: .pane(paneID), focusedPaneID: paneID, panes: [pane])
            let snapshot = try terminal.insertStoppedSavedGroup(record, ensemble: true)
            _ = try terminal.perform(.detachDeletedSavedLayout(record.id))
            _ = try terminal.perform(.parkGroup(snapshot.id))
            try board.edit { document in
                guard let index = document.cards.firstIndex(where: { $0.id == cardID }) else {
                    throw CanvasError.invalidDocument
                }
                document.cards[index].content = .terminal(groupID: snapshot.id)
                document.cards[index].title = snapshot.name.rawValue
            }
        }
        startCanvasTerminalCard(cardID, on: boardID)
    }

    /// Who shows `groupID`'s terminal view now, seen from `board`.
    func canvasTerminalLeaseHolder(_ groupID: TerminalGroupID, board: CanvasID)
        -> CanvasTerminalLeaseHolder
    {
        if let owner = canvasTerminalOwners[groupID] {
            return owner == board ? .thisBoard : .otherBoard
        }
        let resource = EditorTabResource.terminalGroup(groupID: groupID)
        let shownInTab = editorLayout.groupIDs.contains { editorGroupID in
            guard let group = editorLayout.group(id: editorGroupID),
                let selected = group.selectedTabID
            else { return false }
            return group.tabs.contains { $0.id == selected && $0.resource == resource }
        }
        return shownInTab ? .editorTab : .none
    }

    /// The groups whose terminal is on an Ensemble the user can see: the
    /// lease holders, and every terminal card on a presented board (a card
    /// culled or zoomed out still lives there). The Terminals panel and the
    /// tab switcher label these "On an Ensemble", not "Hidden".
    var canvasCardTerminalGroupIDs: Set<TerminalGroupID> {
        var ids = Set(canvasTerminalOwners.keys)
        for (boardID, resources) in canvasResources where resources.isPresented {
            for card in canvas.boards[boardID]?.cards ?? [] {
                if case .terminal(let groupID) = card.content { ids.insert(groupID) }
            }
        }
        return ids
    }

    /// Reveals a terminal where it lives. A group whose own editor tab shows
    /// it is selected there. A group with a card on an open Ensemble shows
    /// that Ensemble and focuses the card, so the card (not a new editor tab)
    /// shows the terminal. Every other group reveals as an editor tab
    /// (`revealTerminalGroup`, which move and undo flows keep using).
    func revealTerminalGroupWhereItLives(_ groupID: TerminalGroupID) {
        let hasOwnTab = editorLayout.tab(matching: .terminalGroup(groupID: groupID)) != nil
        if !(hasOwnTab && canvasTerminalOwners[groupID] == nil),
            let (board, cardID) = canvasCard(showing: groupID)
        {
            presentCanvasBoard(board)
            focusCanvasCard(cardID, in: board)
            return
        }
        revealTerminalGroup(groupID)
    }

    /// The open board and card that show `groupID`: the lease holder first,
    /// then the board on screen, then any open board.
    private func canvasCard(showing groupID: TerminalGroupID) -> (CanvasBoardState, CanvasCardID)? {
        let content = CanvasCardContent.terminal(groupID: groupID)
        let preferred = [canvasTerminalOwners[groupID], selectedCanvasID].compactMap(\.self)
        let boards =
            preferred.compactMap { canvas.boards[$0] }
            + canvas.boards.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        for board in boards {
            if let card = board.cards.first(where: { $0.content == content }) {
                return (board, card.id)
            }
        }
        return nil
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
    /// An agent's `node_remove` on a terminal node (Agent control already
    /// allowed it). Stops the process, closes the group, and removes the card
    /// and its edges. It asks nothing and posts no notice: the user's approval,
    /// when Ask applies, came before this call. Edit > Undo restores the node.
    /// A failure throws to the agent and shows no alert.
    func removeCanvasTerminalCardForAgent(_ id: CanvasID, cardID: CanvasCardID) throws {
        guard let board = canvas.boards[id],
            let card = board.cards.first(where: { $0.id == cardID }),
            case .terminal(let groupID) = card.content
        else { throw CanvasError.unavailable }
        try closeTerminalGroupWithoutConfirmation(groupID)
        movedTerminalCardSourceGroups.removeValue(forKey: groupID)
        pendingCanvasTerminalRemoval = nil
        board.selection = [cardID]
        removeCanvasCards(id)
    }

    func finishCanvasTerminalRemoval() {
        guard let (id, cardID, groupID) = pendingCanvasTerminalRemoval,
            terminal.terminalGroup(groupID) == nil
        else { return }
        pendingCanvasTerminalRemoval = nil
        movedTerminalCardSourceGroups.removeValue(forKey: groupID)
        guard let board = canvas.boards[id] else { return }
        board.selection = [cardID]
        removeCanvasCards(id)
    }
}
