import RafuCore
import SwiftUI

/// The read-only "Agent Session" editor tab: one transcript, newest entry
/// last. The model (and so the parsed text) belongs to this tab and is
/// released when the tab closes.
struct AgentSessionPane: View {
    let reference: AgentSessionTabReference
    let model: AgentTranscriptModel?
    let session: WorkspaceSession
    /// Only the visible tab owns ⌘F.
    let isActive: Bool
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            if let model {
                AgentSessionTranscriptView(model: model, session: session, isActive: isActive)
            } else {
                RafuPanelEmptyState(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "Session Closed",
                    message: "Open the session again from History."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
    }
}

private struct AgentSessionTranscriptView: View {
    @Bindable var model: AgentTranscriptModel
    let session: WorkspaceSession
    let isActive: Bool
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            AgentSessionHeader(model: model, session: session, isActive: isActive)
            if model.isFindPresented {
                AgentSessionFindBar(model: model)
            }
            Divider().overlay(theme.palette.borderSubtle)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading transcript…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            RafuPanelEmptyState(
                icon: "exclamationmark.triangle", title: "Transcript Unavailable", message: message
            ) {
                Button("Try Again") { model.load() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        case .loaded:
            if model.visibleItems.isEmpty {
                RafuPanelEmptyState(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "No Messages",
                    message: "This session has no prompts or replies to show."
                )
            } else {
                AgentTranscriptList(model: model)
            }
        }
    }
}

private struct AgentSessionHeader: View {
    @Bindable var model: AgentTranscriptModel
    let session: WorkspaceSession
    let isActive: Bool
    @Environment(\.rafuTheme) private var theme

    private var summary: AgentHistorySessionSummary { model.summary }

    var body: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space3) {
            AgentIconView(cli: summary.provider.cli, size: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                AgentSessionHeaderDetails(summary: summary)
            }
            Spacer(minLength: RafuMetrics.space2)
            AgentSessionActions(model: model, session: session, isActive: isActive)
        }
        .padding(.horizontal, RafuMetrics.space4)
        .padding(.vertical, RafuMetrics.space3)
        .background(theme.palette.elevatedBackground)
        .accessibilityElement(children: .contain)
    }
}

private struct AgentSessionHeaderDetails: View {
    let summary: AgentHistorySessionSummary
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(summary.provider.displayName)
            if let path = summary.projectPath {
                Text(AgentHistoryPath.abbreviated(path, home: NSHomeDirectory()))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            } else if let label = summary.fallbackProjectLabel {
                Text(label).lineLimit(1).truncationMode(.middle)
            }
            if let branch = summary.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
            }
            if let started = summary.startedAt {
                Text(started, format: .dateTime.day().month().year().hour().minute())
            }
        }
        .font(.caption)
        .foregroundStyle(theme.palette.textSecondary)
    }
}

private struct AgentSessionActions: View {
    @Bindable var model: AgentTranscriptModel
    let session: WorkspaceSession
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button("Find", systemImage: "magnifyingglass") { model.presentFind() }
                .buttonStyle(RafuIconButtonStyle(isActive: model.isFindPresented, size: 26))
                .keyboardShortcut(isActive ? KeyboardShortcut("f", modifiers: .command) : nil)
                .help("Find in Transcript (⌘F)")
                .accessibilityLabel("Find in transcript")
            Button(
                model.showsThinking ? "Hide Thinking" : "Show Thinking",
                systemImage: "brain"
            ) { model.showsThinking.toggle() }
            .buttonStyle(RafuIconButtonStyle(isActive: model.showsThinking, size: 26))
            .help(model.showsThinking ? "Hide Thinking" : "Show Thinking")
            .accessibilityLabel(model.showsThinking ? "Hide thinking" : "Show thinking")
            Menu {
                AgentHistorySessionMenuItems(
                    session: session, summary: model.summary, includesOpen: false)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(RafuIconButtonStyle(size: 26))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Actions")
            .accessibilityLabel("More actions")
            Button("Resume in Terminal", systemImage: "terminal") {
                session.resumeAgentSession(model.summary)
            }
            .buttonStyle(RafuProminentButtonStyle(compact: true))
            .help("Open a terminal in the session folder and resume this session")
        }
    }
}

private struct AgentSessionFindBar: View {
    @Bindable var model: AgentTranscriptModel
    @Environment(\.rafuTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find in transcript", text: $model.findQuery)
                .textFieldStyle(.plain)
                .rafuField(isFocused: isFocused)
                .focused($isFocused)
                .onSubmit { model.nextMatch() }
                .onExitCommand { model.dismissFind() }
                .frame(maxWidth: 320)
            Text(matchText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.palette.textSecondary)
            Button("Previous Match", systemImage: "chevron.up") { model.previousMatch() }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .disabled(model.findMatches.isEmpty)
                .help("Previous Match")
            Button("Next Match", systemImage: "chevron.down") { model.nextMatch() }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .disabled(model.findMatches.isEmpty)
                .help("Next Match (Return)")
            Spacer()
            Button("Close Find", systemImage: "xmark") { model.dismissFind() }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("Close Find (Esc)")
        }
        .padding(.horizontal, RafuMetrics.space4)
        .padding(.vertical, 6)
        .background(theme.palette.elevatedBackground)
        .onAppear { isFocused = true }
        .onChange(of: model.findFocusRequest) { _, _ in isFocused = true }
    }

    private var matchText: String {
        if model.findQuery.isEmpty { return "" }
        guard !model.findMatches.isEmpty else { return "No matches" }
        let position = (model.currentMatchPosition ?? 0) + 1
        return "\(position) of \(model.findMatches.count)"
    }
}

/// A lazy column of entries. Scrolls to Find matches.
private struct AgentTranscriptList: View {
    @Bindable var model: AgentTranscriptModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RafuMetrics.space3) {
                    if let truncation = model.transcript?.truncation {
                        AgentTranscriptTruncationNotice(reason: truncation)
                    }
                    ForEach(model.visibleItems) { item in
                        AgentTranscriptItemRow(
                            item: item,
                            provider: model.summary.provider,
                            isExpanded: model.expandedItems.contains(item.id),
                            matchState: matchState(for: item.id),
                            toggle: { model.toggleExpanded(item.id) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, RafuMetrics.space5)
                .padding(.vertical, RafuMetrics.space4)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func matchState(for id: Int) -> AgentTranscriptItemRow.MatchState {
        if model.currentMatchID == id { return .current }
        return model.findMatches.contains(id) ? .match : .none
    }
}

private struct AgentTranscriptTruncationNotice: View {
    let reason: AgentTranscript.TruncationReason
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(theme.palette.textSecondary)
            .padding(RafuMetrics.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                    .fill(theme.palette.cardBackground)
            )
    }

    private var text: String {
        switch reason {
        case .byteLimit:
            "This session is very large. Rafu shows its first 20 MB only."
        case .itemLimit:
            "This session is very long. Rafu shows its first 5,000 entries only."
        }
    }
}
