import SwiftUI

/// The terminals panel (terminal-manager.md T-B): every live terminal
/// session in creation order, whether or not it currently has a tab. Sessions
/// outlive their tabs (T-A) — hiding a row parks the session, closing it
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
    @State private var isShellPickerPresented = false

    var body: some View {
        // Derived ONCE per body evaluation, never per-row inside a `ForEach`
        // closure: `presentedTerminalSessionIDs` walks every group's tabs
        // (`WorkspaceSession.swift`), so recomputing it per row would be
        // quadratic. Deriving once per render is an accepted cost at the
        // handful of sessions (≤~10) this panel expects.
        let rows = TerminalsPanelModel.rows(
            sessions: session.terminal.sessions,
            presentedIDs: session.presentedTerminalSessionIDs,
            workspaceRoot: session.rootURL?.path
        )
        let currentSessionID = session.currentTerminalSessionID
        VStack(spacing: 0) {
            header(count: rows.count)
            if session.rootURL != nil {
                AgentLauncherSectionView(
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
                sessionList(rows, currentSessionID: currentSessionID)
            }
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
            onClose: { session.navigatorMode = .files },
            context: {
                RafuChip(
                    text: "\(count)",
                    monospacedDigit: true
                )
                .accessibilityLabel(
                    count == 1 ? "1 terminal session" : "\(count) terminal sessions")
            },
            actions: {
                HStack(spacing: RafuMetrics.space1) {
                    Button {
                        session.newTerminalTab()
                    } label: {
                        Label("New Terminal", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(RafuIconButtonStyle(size: 24))
                    .help("New Terminal")
                    .accessibilityLabel("New Terminal")

                    if session.availableTerminalShells.count >= 2 {
                        Button {
                            isShellPickerPresented = true
                        } label: {
                            Label("Choose Terminal Shell", systemImage: "chevron.down")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(RafuIconButtonStyle(size: 24))
                        .help("Choose Terminal Shell")
                        .accessibilityLabel("Choose Terminal Shell")
                        .popover(isPresented: $isShellPickerPresented, arrowEdge: .bottom) {
                            TerminalShellPickerView(
                                shells: session.availableTerminalShells,
                                onSelect: { shell in
                                    session.newTerminalTab(shell: shell)
                                    isShellPickerPresented = false
                                },
                                onCancel: { isShellPickerPresented = false }
                            )
                        }
                    }
                }
            }
        )
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

    private func sessionList(
        _ rows: [TerminalSessionRow],
        currentSessionID: UUID?
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rows) { row in
                    TerminalSessionRowView(
                        row: row,
                        isCurrent: currentSessionID == row.id,
                        isRenaming: renamingID == row.id,
                        renameText: $renameText,
                        reveal: { session.revealTerminalSession(row.id) },
                        hide: row.isParked ? nil : { session.hideTerminalSession(row.id) },
                        close: { session.closeTerminalSession(row.id) },
                        beginRename: { beginRename(row) },
                        commitRename: { commitRename(row.id) },
                        cancelRename: cancelRename,
                        resetName: { session.renameTerminalSession(row.id, to: nil) },
                        setColor: { color in session.setTerminalSessionColor(row.id, color) }
                    )
                }
            }
            .padding(RafuMetrics.utilityBodyInset)
        }
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

/// The inline agent launcher (UX2-03): a compact grid of named provider cells
/// with an honest pending state and unavailable providers that stay visible
/// and say why.
///
/// The section replaced an agent list inside the `+` `Menu`, then a stack of
/// full-width name+status rows. The menu exclusion is not a styling preference:
/// menu content is bridged to `NSMenuItem`, which draws its image at the
/// image's own size, and the vendored SVGs are authored `width="1em"` so
/// `NSImage` reports 1×1 pt. SwiftUI's `.resizable().frame(_:)` — which is what
/// makes `FileIconView` correct everywhere else — has no effect there. The grid
/// is an ordinary SwiftUI surface, so the marks render at their asked size.
///
private struct AgentLauncherSectionView: View {
    let rows: [AgentLauncherRow]
    let isProbing: Bool
    let launch: (AgentLauncherRow) -> Void
    let refresh: () -> Void

    @Environment(\.rafuTheme) private var theme

    /// Reflows to the panel's width while preserving WP-30's 86 pt minimum
    /// named-cell width. `.adaptive` stretches surviving columns, so the grid
    /// remains flush at 250, 310, and 460 pt utility widths.
    private static let columns = [
        GridItem(.adaptive(minimum: 86, maximum: 160), spacing: 6, alignment: .center)
    ]

    var body: some View {
        VStack(spacing: 0) {
            RafuCardHeaderRow {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.badge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                    Text(AgentLauncherModel.headerTitle(rows: rows, isProbing: isProbing))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    if isProbing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                    }
                }
            } trailing: {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isProbing)
                .help("Check installed agent CLIs again")
                .accessibilityLabel("Check installed agent CLIs again")
            }

            // No ScrollView: seven cards reflow into at most three short rows
            // even in the narrowest panel, and a ScrollView would greedily
            // claim vertical space the session list needs.
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    AgentLauncherCardView(row: row, launch: { launch(row) })
                }
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, RafuMetrics.space2)
        }
    }
}

