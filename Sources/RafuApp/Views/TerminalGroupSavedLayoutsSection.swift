import SwiftUI

nonisolated enum TerminalGroupSavedLayoutsPresentation {
    enum State: Equatable {
        case workspaceRequired
        case loading
        case empty
        case error(String)
        case records
    }

    static func state(
        hasWorkspace: Bool, isLoading: Bool, error: String?, recordCount: Int
    ) -> State {
        if let error { return .error(error) }
        guard hasWorkspace else { return .workspaceRequired }
        if isLoading { return .loading }
        return recordCount == 0 ? .empty : .records
    }

    /// Whether the section is open. The user's own choice wins; with no
    /// choice, an empty library starts collapsed (one quiet header line) and
    /// a non-empty one starts open. A load error always opens it, so the
    /// message is never hidden.
    static func isExpanded(userChoice: Bool?, state: State) -> Bool {
        if case .error = state { return true }
        if let userChoice { return userChoice }
        return state == .records
    }

    /// The stored per-window choice: "" (none), "open", or "closed".
    static func userChoice(fromStored raw: String) -> Bool? {
        switch raw {
        case "open": true
        case "closed": false
        default: nil
        }
    }
}

/// The saved-layout library is injected as already-observed workspace state.
/// This view never starts store work from `body`; `WorkspaceSession` owns the
/// generation-checked subscription and mutations.
///
/// Each row opens on double-click or Return; its "···" menu holds Open,
/// Rename…, and Delete…. Delete keeps its own confirmation because it removes
/// the saved layout from the library.
///
/// It is the Terminals panel's one pinned footer, so it keeps the hairline
/// above it. Its header is one collapsible line with a count; an empty
/// library starts collapsed, so it costs one line, not a permanent block.
struct TerminalGroupSavedLayoutsSection: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
    @State private var renamingID: SavedTerminalGroupID?
    @State private var renameText = ""
    @State private var deletionCandidate: SavedTerminalGroupRecord?
    /// Per window, so two windows keep their own open/closed choice.
    @SceneStorage("terminals.savedGroups.expanded") private var storedExpansion = ""

    var body: some View {
        let state = TerminalGroupSavedLayoutsPresentation.state(
            hasWorkspace: session.rootURL != nil, isLoading: session.isTerminalGroupStoreLoading,
            error: session.terminalGroupStoreError, recordCount: session.savedTerminalGroups.count)
        let isExpanded = TerminalGroupSavedLayoutsPresentation.isExpanded(
            userChoice: TerminalGroupSavedLayoutsPresentation.userChoice(
                fromStored: storedExpansion),
            state: state)
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Divider().overlay(theme.palette.borderSubtle)
            sectionHeader(isExpanded: isExpanded)
            if isExpanded { content(state) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, RafuMetrics.space1)
        // `SavedTerminalGroupRecord` is not `Identifiable`, so this keeps the
        // Boolean presentation and reads the candidate inside.
        .sheet(
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } })
        ) {
            if let record = deletionCandidate {
                RafuConfirmPopup(
                    symbol: "trash",
                    title: "Delete \u{201C}\(record.name.rawValue)\u{201D}?",
                    message: "This removes the saved layout. Open terminal groups are not closed.",
                    actions: [
                        .init("Delete", isDestructive: true) {
                            session.deleteSavedTerminalGroup(record.id)
                            deletionCandidate = nil
                        }
                    ]
                ) {
                    deletionCandidate = nil
                }
            }
        }
    }

    /// One button for the whole header line: a 9 pt chevron, the title and
    /// the plain count.
    private func sectionHeader(isExpanded: Bool) -> some View {
        let count = session.savedTerminalGroups.count
        return Button {
            storedExpansion = isExpanded ? "closed" : "open"
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                RafuSidebarSectionHeader(title: "Saved Terminal Groups", count: count)
            }
            .padding(.horizontal, RafuMetrics.sidebarTextInset)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse Saved Terminal Groups" : "Expand Saved Terminal Groups")
        .accessibilityLabel("Saved Terminal Groups, \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func content(_ state: TerminalGroupSavedLayoutsPresentation.State) -> some View {
        switch state {
        case .error(let error):
            stateRow(
                "Saved Terminal Groups could not be loaded: \(error)",
                symbol: "exclamationmark.triangle")
        case .workspaceRequired:
            stateRow("Open a workspace to use saved Terminal Groups.", symbol: "folder")
        case .loading:
            stateRow("Loading Saved Terminal Groups…", symbol: "clock")
        case .empty:
            stateRow("Save a group's layout from its ⋯ menu.", symbol: "bookmark")
        case .records:
            ScrollView {
                LazyVStack(spacing: RafuMetrics.space1) {
                    ForEach(session.savedTerminalGroups, id: \.id) { record in
                        SavedTerminalGroupRowView(
                            record: record,
                            isRenaming: renamingID == record.id,
                            renameText: $renameText,
                            isBusy: session.isTerminalGroupStoreMutationInFlight,
                            open: { session.openSavedTerminalGroup(record.id) },
                            beginRename: { beginRename(record) },
                            commitRename: { commitRename(record.id) },
                            cancelRename: cancelRename,
                            requestDelete: { deletionCandidate = record }
                        )
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func beginRename(_ record: SavedTerminalGroupRecord) {
        renameText = record.name.rawValue
        renamingID = record.id
    }

    private func commitRename(_ id: SavedTerminalGroupID) {
        session.renameSavedTerminalGroup(id, to: renameText)
        cancelRename()
    }

    private func cancelRename() {
        renamingID = nil
        renameText = ""
    }

    private func stateRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(theme.palette.textMuted)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .padding(.horizontal, RafuMetrics.sidebarTextInset)
            .accessibilityLabel(text)
    }
}

/// One saved layout. Double-click or Return opens it; every other action is
/// in the neutral "···" menu, so Delete… is never next to Open.
private struct SavedTerminalGroupRowView: View {
    let record: SavedTerminalGroupRecord
    let isRenaming: Bool
    @Binding var renameText: String
    let isBusy: Bool
    let open: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let requestDelete: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            // A leading glyph in the 16 pt slot aligns the name with the
            // terminal rows above. A saved layout is inert: one line.
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            if isRenaming {
                TextField("Saved layout name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
            } else {
                Text(record.name.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            Text(TerminalNaming.paneCountLabel(record.panes.count))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
                .fixedSize()
            Menu {
                Button("Open", action: open)
                    .disabled(isBusy)
                Button("Rename…", action: beginRename)
                    .disabled(isBusy)
                Divider()
                Button("Delete…", role: .destructive, action: requestDelete)
                    .disabled(isBusy)
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
            .help("Actions for \(record.name.rawValue)")
            .accessibilityLabel("Actions for \(record.name.rawValue)")
        }
        .padding(.leading, RafuMetrics.sidebarTextInset)
        .padding(.trailing, RafuMetrics.space1)
        .frame(minHeight: 26)
        .background(isHovering ? theme.palette.hover : Color.clear)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // Double-click opens. A single click only hovers, so a stray click
        // never starts anything.
        .onTapGesture(count: 2) {
            if !isBusy && !isRenaming { open() }
        }
        .focusable()
        .onKeyPress(.return) {
            guard !isBusy, !isRenaming else { return .ignored }
            open()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved Terminal Group, \(record.name.rawValue)")
        .accessibilityValue(TerminalNaming.paneCountLabel(record.panes.count))
        .accessibilityAction(named: "Open") { if !isBusy { open() } }
        .accessibilityAction(named: "Rename") { if !isBusy { beginRename() } }
        .accessibilityAction(named: "Delete") { if !isBusy { requestDelete() } }
    }
}
