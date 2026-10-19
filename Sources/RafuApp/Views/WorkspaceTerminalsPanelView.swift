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
            canvasOwnedGroupIDs: Set(session.canvasTerminalOwners.keys)
        )
        let managerItemCount = rows.count { $0.isManagerItem }
        VStack(spacing: 0) {
            header(count: managerItemCount)
            if session.rootURL != nil {
                AgentStartMenuView(
                    rows: agentLauncherRows,
                    isProbing: agentTerminalOptions == nil,
                    launch: launchAgent,
                    refresh: { agentProbeToken += 1 }
                )
                Divider().overlay(theme.palette.borderSubtle)
            }
            if rows.isEmpty {
                emptyState
            } else {
                hierarchyList(rows)
            }
            TerminalGroupSavedLayoutsSection(session: session)
        }
        // Load-bearing per AGENTS' panel-top-alignment rule (see
        // `GitInspectorView`'s identical comment): `.frame(maxHeight:
        // .infinity)` defaults to CENTER alignment, so an under-filled tab
        // (few/no sessions) would float the header + list stack to the
        // vertical middle instead of pinning to the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            icon: "terminal",
            title: "Terminals",
            closeAccessibilityLabel: "Close Terminals",
            onClose: { session.isSidebarCollapsed = true },
            context: {
                RafuChip(
                    text: "\(count)",
                    monospacedDigit: true
                )
                .accessibilityLabel(
                    count == 1
                        ? "1 terminal group or legacy terminal"
                        : "\(count) terminal groups or legacy terminals")
            },
            actions: { newTerminalControl }
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

    private var emptyState: some View {
        RafuPanelEmptyState(
            icon: "terminal",
            title: "No Terminal Sessions",
            message: "Open a shell here, or use the terminal shortcuts from the editor."
        ) {
            VStack(spacing: RafuMetrics.space2) {
                Button("New Terminal") { session.newTerminalTab() }
                    .buttonStyle(RafuProminentButtonStyle())
                HStack(spacing: RafuMetrics.space2) {
                    RafuChip(text: "⌃`")
                    Text("Toggle")
                    RafuChip(text: "⌃⇧`")
                    Text("New")
                }
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Control-backtick toggles a terminal. Control-Shift-backtick opens a new terminal."
                )
            }
        }
    }

    /// One card per group (its panes become chips inside it) and one row per
    /// legacy session. `.pane` rows render nothing on their own.
    private func hierarchyList(_ rows: [TerminalsPanelModel.HierarchyRow]) -> some View {
        // Grouped ONCE per render, never per card inside the `ForEach`.
        var panesByGroup: [TerminalGroupID: [TerminalsPanelModel.TerminalPaneRow]] = [:]
        for case .pane(let pane) in rows { panesByGroup[pane.groupID, default: []].append(pane) }
        let cardRows = rows.filter(\.isManagerItem)
        return ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(cardRows) { row in
                    switch row {
                    case .group(let group):
                        TerminalGroupManagerRowView(
                            row: group,
                            panes: panesByGroup[group.id] ?? [],
                            isRenaming: renamingGroupID == group.id,
                            renameText: $groupRenameText,
                            renamingPaneID: renamingPaneID,
                            paneRenameText: $paneRenameText,
                            paneActions: paneActions,
                            reveal: { session.revealTerminalGroup(group.id) },
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
                    case .pane:
                        // Drawn as a chip inside its group's card.
                        EmptyView()
                    case .legacy(let legacy, let isCurrent):
                        TerminalSessionRowView(
                            row: legacy,
                            isCurrent: isCurrent,
                            isRenaming: renamingID == legacy.id,
                            renameText: $renameText,
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
            }
            .padding(RafuMetrics.utilityBodyInset)
        }
    }

    /// Every pane action names its exact pane; rename state stays on the
    /// panel (`renamingPaneID`, `paneRenameText`).
    private var paneActions: TerminalPaneActions {
        TerminalPaneActions(
            revealAndFocus: { pane in
                session.revealTerminalGroup(pane.groupID)
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

/// The agent launcher (macOS redesign T1): one "Start Agent" pull-down in place
/// of the old seven-tile grid. While detection runs, one line says
/// "Checking N agents…".
///
/// The list is a popover of ordinary SwiftUI rows, not a `Menu`: menu content
/// is bridged to `NSMenuItem`, which draws an image at its own size, and the
/// vendored SVGs are authored `width="1em"` so `NSImage` reports 1×1 pt there
/// and every mark drew as a dot (see `docs/references/agent-terminals.md`).
/// Rows therefore use `AgentIconView` (the shared agent identity mark) for every provider.
/// Opening the list starts nothing; only choosing a ready row launches.
private struct AgentStartMenuView: View {
    let rows: [AgentLauncherRow]
    let isProbing: Bool
    let launch: (AgentLauncherRow) -> Void
    let refresh: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isPresented = false

    @State private var isHovering = false

    /// A full-width card row in the same shape as a group card: a well with
    /// the launcher glyph, "Start Agent" over the probe line, and a chevron.
    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.badge")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.palette.chipBackground)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Agent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    HStack(spacing: RafuMetrics.space1) {
                        if isProbing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                        Text(statusLine)
                            .font(.caption2)
                            .foregroundStyle(theme.palette.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? theme.palette.hover : theme.palette.cardBackground)
            )
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Choose an agent CLI to start in a new terminal")
        .accessibilityLabel("Start Agent")
        .accessibilityValue(statusLine)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menu
        }
        .padding(.horizontal, RafuMetrics.utilityBodyInset)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Checking 7 agents…" while probing, then how many are ready.
    private var statusLine: String {
        if isProbing { return AgentLauncherModel.checkingLine(agentCount: rows.count) }
        let ready = rows.count { $0.isLaunchable }
        return ready == 0 ? "No agent CLI found" : "\(ready) ready"
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
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

/// One Terminal Group as a compact horizontal card: drag grip on hover, an
/// identity well (the focused pane's agent mark, else a terminal glyph),
/// the name over a one-line subtitle, a status pill, and a hover ⋯ menu. A
/// group with more than one pane lists its panes as chips on a second line;
/// there is no accordion. The whole card is the drag source.
private struct TerminalGroupManagerRowView: View {
    let row: TerminalsPanelModel.TerminalGroupRow
    /// This group's panes, in pane order (`TerminalsPanelModel.hierarchyRows`).
    let panes: [TerminalsPanelModel.TerminalPaneRow]
    let isRenaming: Bool
    @Binding var renameText: String
    let renamingPaneID: TerminalPaneID?
    @Binding var paneRenameText: String
    let paneActions: TerminalPaneActions
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
    /// card's drag in flight (the dimmed source ghost) and its kind
    /// (same-window hover-label hint). Never read to decide what a drop does.
    let session: WorkspaceSession

    @Environment(\.rafuTheme) private var theme
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @ScaledMetric(relativeTo: .body) private var scaledMinimumHeight: CGFloat = 48
    /// This row's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the row's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    private static let radius: CGFloat = 8

    var body: some View {
        let focused = focusedPane
        let focusedStatus = focused.flatMap {
            CanvasCardCommands.agentCardStatus(pane: $0, in: session)
        }
        surface(content(focused: focused, agentStatus: focusedStatus))
            // One tap handler (docs/references/swiftui-macos-click-latency.md):
            // reveal at once; the second click of a double-click also renames.
            .onTapGesture {
                reveal()
                if TabClickIntent.current() == .selectAndRename { beginRename() }
            }
            .focusable()
            .focused($isFocused)
            .onKeyPress(.return) {
                reveal()
                return .handled
            }
            .onHover { isHovering = $0 }
            // The ⋯ menu is hover- and focus-revealed; the same items are
            // here, so nothing is reachable only by hovering.
            .contextMenu { actions }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal Group, \(row.displayName)")
            .accessibilityValue(accessibilityValue(focusedStatus))
            .accessibilityAction(named: "Reveal") { reveal() }
            .accessibilityAction(named: "Close Group") { close() }
    }

    private func content(focused: TerminalPaneSnapshot?, agentStatus: AgentCardStatus?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.palette.textMuted)
                    .frame(width: 10)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityHidden(true)
                identityWell(focused)
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                statusPill(agentStatus)
                actionsMenu
            }
            if panes.count > 1 { paneChips }
        }
    }

    private var paneChips: some View {
        TerminalPaneChipFlow(spacing: 4) {
            ForEach(panes) { pane in
                TerminalPaneChipView(
                    row: pane,
                    agentStatus: paneAgentStatus(for: pane),
                    isRenaming: renamingPaneID == pane.id,
                    renameText: $paneRenameText,
                    actions: paneActions
                )
            }
        }
        // Under the title, past the grip and the identity well.
        .padding(.leading, 10 + 8 + 26 + 8)
    }

    /// Geometry, fill, the shared manager-row border, and the drag source.
    private func surface(_ content: some View) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                    base: 48, scaledHeight: scaledMinimumHeight),
                alignment: .leading
            )
            .contentShape(.rect)
            .rafuTerminalSurfaceBorder(
                context: .managerRow(
                    isCurrent: row.isCurrent, needsAttention: row.attentionCount > 0),
                identityColor: row.sessionColor.map { theme.palette.color(for: $0) },
                radius: Self.radius
            )
            .background(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(isHovering ? theme.palette.hover : theme.palette.cardBackground)
            )
            .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
            // Carries only the group's id over the private `rafuEnsembleDrag`
            // type, exactly like an Agent History row — never a title, path, or
            // transcript. Dropped on an Ensemble board centre, a one-pane group
            // (running or stopped) moves there with `moveTerminalGroupToEnsemble`
            // (lease, keeps running); the existing refusals (more than one pane,
            // already on a board, board full) apply unchanged at drop time.
            .onDrag(
                {
                    DragDiag.note("source terminals-row onDrag")
                    session.beginDragSourceTracking(dragToken)
                    session.activeEnsembleDragHint = .terminalGroup
                    return CanvasBoardDragPayload(terminalGroupID: row.id).makeItemProvider()
                },
                preview: {
                    RafuDragPreviewLabel(
                        icon: Image(systemName: "rectangle.3.group"), title: row.displayName)
                }
            )
    }

    // MARK: Parts

    private var titleLine: some View {
        HStack(spacing: 5) {
            if isRenaming {
                TextField("Group name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
            } else {
                if let color = row.sessionColor {
                    TerminalColorDot(color: theme.palette.color(for: color))
                }
                Text(row.displayName)
                    .font(.system(size: 13, weight: row.isCurrent ? .semibold : .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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

    /// The focused pane's agent mark, else the terminal glyph.
    private func identityWell(_ pane: TerminalPaneSnapshot?) -> some View {
        Group {
            if let provider = pane.flatMap({ session.terminal.terminalController(for: $0.id) })?
                .resolvedAgentProvider
            {
                AgentIconView(cli: provider, size: 16)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(width: 26, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.palette.chipBackground)
        )
        .accessibilityHidden(true)
    }

    /// The agent pill when the focused pane runs an agent, else the group
    /// state word. Attention adds a bell and a word, never colour alone.
    @ViewBuilder
    private func statusPill(_ agentStatus: AgentCardStatus?) -> some View {
        if let agentStatus {
            AgentStatusPill(status: agentStatus, elapsed: nil)
        } else {
            RafuChip(text: row.stateLabel)
        }
        if row.attentionCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9))
                    .accessibilityHidden(true)
                Text("Needs attention")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.palette.warning)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.warning.opacity(0.14)))
            .fixedSize()
            .accessibilityHidden(true)
        }
    }

    private var actionsMenu: some View {
        Menu {
            actions
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
        .opacity(isHovering || isFocused ? 1 : 0)
        .help("Actions for \(row.displayName)")
        .accessibilityLabel("Actions for \(row.displayName)")
    }

    /// The group's items; a one-pane group also offers its pane's shell and
    /// colour items, since it shows no pane chip.
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

    private func paneAgentStatus(for pane: TerminalsPanelModel.TerminalPaneRow) -> AgentCardStatus?
    {
        guard
            let snapshot = session.terminal.terminalGroup(row.id)?.panes.first(where: {
                $0.id == pane.id
            })
        else { return nil }
        return CanvasCardCommands.agentCardStatus(pane: snapshot, in: session)
    }

    /// One pane: the shell and its folder ("zsh · ~/src/api"), which the
    /// automatic name only shortens. More panes: the pane count and the
    /// group state word.
    private var subtitle: String {
        if panes.count == 1, let pane = panes.first {
            let folder =
                pane.folder.hasPrefix("/")
                ? (pane.folder as NSString).abbreviatingWithTildeInPath
                : TerminalNaming.folderName(
                    path: pane.folder, workspaceRoot: session.rootURL?.path) ?? ""
            return TerminalNaming.subtitle([pane.providerOrShell, folder])
        }
        return TerminalNaming.subtitle([
            TerminalNaming.paneCountLabel(row.paneCount), row.stateLabel,
        ])
    }

    private func accessibilityValue(_ agentStatus: AgentCardStatus?) -> String {
        var values = [TerminalNaming.paneCountLabel(row.paneCount), row.stateLabel]
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
        return values.joined(separator: ", ")
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

/// One pane of a multi-pane group as a capsule chip: a status glyph (a
/// spinner while its agent works), the colour dot and the name. Clicking
/// reveals the group and focuses the pane. The hover ⋯ and the context menu
/// carry the pane's menu; renaming swaps the name for a field.
private struct TerminalPaneChipView: View {
    let row: TerminalsPanelModel.TerminalPaneRow
    let agentStatus: AgentCardStatus?
    let isRenaming: Bool
    @Binding var renameText: String
    let actions: TerminalPaneActions

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if isRenaming {
                TextField("Pane name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 60, maxWidth: 140)
                    .focused($isRenameFieldFocused)
                    .onAppear { isRenameFieldFocused = true }
                    .onSubmit { actions.commitRename(row) }
                    .onExitCommand(perform: actions.cancelRename)
            } else {
                Button {
                    actions.revealAndFocus(row)
                } label: {
                    HStack(spacing: 4) {
                        statusGlyph
                        if let color = row.sessionColor {
                            TerminalColorDot(color: theme.palette.color(for: color))
                        }
                        Text(row.name)
                            .font(.system(size: 11, weight: row.isFocused ? .semibold : .regular))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pane, \(row.name)")
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(row.isFocused ? .isSelected : [])
            }
            Menu {
                TerminalPaneMenuItems(row: row, actions: actions)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 14, height: 18)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .help("Actions for \(row.name)")
            .accessibilityLabel("Actions for \(row.name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 22)
        .background(
            Capsule().fill(isHovering ? theme.palette.hover : theme.palette.chipBackground)
        )
        .overlay(
            Capsule().strokeBorder(
                row.isFocused ? theme.palette.borderStrong : Color.clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .contextMenu { TerminalPaneMenuItems(row: row, actions: actions) }
        .help(row.subtitle)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if let agentStatus {
            AgentActivityGlyph(status: agentStatus)
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    row.status == .live ? theme.palette.accent : theme.palette.textMuted
                )
                .accessibilityHidden(true)
        }
    }

    private var statusSymbol: String {
        switch row.status {
        case .idle: "circle"
        case .live: "circle.fill"
        case .exited: "xmark.circle.fill"
        case .stopped: "stop.circle"
        case .unavailable: "exclamationmark.triangle"
        }
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

/// Lays chips out left to right and wraps to a new line when the next one
/// does not fit — the narrow sidebar never scrolls sideways.
private struct TerminalPaneChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width =
                current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// One terminal session row. Every action is reachable from BOTH the row's
/// trailing ellipsis menu and its context menu (AGENTS: no icon-only-
/// context-menu-exclusive actions) — both feed off the same `actions`
/// view builder, mirroring `GitWorktreeRow`.
private struct TerminalSessionRowView: View {
    let row: TerminalSessionRow
    let isCurrent: Bool
    let isRenaming: Bool
    @Binding var renameText: String
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
    @ScaledMetric(relativeTo: .body) private var scaledMinimumHeight: CGFloat = 48
    /// Seeded lazily from the active theme rather than eagerly from the system
    /// accent: the swatch the picker opens on is the one piece of Rafu chrome
    /// the user sees before they choose, so a system-blue seed there is the
    /// same leak `View.rafuTheme(_:)` closed everywhere else.
    /// `@State` cannot read `@Environment` in its initializer, so nil means
    /// "not chosen yet" and the binding falls back to the theme accent.
    @State private var customColor: Color?

    var body: some View {
        HStack(spacing: RafuMetrics.space3) {
            // IDENTITY well: the agent's vendor mark, or the terminal glyph
            // for a login shell. This slot used to hold the status glyph,
            // which put every session behind the same dot and pushed identity
            // into a second, smaller icon beside the name.
            //
            // Status did not simply move — it changed carrier. It is now the
            // first segment of the caption line below, as a WORD, which is a
            // stronger signal than the glyph it replaces and satisfies AGENTS'
            // rule against state by color alone without needing a badge the
            // size of a few pixels. The exited chip beside the name stays.
            Group {
                if let provider = row.resolvedAgentProvider {
                    AgentIconView(cli: provider, size: 16)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusTint)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(theme.palette.chipBackground)
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isRenaming {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.body.weight(.medium))
                            .foregroundStyle(theme.palette.textPrimary)
                            .focused($isRenameFieldFocused)
                            .onSubmit(commitRename)
                            .onExitCommand(perform: cancelRename)
                            .onAppear { isRenameFieldFocused = true }
                            .onChange(of: isRenameFieldFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    } else {
                        // No vendor mark here any more — it moved to the well,
                        // and two copies of the same mark on one row read as a
                        // mistake.
                        if let color = row.sessionColor {
                            TerminalColorDot(color: theme.palette.color(for: color))
                        }
                        Text(row.presentedTitle)
                            .fontWeight(isCurrent ? .semibold : .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(theme.palette.textPrimary)
                    }
                    if row.isParked {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.palette.textMuted)
                            .accessibilityLabel("Hidden")
                    }
                    if case .exited = row.status {
                        // Exit state is never color-only: the chip makes it
                        // visible as text too, not just the muted glyph tint.
                        RafuChip(
                            text: TerminalSessionPresentation.label(row.status).lowercased(),
                            foreground: theme.palette.textMuted
                        )
                    }
                    Spacer(minLength: 0)
                }
                // Status leads the caption as both a shape-distinct symbol
                // and text. Attention therefore retains a bell plus "Needs
                // attention" even with hue removed.
                HStack(spacing: RafuMetrics.space1) {
                    Image(systemName: TerminalSessionPresentation.symbol(row.status))
                        .font(.caption2)
                        .foregroundStyle(statusTint)
                        .accessibilityHidden(true)
                    Text(
                        TerminalNaming.subtitle([
                            TerminalSessionPresentation.label(row.status),
                            row.shellName, row.directoryLabel,
                        ])
                    )
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Menu {
                actions
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
            .help("Terminal actions")
            .accessibilityLabel("Terminal actions")
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
        .frame(
            minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                base: 48,
                scaledHeight: scaledMinimumHeight
            )
        )
        .contentShape(.rect)
        .rafuTerminalSurfaceBorder(
            context: .managerRow(
                isCurrent: isCurrent,
                needsAttention: row.needsAttention
            ),
            identityColor: identityColor,
            identityMatchesEditorBackground: identityMatchesEditorBackground,
            radius: rowRadius
        )
        .background(
            RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
                .fill(isHovering ? theme.palette.hover : theme.palette.cardBackground)
        )
        // One tap handler. A second `onTapGesture(count: 2)` would make the
        // system hold every single click for the double-click interval before
        // it revealed the row. Reveal at once; a double-click (the second
        // click has `clickCount == 2`) also edits the name in place.
        .onTapGesture {
            reveal()
            if TabClickIntent.current() == .selectAndRename { beginRename() }
        }
        .focusable()
        .onKeyPress(.return) {
            reveal()
            return .handled
        }
        .onHover { isHovering = $0 }
        .popover(isPresented: $isColorPickerPresented, arrowEdge: .trailing) {
            colorPalette
        }
        .contextMenu { actions }
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

    /// One radius for every terminal card, current or not.
    private var rowRadius: CGFloat { 8 }

    private var identityColor: Color? {
        row.sessionColor.map { theme.palette.color(for: $0) }
    }

    /// Explicitly tell the shared resolver about the collision case even
    /// though its neutral edge remains structurally present for every
    /// identity color.
    private var identityMatchesEditorBackground: Bool {
        guard let identityHex = identityColor?.rafuHexString,
            let backgroundHex = theme.palette.editorBackground.rafuHexString
        else { return false }
        return identityHex == backgroundHex
    }

    private var accessibilityLabel: String {
        var parts = [row.presentedTitle]
        if let provider = row.resolvedAgentProvider,
            provider.displayName != row.presentedTitle
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
