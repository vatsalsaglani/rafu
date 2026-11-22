import RafuCore
import SwiftUI

/// Two lines for one meeting: the title, then the date and the state word or
/// the length. A shape goes with each state, so colour is never the only cue.
struct MeetingsListRowLabel: View {
    let row: MeetingsWorkspaceRow
    let session: MeetingsSessionModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let badge = MeetingsWorkspacePresentation.badge(
            state: row.state, meeting: row.id, recorder: session.recorderState,
            processing: session.processing[row.id])
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            Image(systemName: badge?.symbol ?? "waveform.and.person.filled")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(MeetingsWorkspacePresentation.subtitle(row: row, badge: badge))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RafuMetrics.space2)
        .padding(.vertical, RafuMetrics.space1 + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The navigator panel body: Record, Open Meetings, and the list of
/// meetings. A click on a row opens the meeting as a tab beside the code.
/// It never holds a recorder or an engine; it reads `feature.session`.
struct MeetingsNavigatorView: View {
    let feature: MeetingsFeature
    let workspaceSession: WorkspaceSession

    @State private var list = MeetingsWorkspaceListModel()
    @State private var pendingDelete: MeetingID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.rafuTheme) private var theme

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        VStack(spacing: 0) {
            controls
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.libraryRevision) {
            await list.reload(from: feature.store)
        }
        .sheet(isPresented: deleteDialogBinding) {
            // Cancel is the default button, so Return never deletes.
            if let meeting = pendingDelete {
                RafuConfirmPopup(
                    symbol: "trash",
                    title: MeetingsWorkspacePresentation.deleteConfirmationTitle,
                    message: MeetingsWorkspacePresentation.deleteConfirmationMessage,
                    actions: [
                        .init("Delete", isDestructive: true) {
                            pendingDelete = nil
                            session.deleteMeeting(meeting)
                        }
                    ]
                ) {
                    pendingDelete = nil
                }
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if let reason = feature.availability.unavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(RafuMetrics.utilityBodyInset)
        } else {
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                HStack(spacing: RafuMetrics.space2) {
                    Button("Record", systemImage: "record.circle") {
                        session.startRecording()
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .disabled(!session.canStartRecording)
                    .help(
                        session.canStartRecording
                            ? "Start recording a meeting" : "Recording is on or not ready")
                    Button("Open Meetings", systemImage: "macwindow") {
                        openMeetings(selecting: nil)
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Open Meetings (⌘⇧M)")
                    Spacer(minLength: 0)
                }
                if let failure = session.startFailure {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, RafuMetrics.utilityBodyInset)
            .padding(.bottom, RafuMetrics.space2)
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if !list.isLoaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if list.rows.isEmpty {
            RafuPanelEmptyState(
                icon: "waveform.and.person.filled",
                title: list.loadFailed ? "Meetings did not load" : "No meetings yet",
                message: list.loadFailed
                    ? "Try again in a moment."
                    : "Record a call. The text stays on this Mac.",
                compact: true
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(list.rows) { row in
                        rowButton(row)
                    }
                }
                .padding(.horizontal, RafuMetrics.space1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func rowButton(_ row: MeetingsWorkspaceRow) -> some View {
        RafuHoverRow(isSelected: workspaceSession.selectedAuxiliaryTab == .meeting(row.id)) {
            Button {
                workspaceSession.openMeetingTab(row.id)
            } label: {
                MeetingsListRowLabel(row: row, session: session)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button("Open in Meetings") { openMeetings(selecting: row.id) }
            if MeetingsWorkspacePresentation.canDelete(
                meeting: row.id, recorder: session.recorderState)
            {
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = row.id }
            }
        }
    }

    private func openMeetings(selecting meeting: MeetingID?) {
        if !MeetingsWindowOpener.shared.open(selecting: meeting) {
            if let meeting { session.windowSelection = meeting }
            openWindow(id: MeetingsWindowRoot.windowID)
        }
    }
}
