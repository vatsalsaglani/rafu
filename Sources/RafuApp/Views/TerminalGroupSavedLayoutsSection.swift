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

    /// Every row of the section (header, state line, saved layout) is one
    /// fixed height, so the list that holds only this section can be sized
    /// exactly.
    static let rowHeight: CGFloat = 26
    /// With no terminals, the section is the panel's pinned footer. It shows
    /// at most this many saved layouts before it scrolls.
    static let maximumFooterRecordRows = 6

    /// The height of the footer list when the panel has no terminal rows:
    /// the header, plus the state line or the saved layouts when open.
    static func footerHeight(state: State, isExpanded: Bool, recordCount: Int) -> CGFloat {
        guard isExpanded else { return rowHeight }
        let bodyRows = state == .records ? min(recordCount, maximumFooterRecordRows) : 1
        return rowHeight * CGFloat(1 + bodyRows)
    }
}

/// The Saved Terminal Groups section of the Terminals panel's native list.
/// The saved-layout library is injected as already-observed workspace state.
/// This view never starts store work from `body`; `WorkspaceSession` owns the
/// generation-checked subscription and mutations.
///
/// It is list content: one `Section` whose first row is the collapsible
/// header (a chevron, the title and a plain count). An empty library starts
/// collapsed, so it costs one line. Each saved row is selectable; a click
/// selects it, a double-click or Return opens it; its "···" menu holds Open,
/// Rename…, and Delete…. Delete keeps its own confirmation because it removes
/// the saved layout from the library.
struct TerminalGroupSavedLayoutsSection: View {
    @Bindable var session: WorkspaceSession
    /// The panel's per-window `@SceneStorage` choice ("", "open", "closed").
    /// The panel owns it because it also sizes the footer list from it.
    @Binding var storedExpansion: String
    /// The panel's list selection. A click on a saved row selects it.
    @Binding var selection: String?
    @Environment(\.rafuTheme) private var theme
    @State private var renamingID: SavedTerminalGroupID?
    @State private var renameText = ""
    @State private var deletionCandidate: SavedTerminalGroupRecord?

    var body: some View {
        let state = TerminalGroupSavedLayoutsPresentation.state(
            hasWorkspace: session.rootURL != nil, isLoading: session.isTerminalGroupStoreLoading,
            error: session.terminalGroupStoreError, recordCount: session.savedTerminalGroups.count)
        let isExpanded = TerminalGroupSavedLayoutsPresentation.isExpanded(
            userChoice: TerminalGroupSavedLayoutsPresentation.userChoice(
                fromStored: storedExpansion),
            state: state)
        Section {
            sectionHeader(isExpanded: isExpanded)
                .tag(TerminalsPanelListModel.savedHeaderRowID)
                .modifier(SavedSectionRowInsets())
                // `SavedTerminalGroupRecord` is not `Identifiable`, so this
                // keeps the Boolean presentation and reads the candidate
                // inside. The header row always exists, so it hosts the sheet.
                .sheet(
                    isPresented: Binding(
                        get: { deletionCandidate != nil },
                        set: { if !$0 { deletionCandidate = nil } })
                ) {
                    deleteConfirmation
                }
            if isExpanded { content(state) }
        }
    }

