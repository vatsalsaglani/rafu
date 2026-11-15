import SwiftUI

extension TerminalPaneThemeColor {
    fileprivate static let presets: [TerminalPaneThemeColor] = [
        .accent, .info, .success, .warning, .error, .muted,
    ]

    fileprivate var displayName: String {
        switch self {
        case .accent: "Accent"
        case .info: "Blue"
        case .success: "Green"
        case .warning: "Amber"
        case .error: "Red"
        case .muted: "Gray"
        }
    }
}

extension RafuThemePalette {
    /// Swatch colour for a pane theme-colour preset.
    fileprivate func swatch(for color: TerminalPaneThemeColor) -> Color {
        switch color {
        case .accent: accent
        case .info: info
        case .success: success
        case .warning: warning
        case .error: error
        case .muted: textMuted
        }
    }
}

/// A 6 pt session-colour dot beside a name. Colour is never the only carrier:
/// the colour name is in the row's accessibility value.
private struct TerminalColorDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// The terminals panel (terminal-manager.md T-B): every live terminal
/// session in creation order, whether or not it currently has a tab. Sessions
/// outlive their tabs (T-A) — hiding a row hides its tab, closing it
/// terminates the shell.
///
/// Requires an open folder: `WorkspaceWindowView` only renders the utility
/// panel when `session.descriptor != nil, session.navigatorMode != .files`.
/// Terminals spawn in the workspace root, and the empty-window canvas
/// already offers Open Folder, so this view never needs its own
/// no-workspace state.
struct WorkspaceTerminalsPanelView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
    /// Inline rename state (terminal-manager.md T-D) lives on the PANEL, not
    /// the row: rows are recreated every render from `TerminalsPanelModel
    /// .rows`, so holding the in-progress text on a row would lose it (or
    /// the field's focus) across any unrelated re-render. Only one row can
    /// be renaming at a time.
    @State private var renamingID: UUID?
    @State private var renameText = ""
    /// `nil` means the probe has not resolved yet — the launcher shows pending
    /// rows for that state rather than an empty list (UX-03). Resolved-empty
    /// and still-probing must never look the same.
    @State private var agentTerminalOptions: [AgentTerminalOption]?
    /// Bumped by the launcher's explicit "Check Again": the probe spawns real
    /// CLIs, so it runs once per `.task` identity and never per render.
    @State private var agentProbeToken = 0
    @State private var renamingGroupID: TerminalGroupID?
    @State private var groupRenameText = ""
    @State private var renamingPaneID: TerminalPaneID?
    @State private var paneRenameText = ""
    /// The native list's single selection: the keyboard cursor. It follows
    /// the current terminal; Up and Down move it without opening anything,
    /// and Return or Space opens the selected row. Its tags come from
    /// `TerminalsPanelListModel` and never change when a title changes.
    @State private var listSelection: String?
    /// Per window: the Terminal Groups whose pane rows are hidden. Groups
    /// start expanded, so only collapsed ones are stored.
    @SceneStorage(TerminalsPanelListModel.expansionStorageKey)
    private var storedCollapsedGroups = ""
    /// Per window, so two windows keep their own open/closed choice for the
    /// Saved Terminal Groups section ("" none, "open", "closed").
    @SceneStorage("terminals.savedGroups.expanded") private var storedSavedExpansion = ""

    var body: some View {
        // Derived ONCE per body evaluation, never per-row inside a `ForEach`
        // closure: `presentedTerminalSessionIDs` walks every group's tabs
        // (`WorkspaceSession.swift`), so recomputing it per row would be
        // quadratic. Deriving once per render is an accepted cost at the
        // handful of sessions (≤~10) this panel expects.
        let rows = TerminalsPanelModel.hierarchyRows(
            groups: session.terminal.terminalGroups,
            presentedGroupIDs: session.presentedTerminalGroupIDs,
            currentGroupID: session.selectedTerminalGroupID,
            controllers: session.terminal.sessions,
            presentedLegacySessionIDs: session.presentedTerminalSessionIDs,
            currentLegacySessionID: session.currentTerminalSessionID,
            workspaceRoot: session.rootURL?.path,
            canvasOwnedGroupIDs: session.canvasCardTerminalGroupIDs
        )
        let managerItemCount = rows.count { $0.isManagerItem }
        let listRows = TerminalsPanelListModel.visibleRows(
            rows,
            collapsedGroupIDs: TerminalsPanelListModel.collapsedGroupIDs(
                fromStored: storedCollapsedGroups))
        let currentRowID = TerminalsPanelListModel.currentRowID(listRows)
        // No permanent Start Agent card and no divider: Start Agent is a
        // header action (and a button in the empty state) that opens the
        // same popover.
        VStack(spacing: 0) {
            header(count: managerItemCount)
            if rows.isEmpty {
                emptyState
                savedOnlyList
            } else {
                terminalList(listRows)
            }
        }
        // Load-bearing per AGENTS' panel-top-alignment rule (see
        // `GitInspectorView`'s identical comment): `.frame(maxHeight:
        // .infinity)` defaults to CENTER alignment, so an under-filled tab
        // (few/no sessions) would float the header + list stack to the
        // vertical middle instead of pinning to the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The selection follows the terminal shown in the editor.
        .onChange(of: currentRowID, initial: true) { _, current in
            listSelection = TerminalsPanelListModel.selectionFollowingCurrent(
                current, selection: listSelection, rows: listRows)
        }
        .task(id: AgentProbeIdentity(root: session.rootURL, token: agentProbeToken)) {
            guard let root = session.rootURL else {
                agentTerminalOptions = []
                return
            }
            // Back to pending so a refresh shows the probe honestly instead of
            // leaving the previous answer on screen as if it were current.
            agentTerminalOptions = nil
            let loaded = await AgentTerminalLaunchService(
                workspaceRoot: root
            ).options()
            guard !Task.isCancelled else { return }
            agentTerminalOptions = loaded
        }
    }

    /// Pending rows until the probe resolves — one per known provider, so the
    /// section is never an empty list that later fills in silently.
    private var agentLauncherRows: [AgentLauncherRow] {
        guard let agentTerminalOptions else { return AgentLauncherModel.probingRows() }
        return AgentLauncherModel.rows(options: agentTerminalOptions)
    }

    private func header(count: Int) -> some View {
        RafuUtilityPanelHeader(
            title: "Terminals",
            context: {
                RafuPanelHeaderCount(
                    count: count,
                    accessibilityLabel: TerminalNaming.terminalCountLabel(count))
            },
            actions: {
                if session.rootURL != nil { agentStartControl(style: .headerIcon) }
                newTerminalControl
            }
        )
    }

    /// The Start Agent control. It stays a popover of SwiftUI rows, never a
    /// `Menu`: vendor marks draw at 1 x 1 pt inside `NSMenu`
    /// (`docs/references/agent-terminals.md`).
    private func agentStartControl(style: AgentStartMenuView.Style) -> some View {
        AgentStartMenuView(
            rows: agentLauncherRows,
            isProbing: agentTerminalOptions == nil,
            style: style,
            launch: launchAgent,
            refresh: { agentProbeToken += 1 }
        )
    }

    /// One split pull-down: the "+" starts the default shell, the arrow lists
    /// the shells. With a single shell there is nothing to list, so it stays
    /// a plain "+" button. Both paths are explicit user actions.
    @ViewBuilder
    private var newTerminalControl: some View {
        let shells = session.availableTerminalShells
        if shells.count >= 2 {
            Menu {
                ForEach(shells) { shell in
                    Button(TerminalNaming.shellMenuTitle(for: shell, among: shells)) {
                        session.newTerminalTab(shell: shell)
                    }
                    .help(shell.path)
                }
            } label: {
                Label("New Terminal", systemImage: "plus")
                    .labelStyle(.iconOnly)
            } primaryAction: {
                session.newTerminalTab()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New Terminal. Use the arrow to choose a shell.")
            .accessibilityLabel("New Terminal")
        } else {
            Button {
                session.newTerminalTab()
            } label: {
                Label("New Terminal", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("New Terminal")
            .accessibilityLabel("New Terminal")
        }
    }

    /// The launcher's only path to a spawn: an unavailable row cannot reach the
    /// launch service, because `launchableOption` gates on the row's state.
    private func launchAgent(_ row: AgentLauncherRow) {
        guard let options = agentTerminalOptions,
            let option = AgentLauncherModel.launchableOption(for: row, in: options)
        else { return }
        launchAgentTerminal(option)
    }

    private func launchAgentTerminal(_ option: AgentTerminalOption) {
        guard let root = session.rootURL,
            let specification = try? AgentTerminalLaunchService(
                workspaceRoot: root
            ).specification(
                option: option,
                model: option.defaultModel,
                startingDirectory: root)
        else { return }
        session.openAgentTerminal(spec: specification)
    }

    /// Compact sidebar empty state with the two ways to start: a shell or an
    /// agent. The keyboard shortcuts stay in the message.
    private var emptyState: some View {
        RafuPanelEmptyState(
            icon: "terminal",
            title: "No Terminals",
            message: "Start a shell or an agent here. Control-backtick toggles a terminal.",
            compact: true
        ) {
            HStack(spacing: RafuMetrics.space2) {
                Button("New Terminal") { session.newTerminalTab() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("New Terminal (⌃⇧`)")
                if session.rootURL != nil { agentStartControl(style: .emptyStateButton) }
            }
        }
    }

    /// The native list (direction A, "Quiet list"): one row per group, its
    /// panes as indented rows under it while it is expanded, one row per
    /// legacy session, then the Saved Terminal Groups section. One Tab stop;
    /// Up and Down move the selection, Return or Space opens, Left and Right
    /// close and open a group (`TerminalsPanelListModel.action`).
    private func terminalList(_ listRows: [TerminalsPanelListModel.Row]) -> some View {
        List(selection: $listSelection) {
            ForEach(listRows) { row in
                listRow(row)
                    .tag(row.id)
                    .listRowInsets(TerminalPanelRowMetrics.listRowInsets)
                    .listRowSeparator(.hidden)
            }
            savedSection
        }
        .terminalsPanelListStyle(theme: theme)
        .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow]) { press in
            handleKey(press.key, rows: listRows)
        }
        .accessibilityLabel("Terminals")
    }

    /// With no terminal rows, the Saved section is the panel's one pinned
    /// footer under the empty state, so it keeps the hairline above it. Its
    /// list is sized to its rows (`footerHeight`), so the empty state keeps
    /// the remaining space and stays centred in it.
    private var savedOnlyList: some View {
        let state = TerminalGroupSavedLayoutsPresentation.state(
            hasWorkspace: session.rootURL != nil, isLoading: session.isTerminalGroupStoreLoading,
            error: session.terminalGroupStoreError, recordCount: session.savedTerminalGroups.count)
        let isExpanded = isSavedSectionExpanded(state)
        return VStack(spacing: 0) {
            Divider().overlay(theme.palette.borderSubtle)
            List(selection: $listSelection) {
                savedSection
            }
            .terminalsPanelListStyle(theme: theme)
            .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow]) { press in
                handleKey(press.key, rows: [])
            }
            .accessibilityLabel("Saved Terminal Groups")
            .frame(
                height: TerminalGroupSavedLayoutsPresentation.footerHeight(
                    state: state, isExpanded: isExpanded,
                    recordCount: session.savedTerminalGroups.count))
        }
        .padding(.bottom, RafuMetrics.space1)
    }

    private var savedSection: some View {
        TerminalGroupSavedLayoutsSection(
            session: session, storedExpansion: $storedSavedExpansion, selection: $listSelection)
    }

    private func isSavedSectionExpanded(_ state: TerminalGroupSavedLayoutsPresentation.State)
        -> Bool
    {
        TerminalGroupSavedLayoutsPresentation.isExpanded(
            userChoice: TerminalGroupSavedLayoutsPresentation.userChoice(
                fromStored: storedSavedExpansion),
            state: state)
    }

    @ViewBuilder
    private func listRow(_ row: TerminalsPanelListModel.Row) -> some View {
        switch row {
        case .group(let group, let panes, let isDisclosable, let isExpanded):
            TerminalGroupManagerRowView(
                row: group,
                panes: panes,
                isSelected: listSelection == row.id,
                isDisclosable: isDisclosable,
                isExpanded: isExpanded,
                isRenaming: renamingGroupID == group.id,
                renameText: $groupRenameText,
                paneActions: paneActions,
                select: { listSelection = row.id },
                setExpanded: { expand in setGroup(group.id, expanded: expand) },
                reveal: { session.revealTerminalGroupWhereItLives(group.id) },
                hide: { session.hideTerminalGroup(group.id) },
                beginRename: { beginGroupRename(group) },
                commitRename: { commitGroupRename(group.id) },
                cancelRename: cancelGroupRename,
                saveLayout: session.isTerminalGroupStoreMutationInFlight
                    ? nil : { session.requestTerminalGroupSaveAs(group.id) },
                updateSavedLayout: session.isTerminalGroupStoreMutationInFlight
                    || !group.isSaved
                    ? nil : { session.requestTerminalGroupSave(group.id) },
                startAll: group.hasRestartablePane
                    ? { session.startAllRestartableTerminalPanes(in: group.id) } : nil,
                close: { session.requestTerminalGroupClose(group.id) },
                session: session
            )
        case .pane(let pane):
            TerminalPaneRowView(
                row: pane,
                agentStatus: paneAgentStatus(for: pane),
                isSelected: listSelection == row.id,
                isRenaming: renamingPaneID == pane.id,
                renameText: $paneRenameText,
                select: { listSelection = row.id },
                actions: paneActions
            )
        case .legacy(let legacy, let isCurrent):
            TerminalSessionRowView(
                row: legacy,
                isCurrent: isCurrent,
                isSelected: listSelection == row.id,
                isRenaming: renamingID == legacy.id,
                renameText: $renameText,
                select: { listSelection = row.id },
                reveal: { session.revealTerminalSession(legacy.id) },
                hide: legacy.isParked
                    ? nil : { session.hideTerminalSession(legacy.id) },
                close: { session.closeTerminalSession(legacy.id) },
                beginRename: { beginRename(legacy) },
                commitRename: { commitRename(legacy.id) },
                cancelRename: cancelRename,
                resetName: { session.renameTerminalSession(legacy.id, to: nil) },
                setColor: { color in session.setTerminalSessionColor(legacy.id, color) }
            )
        }
    }

    private func paneAgentStatus(for pane: TerminalsPanelModel.TerminalPaneRow) -> AgentCardStatus?
    {
        guard
            let snapshot = session.terminal.terminalGroup(pane.groupID)?.panes.first(where: {
                $0.id == pane.id
            })
        else { return nil }
        return CanvasCardCommands.agentCardStatus(pane: snapshot, in: session)
    }

    // MARK: Keyboard and expansion

    /// Whether any inline rename field is open. Keys then belong to the field.
    private var isRenaming: Bool {
        renamingID != nil || renamingGroupID != nil || renamingPaneID != nil
    }

    private func handleKey(_ key: KeyEquivalent, rows: [TerminalsPanelListModel.Row])
        -> KeyPress.Result
    {
        guard !isRenaming else { return .ignored }
        let mapped: TerminalsPanelListModel.Key
        switch key {
        case .return: mapped = .returnKey
        case .space: mapped = .space
        case .leftArrow: mapped = .leftArrow
        case .rightArrow: mapped = .rightArrow
        default: return .ignored
        }
        let savedState = TerminalGroupSavedLayoutsPresentation.state(
            hasWorkspace: session.rootURL != nil, isLoading: session.isTerminalGroupStoreLoading,
            error: session.terminalGroupStoreError, recordCount: session.savedTerminalGroups.count)
        let action = TerminalsPanelListModel.action(
            for: mapped, selection: listSelection, rows: rows,
            isSavedExpanded: isSavedSectionExpanded(savedState))
        switch action {
        case .open(let id):
            openRow(id, rows: rows)
        case .expand(let groupID):
            setGroup(groupID, expanded: true)
        case .collapse(let groupID):
            setGroup(groupID, expanded: false)
        case .select(let id):
            listSelection = id
        case .setSavedExpanded(let expand):
            storedSavedExpansion = expand ? "open" : "closed"
        case .none:
            return .ignored
        }
        return .handled
    }

    /// Return and Space: the same action as a click on the row.
    private func openRow(_ id: String, rows: [TerminalsPanelListModel.Row]) {
        if TerminalsPanelListModel.isSavedLayoutRowID(id) {
            guard !session.isTerminalGroupStoreMutationInFlight,
                let record = session.savedTerminalGroups.first(where: {
                    TerminalsPanelListModel.savedRowID($0.id) == id
                })
            else { return }
            session.openSavedTerminalGroup(record.id)
            return
        }
        switch rows.first(where: { $0.id == id }) {
        case .group(let group, _, _, _): session.revealTerminalGroupWhereItLives(group.id)
        case .pane(let pane): paneActions.revealAndFocus(pane)
        case .legacy(let legacy, _): session.revealTerminalSession(legacy.id)
        case nil: break
        }
    }

    /// Writes the per-window expansion. A collapse first moves a selected
    /// pane of that group to the group row, so no hidden row stays selected.
    private func setGroup(_ groupID: TerminalGroupID, expanded: Bool) {
        let collapsed = TerminalsPanelListModel.collapsedGroupIDs(
            fromStored: storedCollapsedGroups)
        if !expanded {
            listSelection = TerminalsPanelListModel.selectionAfterCollapsing(
                groupID,
                paneIDs: session.terminal.terminalGroup(groupID)?.panes.map(\.id) ?? [],
                selection: listSelection)
        }
        let next = TerminalsPanelListModel.toggled(
            groupID, expand: expanded, in: collapsed,
            liveGroupIDs: Set(session.terminal.terminalGroups.map(\.id)))
        storedCollapsedGroups = TerminalsPanelListModel.storedValue(collapsedGroupIDs: next)
    }

    /// Every pane action names its exact pane; rename state stays on the
    /// panel (`renamingPaneID`, `paneRenameText`).
    private var paneActions: TerminalPaneActions {
        TerminalPaneActions(
            revealAndFocus: { pane in
                session.revealTerminalGroupWhereItLives(pane.groupID)
                session.focusTerminalPane(pane.id, in: pane.groupID)
            },
            close: { pane in session.closeTerminalPane(pane.id) },
            start: { pane in session.startTerminalPane(pane.id) },
            restart: { pane in session.restartTerminalPane(pane.id) },
            beginRename: { pane in beginPaneRename(pane.id, pane.name) },
            commitRename: { pane in commitPaneRename(pane.id) },
            cancelRename: cancelPaneRename,
            setColor: { pane, color in session.setTerminalPaneColor(pane.id, color) }
        )
    }

    private func beginGroupRename(_ group: TerminalsPanelModel.TerminalGroupRow) {
        groupRenameText = group.displayName
        renamingGroupID = group.id
    }

    private func commitGroupRename(_ groupID: TerminalGroupID) {
        session.renameTerminalGroup(groupID, to: groupRenameText)
        cancelGroupRename()
    }

    private func cancelGroupRename() {
        renamingGroupID = nil
        groupRenameText = ""
    }

    private func beginPaneRename(_ paneID: TerminalPaneID, _ name: String) {
        paneRenameText = name
        renamingPaneID = paneID
    }

    private func commitPaneRename(_ paneID: TerminalPaneID) {
        session.renameTerminalPane(paneID, to: paneRenameText)
        cancelPaneRename()
    }

    private func cancelPaneRename() {
        renamingPaneID = nil
        paneRenameText = ""
    }

    private func beginRename(_ row: TerminalSessionRow) {
        renameText = row.displayName
        renamingID = row.id
    }

    private func commitRename(_ id: UUID) {
        session.renameTerminalSession(id, to: renameText)
        renamingID = nil
        renameText = ""
    }

    private func cancelRename() {
        renamingID = nil
        renameText = ""
    }
}

