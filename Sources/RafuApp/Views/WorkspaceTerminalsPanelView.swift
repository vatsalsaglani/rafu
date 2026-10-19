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
    /// Expansion is local presentation state, keyed by immutable group IDs.
    /// A manager refresh therefore cannot collapse an unrelated group.
    @State private var expandedGroupIDs: Set<TerminalGroupID> = []
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

    private func hierarchyList(_ rows: [TerminalsPanelModel.HierarchyRow]) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rows) { row in
                    switch row {
                    case .group(let group):
                        TerminalGroupManagerRowView(
                            row: group,
                            isExpanded: expandedGroupIDs.contains(group.id),
                            isRenaming: renamingGroupID == group.id,
                            renameText: $groupRenameText,
                            toggle: { toggleExpansion(group.id) },
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
                    case .pane(let pane):
                        if expandedGroupIDs.contains(pane.groupID) {
                            TerminalGroupPaneRowView(
                                row: pane,
                                isRenaming: renamingPaneID == pane.id,
                                renameText: $paneRenameText,
                                revealAndFocus: {
                                    session.revealTerminalGroup(pane.groupID)
                                    session.focusTerminalPane(pane.id, in: pane.groupID)
                                },
                                close: { session.closeTerminalPane(pane.id) },
                                start: pane.canStart ? { session.startTerminalPane(pane.id) } : nil,
                                restart: pane.canRestart
                                    ? { session.restartTerminalPane(pane.id) } : nil,
                                beginRename: { beginPaneRename(pane.id, pane.name) },
                                commitRename: { commitPaneRename(pane.id) },
                                cancelRename: cancelPaneRename,
                                setColor: { color in
                                    session.setTerminalPaneColor(pane.id, color)
                                }
                            )
                        }
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

    private func toggleExpansion(_ groupID: TerminalGroupID) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            HStack(spacing: RafuMetrics.space2) {
                Button {
                    isPresented = true
                } label: {
                    HStack(spacing: RafuMetrics.space1) {
                        Image(systemName: "terminal.badge")
                            .accessibilityHidden(true)
                        Text("Start Agent")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("Choose an agent CLI to start in a new terminal")
                .accessibilityLabel("Start Agent")
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    menu
                }
                Spacer(minLength: 0)
            }
            if isProbing {
                HStack(spacing: RafuMetrics.space1) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(AgentLauncherModel.checkingLine(agentCount: rows.count))
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .padding(.horizontal, RafuMetrics.utilityBodyInset)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One outer Terminal Group row. The group owns the actions that affect the
/// complete saved/runtime tree; individual panes only expose pane actions.
private struct TerminalGroupManagerRowView: View {
    let row: TerminalsPanelModel.TerminalGroupRow
    let isExpanded: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let toggle: () -> Void
    let reveal: () -> Void
    let hide: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let saveLayout: (() -> Void)?
    let updateSavedLayout: (() -> Void)?
    let startAll: (() -> Void)?
    let close: () -> Void
    /// Needed only to mark this row's drag in flight (the dimmed source
    /// ghost) and its kind (same-window hover-label hint). Never read to
    /// decide what a drop does.
    let session: WorkspaceSession

    @Environment(\.rafuTheme) private var theme
    /// This row's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the row's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded ? "Collapse \(row.displayName)" : "Expand \(row.displayName)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isRenaming {
                        TextField("Group name", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.caption.weight(.medium))
                            .onSubmit(commitRename)
                            .onExitCommand(perform: cancelRename)
                    } else {
                        if let color = row.sessionColor {
                            TerminalColorDot(color: theme.palette.color(for: color))
                        }
                        Text(row.displayName)
                            .fontWeight(row.isCurrent ? .semibold : .medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if row.isCanvasOwned {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.palette.textMuted)
                            .accessibilityLabel("On an Ensemble")
                    } else if row.isParked {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.palette.textMuted)
                            .accessibilityLabel("Hidden")
                    }
                    if row.isSaved { Image(systemName: "bookmark.fill").accessibilityHidden(true) }
                }
                .font(.caption)
                Text(row.summary)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
            }
            Spacer(minLength: 0)
            Menu {
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
                Divider()
                Button("Reveal", action: reveal)
                if !row.isParked { Button("Hide Group", action: hide) }
                Divider()
                Button("Close Group", role: .destructive, action: close)
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
            .help("Actions for \(row.displayName)")
            .accessibilityLabel("Actions for \(row.displayName)")
        }
        .padding(RafuMetrics.space2)
        .background(theme.palette.cardBackground)
        .clipShape(.rect(cornerRadius: RafuMetrics.radiusDenseCard))
        .contentShape(.rect)
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
        .onTapGesture(perform: reveal)
        .focusable()
        .onKeyPress(.return) {
            reveal()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal Group, \(row.displayName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "Reveal") { reveal() }
    }

    private var accessibilityValue: String {
        var values = [TerminalNaming.paneCountLabel(row.paneCount), row.stateLabel]
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

private struct TerminalGroupPaneRowView: View {
    let row: TerminalsPanelModel.TerminalPaneRow
    let isRenaming: Bool
    @Binding var renameText: String
    let revealAndFocus: () -> Void
    let close: () -> Void
    let start: (() -> Void)?
    let restart: (() -> Void)?
    let beginRename: (() -> Void)?
    let commitRename: (() -> Void)?
    let cancelRename: () -> Void
    let setColor: (TerminalPaneThemeColor?) -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: statusSymbol).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Pane name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.caption.weight(.medium))
                        .onSubmit { commitRename?() }
                        .onExitCommand(perform: cancelRename)
                } else {
                    HStack(spacing: 5) {
                        if let color = row.sessionColor {
                            TerminalColorDot(color: theme.palette.color(for: color))
                        }
                        Text(row.name)
                            .font(.caption.weight(row.isFocused ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(row.subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                if let start { Button("Start Shell", action: start) }
                if let restart { Button("Restart Shell", action: restart) }
                Button("Reveal and Focus", action: revealAndFocus)
                if let beginRename {
                    Button("Rename…", action: beginRename)
                    Menu("Color") {
                        ForEach(TerminalPaneThemeColor.presets, id: \.self) { color in
                            Button {
                                setColor(color)
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
                        Button("No Color") { setColor(nil) }
                    }
                }
                Button("Close Pane", role: .destructive, action: close)
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
            .help("Actions for \(row.name)")
            .accessibilityLabel("Actions for \(row.name)")
        }
        .padding(.leading, RafuMetrics.space4)
        .padding(.trailing, RafuMetrics.space2)
        .padding(.vertical, RafuMetrics.space1)
        .contentShape(.rect)
        .onTapGesture(perform: revealAndFocus)
        .focusable()
        .onKeyPress(.return) {
            revealAndFocus()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal pane, \(row.name)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "Reveal and Focus") { revealAndFocus() }
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
        if row.folder != "." { values.append(row.folder) }
        if let colorName = row.colorName { values.append("Color \(colorName)") }
        if row.isFocused { values.append("Focused") }
        if row.hasAttention { values.append("Needs attention") }
        if let message = row.unavailableMessage { values.append(message) }
        return values.joined(separator: ", ")
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

    private var rowRadius: CGFloat {
        isCurrent ? RafuMetrics.radiusDenseSelection : RafuMetrics.radiusDenseCard
    }

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
