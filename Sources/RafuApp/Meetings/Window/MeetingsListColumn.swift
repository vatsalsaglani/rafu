import RafuCore
import SwiftUI

/// The left column of the Meetings window: the pinned "New Recording" row,
/// then the meetings in the groups Today, Yesterday and Earlier. It pins
/// to the top; the empty state expands and centres. The arrow keys move the
/// selection while the list has focus.
struct MeetingsListColumn: View {
    let feature: MeetingsFeature
    let model: MeetingsWindowModel
    let commands: MeetingsWindowCommands
    let onRename: (MeetingSummaryRecord) -> Void
    let onDelete: (MeetingSummaryRecord) -> Void

    @FocusState private var isListFocused: Bool
    @Environment(\.rafuTheme) private var theme

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingsNewRecordingRow(session: session) {
                session.windowSelection = nil
                isListFocused = true
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.top, RafuMetrics.space2)
            .padding(.bottom, RafuMetrics.space1)
            listBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var listBody: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: RafuMetrics.space2) {
                Text("The meetings could not be read.")
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.retry() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Read the meetings again")
            }
            .padding(RafuMetrics.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.isEmpty {
                RafuPanelEmptyState(
                    icon: "waveform", title: "No meetings yet",
                    message: "Your recordings show here.", compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.sections) { section in
                    MeetingsListSectionLabel(title: section.group.rawValue)
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.bottom, RafuMetrics.space2)
        }
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .accessibilityLabel("Meetings")
    }

    private func rowView(_ row: MeetingsListRowModel) -> some View {
        let isSelected = session.windowSelection == row.id
        return MeetingsListRowButton(
            meeting: row.id, title: row.title, readyLine: row.subtitle,
            state: row.summary.state, session: session, isSelected: isSelected
        ) {
            session.windowSelection = row.id
            isListFocused = true
        }
        .contextMenu { rowMenu(row) }
    }

    @ViewBuilder
    private func rowMenu(_ row: MeetingsListRowModel) -> some View {
        Button("Rename…") { onRename(row.summary) }
        if MeetingsWorkspacePresentation.canRetry(
            state: row.summary.state, meeting: row.id, recorder: session.recorderState,
            step: session.processing[row.id])
        {
            Button("Try Again") { commands.retryProcessing(row.id) }
        }
        Divider()
        Button("Delete…", role: .destructive) { onDelete(row.summary) }
            .disabled(!commands.canDelete(row.id))
    }

    private func moveSelection(by step: Int) -> KeyPress.Result {
        let next = MeetingsWindowPresentation.movedSelection(
            session.windowSelection, by: step, in: model.orderedIDs)
        guard next != session.windowSelection else { return .ignored }
        session.windowSelection = next
        return .handled
    }
}

/// A group label of the list: "Today", "Yesterday", "Earlier".
private struct MeetingsListSectionLabel: View {
    let title: String

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.palette.textMuted)
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.top, RafuMetrics.space3)
            .padding(.bottom, RafuMetrics.space1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The pinned first row: it clears the selection, so the start page shows.
/// It is not active while a recording runs.
private struct MeetingsNewRecordingRow: View {
    let session: MeetingsSessionModel
    let action: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let isBusy = MeetingsWindowPresentation.isRecorderBusy(session.recorderState)
        RafuHoverRow(isSelected: session.windowSelection == nil && !isBusy) {
            Button(action: action) {
                HStack(spacing: RafuMetrics.space2) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text("New Recording")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RafuMetrics.space2)
                .padding(.vertical, RafuMetrics.space1 + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .disabled(isBusy)
        .help(isBusy ? "A recording is in progress" : "Show the start page")
        .accessibilityHint(isBusy ? "A recording is in progress" : "Shows the start page")
    }
}