/// `.task(id:)` identity for the agent probe: the workspace root plus a
/// user-refresh counter. Any other change to the view must NOT re-probe —
/// `options()` spawns one process per provider.
private struct AgentProbeIdentity: Equatable {
    let root: URL?
    let token: Int
}

/// The agent launcher (macOS redesign T1): one "Start Agent" control in place
/// of the old seven-tile grid. In a list it is a header icon button; with no
/// terminal it is a labelled button in the empty state. Both open the same
/// popover, whose first line says "Checking N agents…" or how many are ready.
///
/// The list is a popover of ordinary SwiftUI rows, not a `Menu`: menu content
/// is bridged to `NSMenuItem`, which draws an image at its own size, and the
/// vendored SVGs are authored `width="1em"` so `NSImage` reports 1×1 pt there
/// and every mark drew as a dot (see `docs/references/agent-terminals.md`).
/// Rows therefore use `AgentIconView` (the shared agent identity mark) for every provider.
/// Opening the list starts nothing; only choosing a ready row launches.
private struct AgentStartMenuView: View {
    enum Style {
        case headerIcon
        case emptyStateButton
    }

    let rows: [AgentLauncherRow]
    let isProbing: Bool
    let style: Style
    let launch: (AgentLauncherRow) -> Void
    let refresh: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isPresented = false

