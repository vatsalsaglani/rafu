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
        VStack(spacing: 0) {
            header(count: rows.count)
            if rows.isEmpty {
                emptyState
            } else {
                sessionList(rows)
            }
        }
        // Load-bearing per AGENTS' panel-top-alignment rule (see
        // `GitInspectorView`'s identical comment): `.frame(maxHeight:
        // .infinity)` defaults to CENTER alignment, so an under-filled tab
        // (few/no sessions) would float the header + list stack to the
        // vertical middle instead of pinning to the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(count: Int) -> some View {
        RafuCardHeaderRow {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                Text("Terminals (\(count))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        } trailing: {
            HStack(spacing: 6) {
                Button("New Terminal", systemImage: "plus") {
                    session.newTerminalTab()
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("New Terminal")

                // Shown only when the catalog has ≥2 discovered shells
                // (terminal-manager.md T-C) — a single-shell machine has
                // nothing to choose between.
                if session.availableTerminalShells.count >= 2 {
                    Menu {
                        ForEach(session.availableTerminalShells) { shell in
                            Button("\(shell.name) — \(shell.path)") {
                                session.newTerminalTab(shell: shell)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.palette.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("New Terminal With Shell")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Terminal Sessions", systemImage: "terminal")
        } description: {
            Text("Toggle a terminal with ⌃` (Control-backtick), or open a new one with ⌃⇧`.")
        } actions: {
            Button("New Terminal") { session.newTerminalTab() }
                .buttonStyle(RafuProminentButtonStyle())
        }
        // Expands to claim the panel's remaining space so the empty state
        // centers WITHIN it, rather than floating the header above it to
        // the vertical middle (AGENTS panel-top-alignment rule).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionList(_ rows: [TerminalSessionRow]) -> some View {
        List {
            ForEach(rows) { row in
                TerminalSessionRowView(
                    row: row,
                    isSelected: session.terminal.selectedID == row.id,
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
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

/// One terminal session row. Every action is reachable from BOTH the row's
/// trailing ellipsis menu and its context menu (AGENTS: no icon-only-
/// context-menu-exclusive actions) — both feed off the same `actions`
/// view builder, mirroring `GitWorktreeRow`.
private struct TerminalSessionRowView: View {
    let row: TerminalSessionRow
    let isSelected: Bool
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

    var body: some View {
        HStack(spacing: 8) {
            // Color TAG dot (terminal-manager.md T-D) — never the only
            // signal: always paired with the status glyph beside it.
            if let sessionColor = row.sessionColor {
                Circle()
                    .fill(theme.palette.color(for: sessionColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Image(systemName: TerminalSessionPresentation.symbol(row.status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusTint)
                .accessibilityLabel(TerminalSessionPresentation.label(row.status))
            VStack(alignment: .leading, spacing: 2) {
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
                        Text(row.displayName)
                            .fontWeight(.medium)
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
                Text("\(row.shellName) · \(row.directoryLabel)")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .padding(.vertical, 3)
        .contentShape(.rect)
        .background(rowBackground)
        .onTapGesture { reveal() }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
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
        Menu("Color", systemImage: "paintpalette") {
            Button("None") { setColor(nil) }
            ForEach(TerminalSessionColor.allCases, id: \.self) { color in
                Button(color.displayName) { setColor(color) }
            }
        }
        Divider()
        Button("Reveal", systemImage: "eye") { reveal() }
        if let hide {
            Button("Hide Tab", systemImage: "eye.slash") { hide() }
        }
        Divider()
        Button("Close", systemImage: "xmark.circle", role: .destructive) { close() }
    }

    private var statusTint: Color {
        switch row.status {
        case .running: theme.palette.accent
        case .idle: theme.palette.textSecondary
        case .bell: theme.palette.accent
        case .exited: theme.palette.textMuted
        }
    }

    /// A subtle attention wash (never the only signal — the glyph/label
    /// already say "Needs attention") for an unselected belling row;
    /// selection tint always wins when both apply.
    private var rowBackground: Color {
        if isSelected { return theme.palette.selection }
        if row.needsAttention { return theme.palette.accentSoft }
        return .clear
    }

    private var accessibilityText: String {
        var parts = [
            row.displayName,
            TerminalSessionPresentation.label(row.status),
            row.shellName,
            row.directoryLabel,
        ]
        if row.isParked { parts.append("hidden") }
        return parts.joined(separator: ", ")
    }
}