/// One provider launch cell. A click launches; under Full Keyboard Access the
/// cell is a focusable button, so Tab reaches it and Return/Space activates it.
/// The short visible name is backed by a full provider/state/reason tooltip and
/// accessibility label. Probing and unavailable states also carry distinct
/// progress/warning shapes, so dimming is never their only visual carrier.
private struct AgentLauncherCardView: View {
    let row: AgentLauncherRow
    let launch: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    @ScaledMetric(relativeTo: .caption) private var scaledMinimumHeight: CGFloat = 34

    var body: some View {
        Button(action: launch) {
            HStack(spacing: 6) {
                // The mark renders here because a normal SwiftUI view honors
                // `FileIconView`'s resizable frame; the same view inside a
                // `Menu` could not.
                FileIconView(icon: row.icon, size: 16)
                    .frame(width: 18, height: 18)
                    .opacity(row.isLaunchable ? 1 : 0.55)
                    .accessibilityHidden(true)
                Text(row.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        row.isLaunchable
                            ? theme.palette.textPrimary : theme.palette.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                statusIndicator
            }
            .padding(.horizontal, RafuMetrics.space2)
            .frame(
                minWidth: 86,
                maxWidth: .infinity,
                minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                    base: 34,
                    scaledHeight: scaledMinimumHeight
                )
            )
            .background(
                RoundedRectangle(
                    cornerRadius: RafuMetrics.radiusDenseCard,
                    style: .continuous
                )
                .fill(background)
            )
            .overlay(border)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
        }
        .buttonStyle(TerminalLauncherButtonStyle())
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

    private var background: Color {
        guard row.isLaunchable else { return theme.palette.cardBackground.opacity(0.5) }
        return isHovering ? theme.palette.hover : theme.palette.cardBackground
    }

    /// An unavailable card is dimmed AND dashed. The dash is a SHAPE
    /// difference, so the disabled state survives grayscale, Increase
    /// Contrast, and colour-blind vision — dimming alone would be meaning by
    /// tone, and the reason itself is always in the tooltip and the
    /// accessibility label.
    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(
            cornerRadius: RafuMetrics.radiusDenseCard,
            style: .continuous
        )
        if row.isLaunchable {
            shape.strokeBorder(theme.palette.borderSubtle.opacity(0.5), lineWidth: 1)
        } else {
            shape.strokeBorder(
                theme.palette.borderSubtle,
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

private struct TerminalLauncherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
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
                if let provider = row.agentProvider {
                    FileIconView(icon: ConductorCLIIcons.icon(for: provider), size: 15)
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
                        Text(row.displayName)
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
                        "\(TerminalSessionPresentation.label(row.status)) · \(row.shellName) · \(row.directoryLabel)"
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
        // Double-click edits the name in place. Registered BEFORE the
        // single-click reveal so SwiftUI can disambiguate; a single click
        // still reveals.
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { reveal() }
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
        .accessibilityElement(children: .combine)
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
        var parts = [row.displayName]
        if let provider = row.agentProvider,
            provider.displayName != row.displayName
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
        if row.isParked { parts.append("Parked") }
        return parts.joined(separator: ", ")
    }
}