    var body: some View {
        trigger
            .help("Start Agent: choose an agent CLI to start in a new terminal. \(statusLine).")
            .accessibilityLabel("Start Agent")
            .accessibilityValue(statusLine)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                menu
            }
    }

    @ViewBuilder
    private var trigger: some View {
        switch style {
        case .headerIcon:
            Button {
                isPresented = true
            } label: {
                Label("Start Agent", systemImage: AgentSymbols.agentTerminal)
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
        case .emptyStateButton:
            Button {
                isPresented = true
            } label: {
                Text("Start Agent")
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
    }

    /// "Checking 7 agents…" while probing, then how many are ready.
    private var statusLine: String {
        if isProbing { return AgentLauncherModel.checkingLine(agentCount: rows.count) }
        let ready = rows.count { $0.isLaunchable }
        return ready == 0 ? "No agent CLI found" : "\(ready) ready"
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RafuMetrics.space1) {
                Text("Start Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: RafuMetrics.space2)
                if isProbing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.bottom, RafuMetrics.space1)
            .accessibilityElement(children: .combine)
            ForEach(rows) { row in
                AgentLauncherMenuRow(
                    row: row,
                    launch: {
                        isPresented = false
                        launch(row)
                    })
            }
            Divider().overlay(theme.palette.borderSubtle)
            Button("Check Again") { refresh() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, RafuMetrics.space2)
                .padding(.vertical, RafuMetrics.space1)
                .disabled(isProbing)
                .help("Check installed agent CLIs again")
                .accessibilityLabel("Check installed agent CLIs again")
        }
        .padding(RafuMetrics.space2)
        .frame(width: 280)
    }
}

/// One provider row in the Start Agent list: icon, full name, state word. A
/// row that cannot launch is disabled, and its state is a word, a shape
/// (progress or warning glyph), and then dimming. The full reason is in the
/// tooltip and the accessibility label.
private struct AgentLauncherMenuRow: View {
    let row: AgentLauncherRow
    let launch: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: launch) {
            HStack(spacing: RafuMetrics.space2) {
                AgentIconView(cli: row.id, size: 16)
                    .frame(width: 18, height: 18)
                    .opacity(row.isLaunchable ? 1 : 0.55)
                    .accessibilityHidden(true)
                Text(row.displayName)
                    .font(.callout)
                    .foregroundStyle(
                        row.isLaunchable
                            ? theme.palette.textPrimary : theme.palette.textSecondary
                    )
                    .lineLimit(1)
                Spacer(minLength: RafuMetrics.space2)
                statusIndicator
                Text(row.stateLabel)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, RafuMetrics.space2)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(
                    cornerRadius: RafuMetrics.radiusDenseCard,
                    style: .continuous
                )
                .fill(isHovering && row.isLaunchable ? theme.palette.hover : Color.clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!row.isLaunchable)
        .onHover { isHovering = $0 }
        .help(row.tooltip)
        .accessibilityLabel(row.accessibilityLabel)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch row.state {
        case .probing:
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        case .ready:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(theme.palette.success)
                .accessibilityHidden(true)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.palette.warning)
                .accessibilityHidden(true)
        }
    }
}