    @ViewBuilder
    private var deleteConfirmation: some View {
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

    /// One row for the whole header line: a 9 pt chevron, the title and the
    /// plain count. Plain content with one tap handler, not a `Button`, so a
    /// click is never held back; the panel maps Return, Space, Left and
    /// Right on the selected header to open and close.
    private func sectionHeader(isExpanded: Bool) -> some View {
        let count = session.savedTerminalGroups.count
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
            RafuSidebarSectionHeader(title: "Saved Terminal Groups", count: count)
        }
        .padding(.horizontal, RafuMetrics.sidebarTextInset)
        .frame(
            maxWidth: .infinity, minHeight: TerminalGroupSavedLayoutsPresentation.rowHeight,
            alignment: .leading
        )
        .contentShape(.rect)
        .onTapGesture {
            selection = TerminalsPanelListModel.savedHeaderRowID
            storedExpansion = isExpanded ? "closed" : "open"
        }
        .help(isExpanded ? "Collapse Saved Terminal Groups" : "Expand Saved Terminal Groups")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved Terminal Groups, \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction { storedExpansion = isExpanded ? "closed" : "open" }
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
            ForEach(session.savedTerminalGroups, id: \.id) { record in
                let rowID = TerminalsPanelListModel.savedRowID(record.id)
                SavedTerminalGroupRowView(
                    record: record,
                    isRenaming: renamingID == record.id,
                    isSelected: selection == rowID,
                    renameText: $renameText,
                    isBusy: session.isTerminalGroupStoreMutationInFlight,
                    select: { selection = rowID },
                    open: { session.openSavedTerminalGroup(record.id) },
                    openAndStartAll: {
                        session.openSavedTerminalGroup(record.id, startingAllPanes: true)
                    },
                    beginRename: { beginRename(record) },
                    commitRename: { commitRename(record.id) },
                    cancelRename: cancelRename,
                    requestDelete: { deletionCandidate = record }
                )
                .tag(rowID)
                .modifier(SavedSectionRowInsets())
            }
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

    /// A state line is not a choice, so the list never selects it.
    private func stateRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(theme.palette.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(
                maxWidth: .infinity, minHeight: TerminalGroupSavedLayoutsPresentation.rowHeight,
                alignment: .leading
            )
            .padding(.horizontal, RafuMetrics.sidebarTextInset)
            .help(text)
            .accessibilityLabel(text)
            .selectionDisabled()
            .modifier(SavedSectionRowInsets())
    }
}

/// Rows of this section own their insets (the text edge comes from their own
/// padding), and the plain list draws no separators.
private struct SavedSectionRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}

/// One saved layout. A click selects it; a double-click or Return opens it;
/// every other action is in the neutral "···" menu, so Delete… is never next
/// to Open.
private struct SavedTerminalGroupRowView: View {
    let record: SavedTerminalGroupRecord
    let isRenaming: Bool
    let isSelected: Bool
    @Binding var renameText: String
    let isBusy: Bool
    let select: () -> Void
    let open: () -> Void
    /// Opens the layout and starts every restartable pane. Only this
    /// explicit item starts shells; Open, a double-click, and Return do not.
    let openAndStartAll: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let requestDelete: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    @FocusState private var isRenameFieldFocused: Bool

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
                    .focused($isRenameFieldFocused)
                    .onAppear { isRenameFieldFocused = true }
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
                Button("Open and Start All Panes", action: openAndStartAll)
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
        .frame(minHeight: TerminalGroupSavedLayoutsPresentation.rowHeight)
        // The list draws no native highlight (`rafuQuietListSelection`):
        // this row draws the shared quiet fill, full width like its hover.
        .rafuRowSelection(isSelected: isSelected, isHovering: isHovering, cornerRadius: 0)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // One tap handler (docs/references/swiftui-macos-click-latency.md):
        // a click selects at once; the second click of a double-click also
        // opens. A single click never starts anything.
        .onTapGesture {
            select()
            guard TabClickIntent.current() == .selectAndRename, !isBusy, !isRenaming else {
                return
            }
            open()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved Terminal Group, \(record.name.rawValue)")
        .accessibilityValue(TerminalNaming.paneCountLabel(record.panes.count))
        .accessibilityAction(named: "Open") { if !isBusy { open() } }
        .accessibilityAction(named: "Open and Start All") { if !isBusy { openAndStartAll() } }
        .accessibilityAction(named: "Rename") { if !isBusy { beginRename() } }
        .accessibilityAction(named: "Delete") { if !isBusy { requestDelete() } }
    }
}
