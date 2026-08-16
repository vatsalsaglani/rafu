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
struct TerminalGroupSavedLayoutsSection: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
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
                            HStack(spacing: RafuMetrics.space2) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.name.rawValue).font(.caption.weight(.medium))
                                    Text("\(record.panes.count) panes")
                                        .font(.caption2)
                                        .foregroundStyle(theme.palette.textMuted)
                                }
                                Spacer(minLength: 0)
                                Button("Open") { session.openSavedTerminalGroup(record.id) }
                                    .buttonStyle(.borderless)
                                    .disabled(session.isTerminalGroupStoreMutationInFlight)
                                Button("Delete", role: .destructive) {
                                    session.deleteSavedTerminalGroup(record.id)
                                }
                                .buttonStyle(.borderless)
                                .disabled(session.isTerminalGroupStoreMutationInFlight)
                            }
                            .padding(.horizontal, RafuMetrics.utilityBodyInset)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Saved Terminal Group, \(record.name.rawValue)")
                            .accessibilityValue("\(record.panes.count) panes")
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, RafuMetrics.space2)
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