/// The pane-level actions a group card hands to its pane chips (and, for a
/// one-pane group, merges into its own menu). Each closure names the exact
/// pane; the panel owns the rename state.
private struct TerminalPaneActions {
    let revealAndFocus: (TerminalsPanelModel.TerminalPaneRow) -> Void
    let close: (TerminalsPanelModel.TerminalPaneRow) -> Void
    let start: (TerminalsPanelModel.TerminalPaneRow) -> Void
    let restart: (TerminalsPanelModel.TerminalPaneRow) -> Void
    let beginRename: (TerminalsPanelModel.TerminalPaneRow) -> Void
    let commitRename: (TerminalsPanelModel.TerminalPaneRow) -> Void
    let cancelRename: () -> Void
    let setColor: (TerminalsPanelModel.TerminalPaneRow, TerminalPaneThemeColor?) -> Void
}

/// Shared geometry for the Terminals rows ("tuned rows", sidebar redesign):
/// no card fill and no border; a row's text starts on the sidebar's 10 pt
/// edge (4 pt outer inset + 6 pt row padding), a 16 pt status slot sits at
/// the trailing edge, and pane rows indent 22 pt.
private enum TerminalPanelRowMetrics {
    static let outerInset: CGFloat = 4
    static let rowPadding: CGFloat = 6
    static let radius: CGFloat = RafuMetrics.radiusDenseSelection
    static let statusSlot: CGFloat = 16
    static let iconSlot: CGFloat = 16
    static let twoLineHeight: CGFloat = 40
    static let paneRowHeight: CGFloat = 22
    static let paneIndent: CGFloat = 22
    /// The group chevron sits in the 8 pt before the identity icon, so a
    /// disclosable group keeps the same text edge as every other row.
    static let disclosureWidth: CGFloat = 8
    /// The list row owns the 4 pt outer inset; rows pad 6 pt inside, so the
    /// text starts on the 10 pt sidebar edge. 1 pt above and below keeps the
    /// 2 pt gap the stacked rows had.
    static let listRowInsets = EdgeInsets(
        top: 1, leading: outerInset, bottom: 1, trailing: outerInset)
}

extension View {
    /// The Terminals panel's native list: `.plain` like the Files tree (rows
    /// draw their own hover; no sidebar insets), no scroll background so the
    /// sidebar (or the frosted window) shows through, overlay scrollers, and
    /// the system selection tinted with the theme's `selection` token.
    fileprivate func terminalsPanelListStyle(theme: RafuTheme) -> some View {
        listStyle(.plain)
            .environment(\.defaultMinListRowHeight, TerminalPanelRowMetrics.paneRowHeight)
            .scrollContentBackground(.hidden)
            .background(OverlayScrollerConfigurator(knobStyle: theme.isDark ? .light : .dark))
            .tint(theme.palette.selection)
    }
}

