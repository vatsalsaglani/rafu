import RafuCore
import SwiftUI

/// The view of one ready meeting, the same in the Meetings window and in a
/// workspace tab: the header (title, one meta line, Share and More), then
/// the Notes column and the Ask column side by side at 860 pt or more, or a
/// Notes | Ask picker below that. The window and the tab show the live,
/// processing and failed states with the status views of this package.
struct MeetingView: View {
    let feature: MeetingsFeature
    let meeting: MeetingID

    var body: some View {
        Group {
            if !feature.availability.isAvailable {
                MeetingsPlaceholderView(availability: feature.availability)
            } else if let store = feature.store as? any MeetingLibraryServicing {
                MeetingViewContent(feature: feature, meeting: meeting, store: store)
                    .id(meeting)
            } else {
                MeetingsPlaceholderView(availability: feature.availability)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Wide (Notes and Ask side by side) or narrow (a Notes | Ask picker).
nonisolated enum MeetingViewLayout: Hashable, Sendable {
    case wide
    case narrow

    /// At this content width or more, the two columns show side by side.
    static let wideMinimumWidth: CGFloat = 860
    static let askColumnWidth: CGFloat = 380
    static let notesMinimumWidth: CGFloat = 440

    static func layout(width: CGFloat) -> MeetingViewLayout {
        width >= wideMinimumWidth ? .wide : .narrow
    }
}

/// The part that a narrow layout shows.
nonisolated enum MeetingViewPane: String, Hashable, CaseIterable, Identifiable, Sendable {
    case notes
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .ask: "Ask"
        }
    }
}

/// A Rafu popup of the meeting view.
private enum MeetingViewPopup: Identifiable, Hashable {
    case rename
    case delete
    case remake(MeetingTextEngineID)

    var id: Self { self }
}

private struct MeetingViewContent: View {
    let feature: MeetingsFeature
    let meeting: MeetingID

    @State private var model: MeetingDetailModel
    @State private var layout: MeetingViewLayout = .wide
    @State private var pane: MeetingViewPane = .notes
    @State private var searchFocusRequest = 0
    @State private var popup: MeetingViewPopup?
    @State private var shareResult: String?

    init(feature: MeetingsFeature, meeting: MeetingID, store: any MeetingLibraryServicing) {
        self.feature = feature
        self.meeting = meeting
        let session = feature.session
        _model = State(
            initialValue: MeetingDetailModel(
                meeting: meeting, store: store, runner: feature.agentRunner,
                textEngines: feature.textEngines,
                onLibraryChanged: { session.noteLibraryChanged() }))
    }

    private var session: MeetingsSessionModel { feature.session }
    private var commands: MeetingsWindowCommands { MeetingsWindowCommands(session: session) }

    private var summaryContext: MeetingSummaryContext {
        let session = session
        let meeting = meeting
        let running = session.agentRuns[meeting]?.first { $0.kind == .summary }?.cli
        return MeetingSummaryContext(
            state: session.summaryStates[meeting] ?? .none,
            writingCLI: running ?? model.summaryNotes?.cli ?? model.agent,
            make: { session.makeSummary(meeting) },
            cancel: { session.cancelSummary(meeting) })
    }

    private var isRunningElsewhere: Bool {
        !model.askState.isRunning && session.isAgentRunning(.question, for: meeting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingHeaderView(
                feature: feature, model: model,
                isProcessing: session.processing[meeting] != nil,
                canDelete: commands.canDelete(meeting),
                shareResult: shareResult,
                onShareResult: { shareResult = $0 },
                onPopup: { popup = $0 })
            Divider()
            if model.summary == nil {
                emptyState
            } else {
                switch layout {
                case .wide: wideLayout
                case .narrow: narrowLayout
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: MeetingViewLayout.self) {
            MeetingViewLayout.layout(width: $0.size.width)
        } action: {
            layout = $0
        }
        .background { searchShortcut }
        .task(id: session.libraryRevision) { await model.reload() }
        .task { await model.refreshEngines() }
        .task { await model.refreshAgents() }
        .task {
            if session.summaryStates[meeting] == nil { session.refreshSummaryState(meeting) }
        }
        .task(id: session.summaryStates[meeting]) { await model.loadSummaryNotes() }
        .task(id: shareResult) {
            guard shareResult != nil else { return }
            try? await Task.sleep(for: MeetingDetailPresentation.shareResultSeconds)
            guard !Task.isCancelled else { return }
            shareResult = nil
        }
        // `.id(meeting)` above makes a new content view for each meeting,
        // so this covers a change of meeting too.
        .onDisappear { model.cancelRunsOnDisappear() }
        .background { popupHost }
    }

    @ViewBuilder
    private var emptyState: some View {
        RafuPanelEmptyState(
            icon: "waveform", title: "Meeting",
            message: model.loadFailed ? "Rafu cannot read this meeting." : "Loading the meeting…",
            compact: true
        ) { EmptyView() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            notesColumn
                .frame(
                    minWidth: MeetingViewLayout.notesMinimumWidth, maxWidth: .infinity,
                    maxHeight: .infinity, alignment: .top)
            Divider()
            askColumn
                .frame(width: MeetingViewLayout.askColumnWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuSegmentedPicker(
                items: MeetingViewPane.allCases, selection: $pane, fillsWidth: true
            ) { $0.title }
            .padding(.horizontal, RafuMetrics.space5)
            .padding(.vertical, RafuMetrics.space2)
            switch pane {
            case .notes: notesColumn
            case .ask: askColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var notesColumn: some View {
        MeetingNotesColumn(
            model: model, summary: summaryContext, searchFocusRequest: searchFocusRequest)
    }

    private var askColumn: some View {
        MeetingAskColumn(
            model: model, isRunningElsewhere: isRunningElsewhere, onCite: openCitation)
    }

    /// Command-F: shows Notes (in a narrow layout) and focuses the
    /// transcript search.
    private var searchShortcut: some View {
        Button("Search the Transcript") {
            pane = .notes
            searchFocusRequest += 1
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(model.summary == nil)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// A citation shows Notes (in a narrow layout), loads the page,
    /// scrolls the transcript and marks the line for two seconds.
    private func openCitation(_ turn: MeetingTurnID) {
        if layout == .narrow { pane = .notes }
        Task { await model.reveal(turn) }
    }

    private var popupHost: some View {
        Color.clear
            .sheet(item: $popup) { popup in
                switch popup {
                case .rename:
                    RafuTextFieldPopup(
                        symbol: "pencil", title: "Rename Meeting",
                        subtitle: "Enter a new title for this meeting.", fieldLabel: "Title",
                        initialText: model.summary?.title ?? "", actionTitle: "Rename",
                        validate: {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Enter a title." : nil
                        },
                        cancel: { self.popup = nil }
                    ) { title in
                        self.popup = nil
                        Task { await model.renameMeeting(to: title) }
                    }
                case .delete:
                    RafuConfirmPopup(
                        symbol: "trash",
                        title: MeetingsWorkspacePresentation.deleteConfirmationTitle,
                        message: "The audio and the transcript are removed. You cannot undo this.",
                        actions: [
                            .init("Delete", isDestructive: true) {
                                self.popup = nil
                                commands.delete(meeting)
                            }
                        ]
                    ) {
                        self.popup = nil
                    }
                case .remake(let engine):
                    RafuConfirmPopup(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Make the text again?",
                        message: MeetingDetailPresentation.remakeConfirmation(engine),
                        actions: [
                            .init("Make the Text Again", isDestructive: true) {
                                self.popup = nil
                                session.remakeText(meeting, with: engine)
                            }
                        ]
                    ) {
                        self.popup = nil
                    }
                }
            }
    }
}

/// The header: the title (selectable, two lines at most), one meta line,
/// the Share menu and the More menu.
struct MeetingHeaderView: View {
    let feature: MeetingsFeature
    let model: MeetingDetailModel
    let isProcessing: Bool
    let canDelete: Bool
    /// "Copied" or "Exported 12:31", for four seconds.
    let shareResult: String?
    let onShareResult: (String) -> Void
    fileprivate let onPopup: (MeetingViewPopup) -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space3) {
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let meta {
                    HStack(spacing: RafuMetrics.space2) {
                        Text(meta)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let shareResult {
                            Text("· \(shareResult)")
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.summary != nil {
                MeetingShareMenu(feature: feature, meeting: model.meeting, onResult: onShareResult)
                moreMenu
            }
        }
        .padding(.horizontal, RafuMetrics.space5)
        .padding(.top, RafuMetrics.space4)
        .padding(.bottom, RafuMetrics.space3)
    }

    private var title: String {
        MeetingsWorkspacePresentation.displayTitle(model.summary?.title ?? "")
    }

    private var meta: String? {
        guard let summary = model.summary else { return nil }
        return MeetingDetailPresentation.headerMeta(
            start: summary.startDate, duration: summary.duration,
            speakers: MeetingDetailPresentation.headerSpeakers(model.overview, names: model.names))
    }

    private var moreMenu: some View {
        let engines = model.summary?.engines
        let choices = MeetingDetailPresentation.remakeChoices(
            used: engines?.textEngine, available: model.textEngineAvailability)
        return Menu {
            Button("Rename…") { onPopup(.rename) }
            Menu("Make the Text Again With") {
                ForEach(choices, id: \.self) { engine in
                    Button(MeetingDetailPresentation.textEngineName(engine)) {
                        onPopup(.remake(engine))
                    }
                }
            }
            .disabled(choices.isEmpty || isProcessing || !model.isReady)
            if let engines, engines.textEngine != nil {
                Button(MeetingDetailPresentation.engineLine(engines)) {}
                    .disabled(true)
            }
            Divider()
            Button("Delete…") { onPopup(.delete) }
                .disabled(!canDelete)
        } label: {
            Label("More Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(RafuIconButtonStyle(size: 26))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}
