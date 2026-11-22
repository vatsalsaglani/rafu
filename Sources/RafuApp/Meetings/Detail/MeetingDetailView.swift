import RafuCore
import SwiftUI

/// The view of one meeting, in the Meetings window and in a workspace tab:
/// a conversation column and a Transcript | Share sidebar. In a narrow view
/// the sidebar becomes a third segment over the same column.
struct MeetingDetailView: View {
    let feature: MeetingsFeature
    let meeting: MeetingID

    var body: some View {
        Group {
            if !feature.availability.isAvailable {
                MeetingsPlaceholderView(availability: feature.availability)
            } else if let store = feature.store as? any MeetingLibraryServicing {
                MeetingDetailContent(feature: feature, meeting: meeting, store: store)
                    .id(meeting)
            } else {
                MeetingsPlaceholderView(availability: feature.availability)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The part of the detail view that a narrow layout shows.
nonisolated enum MeetingDetailSection: String, Hashable, CaseIterable, Identifiable {
    case ask
    case transcript
    case share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .transcript: "Transcript"
        case .share: "Share"
        }
    }

    /// Below this width the sidebar becomes a segment over the column.
    static let narrowWidth: CGFloat = 700
}

private struct MeetingDetailReloadKey: Hashable {
    var meeting: MeetingID
    var revision: Int
    var isProcessing: Bool
}

private struct MeetingDetailContent: View {
    let feature: MeetingsFeature
    let meeting: MeetingID

    @State private var model: MeetingDetailModel
    @State private var isNarrow = false
    @State private var sidebarSection: MeetingDetailSection = .transcript
    @State private var narrowSection: MeetingDetailSection = .ask

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

    private var processingStep: MeetingsProcessingStep? {
        feature.session.processing[meeting]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingDetailHeader(model: model)
            Divider()
            if model.summary == nil {
                emptyState
            } else if isNarrow {
                narrowLayout
            } else {
                wideLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: Bool.self) {
            $0.size.width < MeetingDetailSection.narrowWidth
        } action: {
            isNarrow = $0
        }
        .task(
            id: MeetingDetailReloadKey(
                meeting: meeting, revision: feature.session.libraryRevision,
                isProcessing: processingStep != nil)
        ) {
            await model.reload()
        }
        .task { await model.refreshAvailability() }
    }

    @ViewBuilder
    private var emptyState: some View {
        RafuPanelEmptyState(
            icon: "waveform.and.person.filled", title: "Meeting",
            message: model.loadFailed ? "Rafu cannot read this meeting." : "Loading the meeting…",
            compact: true
        ) { EmptyView() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            conversation
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                RafuSegmentedPicker(
                    items: [MeetingDetailSection.transcript, .share], selection: $sidebarSection,
                    fillsWidth: true
                ) { $0.title }
                .padding(RafuMetrics.space2)
                sidebar(sidebarSection)
            }
            .frame(width: 320)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuSegmentedPicker(
                items: MeetingDetailSection.allCases, selection: $narrowSection, fillsWidth: true
            ) { $0.title }
            .padding(RafuMetrics.space2)
            switch narrowSection {
            case .ask: conversation
            case .transcript, .share: sidebar(narrowSection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var conversation: some View {
        MeetingConversationColumn(
            model: model, processingLabel: processingStep?.label, onCite: openCitation)
    }

    @ViewBuilder
    private func sidebar(_ section: MeetingDetailSection) -> some View {
        switch section {
        case .share:
            MeetingShareSidebar(feature: feature, meeting: meeting)
        case .ask, .transcript:
            MeetingTranscriptSidebar(
                model: model, isProcessing: processingStep != nil,
                onRemake: { engine in feature.session.remakeText(meeting, with: engine) })
        }
    }

    private func openCitation(_ turn: MeetingTurnID) {
        if isNarrow {
            narrowSection = .transcript
        } else {
            sidebarSection = .transcript
        }
        Task { await model.reveal(turn) }
    }
}

/// Title, date and length, the engines and where the text was made.
private struct MeetingDetailHeader: View {
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Text(model.summary?.title ?? "Meeting")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let summary = model.summary {
                Text(
                    MeetingDetailPresentation.dateLine(
                        startDate: summary.startDate, duration: summary.duration)
                )
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                if summary.engines.textEngine != nil {
                    Text(MeetingDetailPresentation.engineLine(summary.engines))
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
            Label("Rafu wrote this transcript on this Mac.", systemImage: "lock.laptopcomputer")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