/// Under Increase Contrast the selected row also gets a `borderStrong`
/// hairline, so selection never rests on a low-contrast fill alone.
private struct TerminalRowSelectionHairline: ViewModifier {
    let isSelected: Bool

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if isSelected && contrast == .increased {
                RoundedRectangle(cornerRadius: TerminalPanelRowMetrics.radius, style: .continuous)
                    .strokeBorder(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The 16 pt trailing status glyph. An agent pane uses `AgentActivityGlyph`
/// (spinning arc while working, a different symbol per state); a shell uses
/// `TerminalNaming.shellStatusSymbol`. Every state has its own shape, and the
/// row's second line adds a word for every abnormal state, so status never
/// depends on colour. Decorative: the row's accessibility value speaks it.
private struct TerminalStatusGlyph: View {
    let agentStatus: AgentCardStatus?
    let paneStatus: TerminalPaneStatus
    let hasAttention: Bool

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            if let agentStatus {
                AgentActivityGlyph(status: agentStatus, size: 10)
            } else {
                Image(
                    systemName: TerminalNaming.shellStatusSymbol(
                        paneStatus: paneStatus, hasAttention: hasAttention)
                )
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            }
        }
        .frame(
            width: TerminalPanelRowMetrics.statusSlot, height: TerminalPanelRowMetrics.statusSlot
        )
        .accessibilityHidden(true)
    }

    private var tint: Color {
        if hasAttention { return theme.palette.warning }
        return paneStatus == .live ? theme.palette.accent : theme.palette.textMuted
    }
}

/// The trailing `ellipsis` menu shown over the status slot on hover and on
/// the list selection. The same items are in the row's context menu, so nothing
/// is reachable only by hovering.
private struct TerminalRowActionsMenu<Items: View>: View {
    let label: String
    let isVisible: Bool
    @ViewBuilder let items: Items

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isVisible ? 1 : 0)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// One Terminal Group as a two-line row: the identity mark (the focused
/// pane's agent mark, else a terminal glyph), the title over the second line
/// (abnormal status word · agent · folder · placement), and a 16 pt status
/// glyph. The drag grip and the ⋯ menu are hover/selection overlays, so they
/// take no width from the title. A group with more than one pane is a
/// disclosure row: its chevron sits before the identity icon, and the panel
/// lists its panes as indented list rows under it while it is expanded. The
/// group row is the drag source.
///
/// Selection is the list's own selection (tinted with the theme `selection`
/// token, plus a hairline under Increase Contrast); the amber border is
/// reserved for attention. The current group is semibold.
private struct TerminalGroupManagerRowView: View {
    let row: TerminalsPanelModel.TerminalGroupRow
    /// This group's panes, in pane order (`TerminalsPanelModel.hierarchyRows`).
    let panes: [TerminalsPanelModel.TerminalPaneRow]
    /// Whether the list selection is this row.
    let isSelected: Bool
    /// More than one pane: the row has a chevron and pane rows.
    let isDisclosable: Bool
    let isExpanded: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let paneActions: TerminalPaneActions
    let select: () -> Void
    let setExpanded: (Bool) -> Void
    let reveal: () -> Void
    let hide: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let saveLayout: (() -> Void)?
    let updateSavedLayout: (() -> Void)?
    let startAll: (() -> Void)?
    let close: () -> Void
    /// Reads the focused pane's agent identity and status, and marks this
    /// row's drag in flight (the dimmed source ghost) and its kind
    /// (same-window hover-label hint). Never read to decide what a drop does.
    let session: WorkspaceSession

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    @FocusState private var isRenameFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var scaledMinimumHeight: CGFloat =
        TerminalPanelRowMetrics.twoLineHeight
    /// This row's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the row's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    var body: some View {
        let focused = focusedPane
        let agentStatus = focused.flatMap {
            CanvasCardCommands.agentCardStatus(pane: $0, in: session)
        }
        surface(content(focused: focused, agentStatus: agentStatus))
            // One tap handler (docs/references/swiftui-macos-click-latency.md):
            // select and reveal at once; the second click of a double-click
            // also renames. Not a `Button`, so `.onDrag` keeps the press.
            .onTapGesture {
                select()
                reveal()
                if TabClickIntent.current() == .selectAndRename { beginRename() }
            }
            .onHover { isHovering = $0 }
            // The ⋯ menu is hover- and selection-revealed; the same items are
            // here, so nothing is reachable only by hovering.
            .contextMenu { actions }
            .help(tooltip)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal Group, \(row.rowTitle)")
            .accessibilityValue(accessibilityValue(agentStatus))
            .accessibilityAddTraits(row.isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { reveal() }
            .accessibilityAction(named: "Reveal") { reveal() }
            .accessibilityActions {
                if isDisclosable {
                    Button(isExpanded ? "Collapse" : "Expand") { setExpanded(!isExpanded) }
                }
            }
            .accessibilityAction(named: "Close Group") { close() }
    }

    private func content(focused: TerminalPaneSnapshot?, agentStatus: AgentCardStatus?)
        -> some View
    {
        HStack(spacing: 8) {
            identityIcon(focused)
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                Text(subtitle(agentStatus))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            TerminalStatusGlyph(
                agentStatus: agentStatus,
                paneStatus: groupPaneStatus,
                hasAttention: row.attentionCount > 0
            )
            .opacity(showsActions ? 0 : 1)
        }
        .overlay(alignment: .trailing) {
            TerminalRowActionsMenu(
                label: "Actions for \(row.displayName)", isVisible: showsActions
            ) { actions }
        }
        .overlay(alignment: .leading) {
            if isDisclosable {
                disclosureChevron
            } else {
                // The whole row is the drag source; the grip is only a hint.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(theme.palette.textMuted)
                    .offset(x: -TerminalPanelRowMetrics.rowPadding - 1)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The group's disclosure chevron, in the 8 pt before the identity icon.
    /// Its own tap wins over the row's, so it only opens or closes the panes.
    /// No animation: a disclosure is a frequent, immediate action. The row's
    /// accessibility value and its Expand/Collapse action carry the state.
    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(theme.palette.textSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(
                width: TerminalPanelRowMetrics.disclosureWidth,
                height: TerminalPanelRowMetrics.iconSlot + 8
            )
            .contentShape(.rect)
            .onTapGesture { setExpanded(!isExpanded) }
            .offset(x: -TerminalPanelRowMetrics.disclosureWidth)
            .help(isExpanded ? "Collapse Panes" : "Expand Panes")
            .accessibilityHidden(true)
    }

    /// Geometry, hover fill, the shared manager-row resolver (attention
    /// border), the contrast hairline for the selected row, and the drag
    /// source. The selection fill is the list's own selection.
    private func surface(_ content: some View) -> some View {
        content
            .padding(.horizontal, TerminalPanelRowMetrics.rowPadding)
            .padding(.vertical, 4)
            .frame(
                maxWidth: .infinity,
                minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                    base: TerminalPanelRowMetrics.twoLineHeight,
                    scaledHeight: scaledMinimumHeight),
                alignment: .leading
            )
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: TerminalPanelRowMetrics.radius, style: .continuous)
                    .fill(isHovering && !isSelected ? theme.palette.hover : Color.clear)
            )
            // `isCurrent: false`: the list draws the selection fill, so the
            // resolver contributes only the attention border here.
            .rafuTerminalSurfaceBorder(
                context: .managerRow(isCurrent: false, needsAttention: row.attentionCount > 0),
                radius: TerminalPanelRowMetrics.radius
            )
            .modifier(TerminalRowSelectionHairline(isSelected: isSelected))
            .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
            // Carries only the group's id over the private `rafuEnsembleDrag`
            // type, exactly like an Agent History row — never a title, path, or
            // transcript. Dropped on an Ensemble board centre, a one-pane group
            // (running or stopped) moves there with `moveTerminalGroupToEnsemble`
            // (lease, keeps running); the existing refusals (more than one pane,
            // already on a board, board full) apply unchanged at drop time.
            .onDrag(
                {
                    session.beginDragSourceTracking(dragToken)
                    session.activeEnsembleDragHint = .terminalGroup
                    return CanvasBoardDragPayload(terminalGroupID: row.id).makeItemProvider()
                },
                preview: {
                    RafuDragPreviewLabel(
                        icon: Image(systemName: "rectangle.3.group"), title: row.rowTitle)
                }
            )
    }

