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
}

/// The saved-layout library is injected as already-observed workspace state.
/// This view never starts store work from `body`; `WorkspaceSession` owns the
/// generation-checked subscription and mutations.
///
/// Each row opens on double-click or Return; its "···" menu holds Open,
/// Rename…, and Delete…. Delete keeps its own confirmation because it removes
/// the saved layout from the library.
struct TerminalGroupSavedLayoutsSection: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
    @State private var renamingID: SavedTerminalGroupID?
    @State private var renameText = ""
    @State private var deletionCandidate: SavedTerminalGroupRecord?

    var body: some View {
        let state = TerminalGroupSavedLayoutsPresentation.state(
            hasWorkspace: session.rootURL != nil, isLoading: session.isTerminalGroupStoreLoading,
            error: session.terminalGroupStoreError, recordCount: session.savedTerminalGroups.count)
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Divider().overlay(theme.palette.borderSubtle)
            Text("Saved Terminal Groups")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, RafuMetrics.utilityBodyInset)

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
                stateRow("No saved Terminal Groups.", symbol: "bookmark")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, RafuMetrics.space2)
        .confirmationDialog(
            deletionCandidate.map { "Delete \u{201C}\($0.name.rawValue)\u{201D}?" }
                ?? "Delete Saved Terminal Group?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { record in
            Button("Delete", role: .destructive) {
                session.deleteSavedTerminalGroup(record.id)
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { _ in
            Text("This removes the saved layout. Open terminal groups are not closed.")
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
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
            .padding(.horizontal, RafuMetrics.utilityBodyInset)
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
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Saved layout name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.caption.weight(.medium))
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                } else {
                    Text(record.name.rawValue)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(TerminalNaming.paneCountLabel(record.panes.count))
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
            }
            Spacer(minLength: 0)
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
        .padding(.horizontal, RafuMetrics.utilityBodyInset)
        .padding(.vertical, RafuMetrics.space1)
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
