import RafuCore
import SwiftUI

/// The History navigator (X12): Claude Code and Codex sessions on this Mac,
/// "This Workspace" first, then "All Projects". The index loads the first
/// time this panel appears, never earlier.
struct AgentHistoryPanelView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(spacing: 0) {
            RafuUtilityPanelHeader(
                icon: WorkspaceNavigatorMode.history.symbolName,
                title: "History",
                closeAccessibilityLabel: "Close History",
                onClose: { session.isSidebarCollapsed = true }
            ) {
                AgentHistoryRefreshButton(store: AgentHistoryStore.shared)
            }
            AgentHistoryPanelContent(
                session: session, state: session.agentHistory, store: AgentHistoryStore.shared
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { AgentHistoryStore.shared.loadIfNeeded() }
    }
}

private struct AgentHistoryRefreshButton: View {
    let store: AgentHistoryStore

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .disabled(store.isScanning)
            .help("Refresh Agent History")
            .accessibilityLabel("Refresh Agent History")
    }
}

private struct AgentHistoryPanelContent: View {
    @Bindable var session: WorkspaceSession
    @Bindable var state: AgentHistoryWindowState
    let store: AgentHistoryStore
    @Environment(\.rafuTheme) private var theme
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            AgentHistoryControls(
                state: state, isQueryFocused: $isQueryFocused, searchMessages: searchMessages)
            Divider().overlay(theme.palette.borderSubtle)
            results
        }
        .onChange(of: state.searchFocusRequest, initial: true) { _, request in
            guard request > state.handledSearchFocusRequest else { return }
            state.handledSearchFocusRequest = request
            isQueryFocused = true
        }
        .onChange(of: state.query) { _, _ in
            if state.messageMatchesQuery != nil || state.isSearchingMessages {
                state.clearMessageSearch()
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let sections = state.sections(
            for: store.index, generation: store.lastScanDate,
            workspaceRoots: session.agentHistoryWorkspaceRoots)
        if store.index.sessions.isEmpty {
            emptyIndex
        } else if sections.sessionCount == 0 {
            RafuPanelEmptyState(
                icon: "magnifyingglass",
                title: "No Matching Sessions",
                message: state.query.isEmpty
                    ? "No sessions for this agent."
                    : "No session title, folder, or branch matches."
            ) {
                if !state.query.isEmpty, state.messageMatchesQuery == nil {
                    Button("Search Message Text", action: searchMessages)
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .disabled(state.isSearchingMessages)
                }
            }
        } else {
            AgentHistorySessionList(session: session, state: state, sections: sections)
        }
    }

    @ViewBuilder
    private var emptyIndex: some View {
        switch store.phase {
        case .idle, .scanning:
            ProgressView("Reading agent history…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            RafuPanelEmptyState(
                icon: "exclamationmark.triangle", title: "History Unavailable", message: message
            ) {
                Button("Try Again") { store.refresh() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        case .ready:
            RafuPanelEmptyState(
                icon: WorkspaceNavigatorMode.history.symbolName,
                title: "No Agent History",
                message: store.showsClaudeCode || store.showsCodex
                    ? "Claude Code and Codex sessions on this Mac appear here."
                    : "Turn on Claude Code or Codex history in Settings > Agents."
            )
        }
    }

    private func searchMessages() {
        let sessions = store.index.filtered(provider: state.providerFilter, query: "").sessions
        state.searchMessages(in: sessions)
    }
}

private struct AgentHistoryControls: View {
    @Bindable var state: AgentHistoryWindowState
    var isQueryFocused: FocusState<Bool>.Binding
    let searchMessages: () -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField("Search history", text: $state.query)
                    .textFieldStyle(.plain)
                    .rafuField(isFocused: isQueryFocused.wrappedValue)
                    .focused(isQueryFocused)
                    .onSubmit(searchMessages)
                    .help(
                        "Filter by title, folder, or branch. Press Return to search message text.")
                Button(
                    "Search Message Text", systemImage: "text.magnifyingglass",
                    action: searchMessages
                )
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .disabled(state.query.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Search Message Text")
                .accessibilityLabel("Search message text")
            }
            RafuSegmentedPicker(
                items: AgentHistoryProviderFilter.allCases, selection: $state.providerFilter,
                fillsWidth: true
            ) { $0.title }
            .accessibilityLabel("Agent")
            messageSearchStatus
        }
        .padding(RafuMetrics.utilityBodyInset)
    }

    @ViewBuilder
    private var messageSearchStatus: some View {
        if state.isSearchingMessages {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching message text…")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
                Button("Stop") { state.clearMessageSearch() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        } else if state.messageMatchesQuery != nil {
            HStack(spacing: 6) {
                Text(messageMatchSummary)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
                Button("Clear") { state.clearMessageSearch() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
    }

    private var messageMatchSummary: String {
        let count = state.messageMatchesForCurrentQuery().count
        return count == 1
            ? "1 session matches in message text"
            : "\(count) sessions match in message text"
    }
}

/// The lazy session list. Rows are plain buttons so every row is reachable
/// with the keyboard; actions are in each row's context menu and in the tab.
private struct AgentHistorySessionList: View {
    let session: WorkspaceSession
    @Bindable var state: AgentHistoryWindowState
    let sections: AgentHistorySections

    var body: some View {
        List {
            if !sections.workspace.isEmpty {
                Section("This Workspace") {
                    ForEach(sections.workspace) { project in
                        if sections.workspace.count > 1 {
                            AgentHistoryProjectLabel(project: project)
                        }
                        ForEach(project.sessions) { summary in
                            row(summary)
                        }
                    }
                }
            }
            if !sections.others.isEmpty {
                Section(sections.workspace.isEmpty ? "Projects" : "All Projects") {
                    ForEach(sections.others) { project in
                        DisclosureGroup(isExpanded: expansion(for: project.id)) {
                            ForEach(project.sessions) { summary in
                                row(summary)
                            }
                        } label: {
                            AgentHistoryProjectLabel(project: project)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func row(_ summary: AgentHistorySessionSummary) -> some View {
        AgentHistorySessionRow(
            summary: summary,
            isOpen: state.visibleSession?.key == summary.key,
            session: session,
            open: { session.openAgentSession(summary) }
        )
        .contextMenu {
            AgentHistorySessionMenuItems(session: session, summary: summary, includesOpen: true)
        }
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { !state.query.isEmpty || state.expandedProjects.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    state.expandedProjects.insert(id)
                } else {
                    state.expandedProjects.remove(id)
                }
            }
        )
    }
}

private struct AgentHistoryProjectLabel: View {
    let project: AgentHistoryProject
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.path == nil ? "questionmark.folder" : "folder")
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(project.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            RafuChip(text: "\(project.sessions.count)", monospacedDigit: true)
        }
        .help(project.path ?? project.displayName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.displayName), \(project.sessions.count) sessions")
    }
}

private struct AgentHistorySessionRow: View {
    let summary: AgentHistorySessionSummary
    let isOpen: Bool
    let session: WorkspaceSession
    let open: () -> Void
    @Environment(\.rafuTheme) private var theme
    /// This row's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the row's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    var body: some View {
        // Not a `Button`, for the same reason as a Files-tree file row
        // (`WorkspaceFileTreeItem.interactiveRow`): the `.onDrag` lift
        // gesture must be the row's only press owner. One tap handler keeps
        // single-click opening; focus, Return/Space, and the VoiceOver
        // button element are restored below.
        HStack(alignment: .top, spacing: 7) {
            AgentIconView(cli: summary.provider.cli, size: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.callout)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                AgentHistorySessionMetadata(summary: summary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseSelection, style: .continuous)
                .fill(isOpen ? theme.palette.selection : Color.clear)
        )
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.return, .space]) { _ in
            open()
            return .handled
        }
        .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        // Drag a row onto an Ensemble to resume the session there. The
        // payload holds only the provider and the session id.
        .onDrag(
            {
                DragDiag.note("source history-row onDrag")
                session.beginDragSourceTracking(dragToken)
                session.activeEnsembleDragHint = .agentSession
                return CanvasBoardDragPayload.agentSession(
                    provider: summary.key.provider, sessionID: summary.key.sessionID
                ).makeItemProvider()
            },
            preview: {
                RafuDragPreviewLabel(
                    icon: AgentIconView(cli: summary.provider.cli, size: 13), title: summary.title)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the transcript in a tab")
        .accessibilityAction { open() }
    }

    private var accessibilityText: String {
        var parts = [summary.title, summary.provider.displayName]
        if let branch = summary.gitBranch { parts.append("branch \(branch)") }
        return parts.joined(separator: ", ")
    }
}

/// "2 hours ago · main · 14 messages" under a session title.
struct AgentHistorySessionMetadata: View {
    let summary: AgentHistorySessionSummary
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Text(summary.activityDate, format: .relative(presentation: .named))
            if let branch = summary.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(messageCountText)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(theme.palette.textSecondary)
        .lineLimit(1)
    }

    private var messageCountText: String {
        let prefix = summary.isMessageCountEstimated ? "~" : ""
        return summary.messageCount == 1
            ? "\(prefix)1 message" : "\(prefix)\(summary.messageCount) messages"
    }
}

/// The session actions, shared by the row context menu and the tab's More
/// menu. Menus use system symbols only (vendor SVGs do not draw in NSMenu).
struct AgentHistorySessionMenuItems: View {
    let session: WorkspaceSession
    let summary: AgentHistorySessionSummary
    let includesOpen: Bool

    var body: some View {
        if includesOpen {
            Button("Open Transcript", systemImage: "doc.text") {
                session.openAgentSession(summary)
            }
        }
        Button("Resume in Terminal", systemImage: "terminal") {
            session.resumeAgentSession(summary)
        }
        Button("Resume in Ensemble", systemImage: "rectangle.3.group") {
            session.resumeAgentSessionInEnsemble(summary)
        }
        AgentHandoffMenuItems(session: session, summary: summary)
        Divider()
        Button("Reveal Transcript in Finder", systemImage: "folder") {
            session.revealAgentTranscript(summary)
        }
        Button("Copy Session ID", systemImage: "doc.on.doc") {
            session.copyAgentSessionID(summary)
        }
        Button("Open Project Folder", systemImage: "macwindow.badge.plus") {
            session.openAgentProjectFolder(summary)
        }
        .disabled(summary.projectPath == nil)
    }
}