    // MARK: Parts

    private var titleLine: some View {
        HStack(spacing: 5) {
            if isRenaming {
                // Focused on appear: inside a `List` the field does not take
                // focus by itself, and the list would keep the keys.
                TextField("Group name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isRenameFieldFocused)
                    .onAppear { isRenameFieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
            } else {
                if let color = row.sessionColor {
                    TerminalColorDot(color: theme.palette.color(for: color))
                }
                Text(row.rowTitle)
                    .font(.system(size: 13, weight: row.isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The placement glyph stays beside the title; the second line also
            // says it in a word ("Ensemble", "Hidden").
            if row.isCanvasOwned {
                Image(systemName: CanvasBoardState.ensembleSymbol)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityLabel("On an Ensemble")
            } else if row.isParked {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityLabel("Hidden")
            }
            if row.isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The focused pane's agent mark, else the terminal glyph: 14 pt in a
    /// 16 pt slot, no well.
    private func identityIcon(_ pane: TerminalPaneSnapshot?) -> some View {
        Group {
            if let provider = pane.flatMap({ session.terminal.terminalController(for: $0.id) })?
                .resolvedAgentProvider
            {
                AgentIconView(cli: provider, size: 14)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(width: TerminalPanelRowMetrics.iconSlot, height: TerminalPanelRowMetrics.iconSlot)
        .accessibilityHidden(true)
    }

    /// The ⋯ menu covers the status glyph on hover or when the list selects
    /// the row (the keyboard cursor).
    private var showsActions: Bool { isHovering || isSelected }

    /// The pane status the group's shell glyph shows: the focused pane's
    /// for one pane; for more, live while any pane runs.
    private var groupPaneStatus: TerminalPaneStatus {
        if panes.count == 1, let pane = panes.first { return pane.status }
        return row.livePaneCount > 0 ? .live : .stopped
    }

    private func subtitle(_ agentStatus: AgentCardStatus?) -> String {
        let statusWord: String? =
            if panes.count == 1, let pane = panes.first {
                TerminalNaming.abnormalStatusWord(
                    agentStatus: agentStatus, paneStatus: pane.status,
                    hasAttention: pane.hasAttention)
            } else {
                TerminalNaming.abnormalGroupStatusWord(
                    attentionCount: row.attentionCount, livePaneCount: row.livePaneCount)
            }
        return TerminalNaming.panelSubtitle(
            statusWord: statusWord,
            context: row.context,
            placement: TerminalNaming.panelPlacement(
                isCanvasOwned: row.isCanvasOwned, isParked: row.isParked))
    }

    /// The full title and the full folder path; the row truncates both.
    private var tooltip: String {
        guard let path = row.fullPath else { return row.rowTitle }
        return row.rowTitle + "\n" + (path as NSString).abbreviatingWithTildeInPath
    }

    /// The group's items; a one-pane group also offers its pane's shell and
    /// colour items, since it shows no pane row.
    @ViewBuilder
    private var actions: some View {
        Button("Rename…", action: beginRename)
        if let saveLayout { Button("Save Layout…", action: saveLayout) }
        if let updateSavedLayout {
            Button("Update Saved Layout", action: updateSavedLayout)
        }
        if let startAll {
            Button("Start All Panes", action: startAll)
                .help(
                    "Starts every pane that can be restarted: "
                        + "stopped panes and exited shells.")
        }
        if panes.count == 1, let pane = panes.first {
            Divider()
            TerminalPaneMenuItems(row: pane, actions: paneActions, includesPaneIdentity: false)
        }
        if isDisclosable {
            Divider()
            Button(isExpanded ? "Collapse Panes" : "Expand Panes") { setExpanded(!isExpanded) }
        }
        Divider()
        Button("Reveal", action: reveal)
        if !row.isParked { Button("Hide Group", action: hide) }
        Divider()
        Button("Close Group", role: .destructive, action: close)
    }

    // MARK: Derived

    private var focusedPane: TerminalPaneSnapshot? {
        guard let group = session.terminal.terminalGroup(row.id) else { return nil }
        return group.panes.first { $0.id == group.focusedPaneID } ?? group.panes.first
    }

    /// The full status in words, in every state (the glyph is hidden). A
    /// disclosure row says "Expanded" or "Collapsed" first.
    private func accessibilityValue(_ agentStatus: AgentCardStatus?) -> String {
        var values: [String] = []
        if isDisclosable { values.append(isExpanded ? "Expanded" : "Collapsed") }
        values += [row.context, TerminalNaming.paneCountLabel(row.paneCount), row.stateLabel]
        if let agentStatus { values.append(agentStatus.word) }
        if row.livePaneCount > 0 { values.append("\(row.livePaneCount) live") }
        if row.isCurrent { values.append("Current") }
        if row.isCanvasOwned {
            values.append("On an Ensemble")
        } else if row.isParked {
            values.append("Hidden")
        }
        if row.isSaved { values.append("Saved") } else { values.append("Unsaved") }
        if row.attentionCount > 0 {
            values.append(TerminalNaming.attentionLabel(row.attentionCount))
        }
        if let color = row.sessionColor { values.append("Color \(color.displayName)") }
        return values.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A pane's menu items, shared by its chip's ⋯ menu, its chip's context
/// menu, and (without the identity items) a one-pane group card's menu.
private struct TerminalPaneMenuItems: View {
    let row: TerminalsPanelModel.TerminalPaneRow
    let actions: TerminalPaneActions
    /// Reveal and Focus, Rename… and Close Pane. A one-pane group card
    /// leaves them out: its own Reveal, Rename… and Close Group cover them.
    var includesPaneIdentity = true

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if row.canStart { Button("Start Shell") { actions.start(row) } }
        if row.canRestart { Button("Restart Shell") { actions.restart(row) } }
        if includesPaneIdentity {
            Button("Reveal and Focus") { actions.revealAndFocus(row) }
            Button("Rename…") { actions.beginRename(row) }
        }
        Menu("Color") {
            ForEach(TerminalPaneThemeColor.presets, id: \.self) { color in
                Button {
                    actions.setColor(row, color)
                } label: {
                    Label {
                        Text(color.displayName)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(theme.palette.swatch(for: color))
                    }
                }
            }
            Divider()
            Button("No Color") { actions.setColor(row, nil) }
        }
        if includesPaneIdentity {
            Button("Close Pane", role: .destructive) { actions.close(row) }
        }
    }
}

/// One pane of a multi-pane group as an indented 22 pt row: its ordinal (the
/// pane order, from 1), the colour dot, the name, the folder when it differs
/// from the group's, an abnormal status word, and the 16 pt status glyph.
/// It is its own list row under its group. Clicking (or Return on the
/// selected row) reveals the group and focuses the pane. The ⋯ menu (hover
/// and selection) and the context menu carry the pane's menu; renaming swaps
/// the name for a field. The focused pane is semibold with the `.isSelected`
/// trait.
private struct TerminalPaneRowView: View {
    let row: TerminalsPanelModel.TerminalPaneRow
    let agentStatus: AgentCardStatus?
    /// Whether the list selection is this row.
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let select: () -> Void
    let actions: TerminalPaneActions

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    @FocusState private var isRenameFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var scaledMinimumHeight: CGFloat =
        TerminalPanelRowMetrics.paneRowHeight

    var body: some View {
        HStack(spacing: 6) {
            Text("\(row.ordinal)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
                .frame(minWidth: 12, alignment: .trailing)
                .accessibilityHidden(true)
            if isRenaming {
                TextField("Pane name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isRenameFieldFocused)
                    .onAppear { isRenameFieldFocused = true }
                    .onSubmit { actions.commitRename(row) }
                    .onExitCommand(perform: actions.cancelRename)
            } else {
                label
            }
            TerminalStatusGlyph(
                agentStatus: agentStatus, paneStatus: row.status, hasAttention: row.hasAttention
            )
            .opacity(showsActions ? 0 : 1)
        }
        .overlay(alignment: .trailing) {
            TerminalRowActionsMenu(label: "Actions for \(row.name)", isVisible: showsActions) {
                TerminalPaneMenuItems(row: row, actions: actions)
            }
        }
        .padding(.leading, TerminalPanelRowMetrics.rowPadding + TerminalPanelRowMetrics.paneIndent)
        .padding(.trailing, TerminalPanelRowMetrics.rowPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                base: TerminalPanelRowMetrics.paneRowHeight, scaledHeight: scaledMinimumHeight),
            alignment: .leading
        )
        .contentShape(.rect)
        .background(
            RoundedRectangle(cornerRadius: TerminalPanelRowMetrics.radius, style: .continuous)
                .fill(isHovering && !isSelected ? theme.palette.hover : Color.clear)
        )
        .modifier(TerminalRowSelectionHairline(isSelected: isSelected))
        // One tap handler, as on the group row: plain content, not a
        // `Button`, so a click is never held back inside the list.
        .onTapGesture {
            guard !isRenaming else { return }
            select()
            actions.revealAndFocus(row)
        }
        .onHover { isHovering = $0 }
        .contextMenu { TerminalPaneMenuItems(row: row, actions: actions) }
        .help(tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(row.ordinal), \(row.rowTitle)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(row.isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.revealAndFocus(row) }
        .accessibilityAction(named: "Reveal and Focus") { actions.revealAndFocus(row) }
    }

    private var label: some View {
        HStack(spacing: 4) {
            if let color = row.sessionColor {
                TerminalColorDot(color: theme.palette.color(for: color))
            }
            Text(row.rowTitle)
                .font(.system(size: 12, weight: row.isFocused ? .semibold : .regular))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let detail = detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }

    /// "· docs" when the folder differs from the group's, an abnormal status
    /// word, or both.
    private var detailText: String? {
        let statusWord = TerminalNaming.abnormalStatusWord(
            agentStatus: agentStatus, paneStatus: row.status, hasAttention: row.hasAttention)
        let text = TerminalNaming.subtitle([row.folderIfDifferent ?? "", statusWord ?? ""])
        return text.isEmpty ? nil : "· " + text
    }

    private var showsActions: Bool { isHovering || isSelected }

    private var tooltip: String {
        var lines = [row.rowTitle, row.subtitle]
        if let path = row.fullPath { lines.append((path as NSString).abbreviatingWithTildeInPath) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var accessibilityValue: String {
        var values = [row.providerOrShell, row.detail]
        if let agentStatus { values.append(agentStatus.word) }
        if row.folder != "." { values.append(row.folder) }
        if let colorName = row.colorName { values.append("Color \(colorName)") }
        if row.isFocused { values.append("Focused") }
        if row.hasAttention { values.append("Needs attention") }
        if let message = row.unavailableMessage { values.append(message) }
        return values.joined(separator: ", ")
    }
}

/// One ungrouped terminal session as a tuned two-line row, like a group row.
/// Every action is reachable from BOTH the row's trailing ellipsis menu (on
/// hover and selection) and its context menu (AGENTS: no icon-only-
/// context-menu-exclusive actions) — both feed off the same `actions`
/// view builder, mirroring `GitWorktreeRow`.
private struct TerminalSessionRowView: View {
    let row: TerminalSessionRow
    let isCurrent: Bool
    /// Whether the list selection is this row.
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let select: () -> Void
    let reveal: () -> Void
    /// `nil` when the row is already parked — there is no tab left to hide.
    let hide: (() -> Void)?
    let close: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let resetName: () -> Void
    let setColor: (TerminalSessionColor?) -> Void

    @Environment(\.rafuTheme) private var theme
    @FocusState private var isRenameFieldFocused: Bool
    @State private var isColorPickerPresented = false
    @State private var isHovering = false
    @ScaledMetric(relativeTo: .body) private var scaledMinimumHeight: CGFloat =
        TerminalPanelRowMetrics.twoLineHeight
    /// Seeded lazily from the active theme rather than eagerly from the system
    /// accent: the swatch the picker opens on is the one piece of Rafu chrome
    /// the user sees before they choose, so a system-blue seed there is the
    /// same leak `View.rafuTheme(_:)` closed everywhere else.
    /// `@State` cannot read `@Environment` in its initializer, so nil means
    /// "not chosen yet" and the binding falls back to the theme accent.
    @State private var customColor: Color?

    var body: some View {
        HStack(spacing: 8) {
            // Identity: the agent's vendor mark, or the terminal glyph for a
            // login shell — 14 pt in a 16 pt slot, as on the group rows.
            Group {
                if let provider = row.resolvedAgentProvider {
                    AgentIconView(cli: provider, size: 14)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .frame(
                width: TerminalPanelRowMetrics.iconSlot, height: TerminalPanelRowMetrics.iconSlot
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isRenaming {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.palette.textPrimary)
                            .focused($isRenameFieldFocused)
                            .onSubmit(commitRename)
                            .onExitCommand(perform: cancelRename)
                            .onAppear { isRenameFieldFocused = true }
                            .onChange(of: isRenameFieldFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    } else {
                        if let color = row.sessionColor {
                            TerminalColorDot(color: theme.palette.color(for: color))
                        }
                        Text(title)
                            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(theme.palette.textPrimary)
                    }
                }
                // An abnormal status word ("Needs attention", "Exited (1)")
                // leads the second line; a running or idle shell shows only
                // its glyph. The accessibility value always says the status.
                Text(
                    TerminalNaming.subtitle([
                        TerminalNaming.abnormalSessionStatusWord(row.status) ?? "",
                        row.shellName, row.directoryLabel,
                        row.isParked ? "Hidden" : "",
                    ])
                )
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Image(systemName: TerminalSessionPresentation.symbol(row.status))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(
                    width: TerminalPanelRowMetrics.statusSlot,
                    height: TerminalPanelRowMetrics.statusSlot
                )
                .opacity(showsActions ? 0 : 1)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .trailing) {
            TerminalRowActionsMenu(label: "Terminal actions", isVisible: showsActions) {
                actions
            }
        }
        .padding(.horizontal, TerminalPanelRowMetrics.rowPadding)
        .padding(.vertical, 4)
        .frame(
            maxWidth: .infinity,
            minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                base: TerminalPanelRowMetrics.twoLineHeight,
                scaledHeight: scaledMinimumHeight
            ),
            alignment: .leading
        )
        .contentShape(.rect)
        .background(
            RoundedRectangle(cornerRadius: TerminalPanelRowMetrics.radius, style: .continuous)
                .fill(isHovering && !isSelected ? theme.palette.hover : Color.clear)
        )
        // `isCurrent: false`: the list draws the selection fill, so the
        // resolver contributes only the attention border here.
        .rafuTerminalSurfaceBorder(
            context: .managerRow(
                isCurrent: false,
                needsAttention: row.needsAttention
            ),
            radius: TerminalPanelRowMetrics.radius
        )
        .modifier(TerminalRowSelectionHairline(isSelected: isSelected))
        // One tap handler. A second `onTapGesture(count: 2)` would make the
        // system hold every single click for the double-click interval before
        // it revealed the row. Select and reveal at once; a double-click (the
        // second click has `clickCount == 2`) also edits the name in place.
        // Return and Space come from the list (`TerminalsPanelListModel`).
        .onTapGesture {
            select()
            reveal()
            if TabClickIntent.current() == .selectAndRename { beginRename() }
        }
        .onHover { isHovering = $0 }
        .popover(isPresented: $isColorPickerPresented, arrowEdge: .trailing) {
            colorPalette
        }
        .contextMenu { actions }
        .help(tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Reveal") { reveal() }
    }

    /// Restart Shell is deliberately NOT offered here:
    /// `WorkspaceTerminalController.restart()` only respawns when a
    /// `TerminalHostView` mounts, and a parked row has no view, so a
    /// panel-only restart would strand the session `.exited` forever.
    /// Reveal (which mounts the exited overlay's own Restart Shell) covers
    /// that.
    @ViewBuilder
    private var actions: some View {
        Button("Rename…", systemImage: "pencil") { beginRename() }
        if row.hasUserName {
            Button("Reset to Automatic Name", systemImage: "arrow.uturn.backward") { resetName() }
        }
        // A popover rather than a submenu: `ColorPicker` cannot live inside
        // a `Menu`, and the arbitrary-color picker is the point.
        Button("Color…", systemImage: "paintpalette") { isColorPickerPresented = true }
        Divider()
        Button("Reveal", systemImage: "eye") { reveal() }
        if let hide {
            Button("Hide Tab", systemImage: "eye.slash") { hide() }
        }
        Divider()
        Button("Close", systemImage: "xmark.circle", role: .destructive) { close() }
    }

    /// Preset swatches plus the system color picker. Presets follow the
    /// theme; a picked color is stored as literal sRGB hex and does not.
    private var colorPalette: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            Text("Session Color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.palette.textSecondary)
            HStack(spacing: RafuMetrics.space2) {
                ForEach(TerminalSessionColor.presets, id: \.self) { preset in
                    Button {
                        setColor(preset)
                        isColorPickerPresented = false
                    } label: {
                        Circle()
                            .fill(theme.palette.color(for: preset))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    theme.palette.textPrimary,
                                    lineWidth: row.sessionColor == preset ? 2 : 0
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.displayName)
                    .accessibilityLabel(preset.displayName)
                }
            }
            ColorPicker(
                "Custom",
                selection: Binding(
                    get: { customColor ?? theme.palette.accent },
                    set: { customColor = $0 }),
                supportsOpacity: false
            )
            .font(.caption)
            .onChange(of: customColor) { _, picked in
                guard let picked, let hex = picked.rafuHexString,
                    let custom = TerminalSessionColor.custom(fromHex: hex)
                else { return }
                setColor(custom)
            }
            Divider().overlay(theme.palette.borderSubtle)
            Button("No Color") {
                setColor(nil)
                isColorPickerPresented = false
            }
            .buttonStyle(RafuSecondaryButtonStyle())
        }
        .padding(RafuMetrics.space4)
        .frame(width: 220)
    }

    private var statusTint: Color {
        switch row.status {
        case .running: theme.palette.accent
        case .idle: theme.palette.textSecondary
        case .bell: theme.palette.accent
        case .exited: theme.palette.textMuted
        }
    }

    /// The panel title, with a duplicate ordinal from the model.
    private var title: String { row.panelTitle ?? row.presentedTitle }

    private var showsActions: Bool { isHovering || isSelected }

    private var tooltip: String {
        TerminalNaming.subtitle([title, row.shellName, row.directoryLabel])
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if let provider = row.resolvedAgentProvider,
            provider.displayName != title
        {
            parts.append(provider.displayName)
        }
        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isCurrent { parts.append("Current terminal") }
        parts += [
            TerminalSessionPresentation.label(row.status),
            row.shellName,
            row.directoryLabel,
        ]
        if row.isParked { parts.append("Hidden") }
        if let color = row.sessionColor { parts.append("Color \(color.displayName)") }
        return parts.joined(separator: ", ")
    }
}
