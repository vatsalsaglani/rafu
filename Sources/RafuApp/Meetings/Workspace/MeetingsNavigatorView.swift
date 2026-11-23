import RafuCore
import SwiftUI

/// Two lines for one meeting: the title, then the date and length, or the
/// state ("Recording · 02:13", "Writing the text · 57%", a failure reason).
/// A shape goes with each state, so colour is never the only cue.
struct MeetingsListRowLabel: View {
    let title: String
    let display: MeetingsRowDisplay
    var isSelected = false

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            Image(systemName: display.symbol)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(display.subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    // On the selection fill the muted tone is too faint.
                    .foregroundStyle(
                        isSelected ? theme.palette.textSecondary : theme.palette.textMuted
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                if display.showsProgress {
                    MeetingsRowProgressBar(fraction: display.progress)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RafuMetrics.space2)
        .padding(.vertical, RafuMetrics.space1 + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            MeetingsStatePresentation.rowAccessibilityLabel(title: title, display: display))
    }

    private var iconColor: Color {
        switch display.tone {
        case .ready, .paused: theme.palette.textSecondary
        case .recording: theme.palette.error
        case .processing: theme.palette.accent
        case .failed: theme.palette.warning
        }
    }
}

/// The thin bar under a processing row.
struct MeetingsRowProgressBar: View {
    let fraction: Double?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.mini)
        .tint(theme.palette.accent)
        .frame(maxWidth: 160)
        .accessibilityHidden(true)
    }
}

/// One meeting row of a list: the open button with its two-line label and,
/// for a failed meeting, "Try Again" while the pointer is on the row. The
/// same actions are in the context menu, so the keyboard reaches them.
struct MeetingsListRowButton: View {
    let meeting: MeetingID
    let title: String
    let readyLine: String
    let state: MeetingState
    let session: MeetingsSessionModel
    var isSelected = false
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        let display = currentDisplay
        RafuHoverRow(isSelected: isSelected) {
            HStack(spacing: 0) {
                Button(action: open) {
                    MeetingsListRowLabel(title: title, display: display, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if display.canRetry, isHovering {
                    Button("Try Again") { session.retryProcessing(meeting) }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .help("Write the text from the kept audio again")
                        .padding(.trailing, RafuMetrics.space1)
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private var currentDisplay: MeetingsRowDisplay {
        let recorder = session.recorderState
        // Only the live row reads the clock, so the other rows do not
        // redraw each second.
        let elapsed = recorder.meeting == meeting ? session.liveElapsed : 0
        return MeetingsStatePresentation.rowDisplay(
            meeting: meeting, state: state, readyLine: readyLine, recorder: recorder,
            elapsed: elapsed, step: session.processing[meeting])
    }
}

/// The two icon buttons of the Meetings navigator header: Record and Open
/// Meetings. Nothing shows when Meetings is not available.
struct MeetingsNavigatorHeaderActions: View {
    let feature: MeetingsFeature

    @Environment(\.openWindow) private var openWindow

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        if feature.availability.isAvailable {
            let reason = MeetingsWindowPresentation.recordDisabledReason(
                availability: feature.availability, recorderState: session.recorderState,
                isDriverInstalled: session.isDriverInstalled)
            Button {
                session.startRecording()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .disabled(reason != nil || !session.canStartRecording)
            .help(reason ?? "Start recording a meeting")
            .accessibilityLabel("Record")
            .accessibilityHint(reason ?? "Starts a new recording")
            Button {
                if !MeetingsWindowOpener.shared.open() {
                    openWindow(id: MeetingsWindowRoot.windowID)
                }
            } label: {
                Label("Open Meetings", systemImage: "macwindow")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("Open Meetings (⌘⇧M)")
            .accessibilityLabel("Open Meetings")
        }
    }
}

/// The navigator panel body: the list of meetings. The header (in the host)
/// holds Record and Open Meetings. A click on a row opens the meeting as a
/// tab beside the code. It never holds a recorder or an engine; it reads
/// `feature.session`.
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
            notice
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.libraryRevision) {
            await list.reload(from: feature.store)
            session.noteMeetingTitles(list.rows.map { ($0.id, $0.title) })
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

    // MARK: Notice

    /// Why Meetings is not available, or why the last Record did not start.
    @ViewBuilder
    private var notice: some View {
        if let text = feature.availability.unavailableReason ?? session.startFailure?.message {
            Text(text)
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                icon: "waveform",
                title: list.loadFailed ? "Meetings did not load" : "No meetings yet",
                message: list.loadFailed
                    ? "Try again in a moment."
                    : "Your recordings show here.",
                compact: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // Split into typed parts: as one expression this took about 1 s to
    // type-check here, and the CI runner has a lower effective limit.
    private func rowButton(_ row: MeetingsWorkspaceRow) -> some View {
        let selectedTab: WorkspaceAuxiliaryTab? = workspaceSession.selectedAuxiliaryTab
        var isSelected = false
        if case .meeting(let selected)? = selectedTab { isSelected = selected == row.id }
        let canDelete: Bool = MeetingsWorkspacePresentation.canDelete(
            meeting: row.id, recorder: session.recorderState)
        return MeetingsListRowButton(
            meeting: row.id, title: row.title, readyLine: row.readyLine, state: row.state,
            session: session, isSelected: isSelected
        ) {
            workspaceSession.openMeetingTab(row.id)
        }
        .contextMenu {
            rowMenu(row, canDelete: canDelete)
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: MeetingsWorkspaceRow, canDelete: Bool) -> some View {
        Button("Open in Meetings") { openMeetings(selecting: row.id) }
        if MeetingsWorkspacePresentation.canRetry(
            state: row.state, meeting: row.id, recorder: session.recorderState,
            step: session.processing[row.id])
        {
            Button("Try Again") { session.retryProcessing(row.id) }
        }
        if canDelete {
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = row.id }
        }
    }

    private func openMeetings(selecting meeting: MeetingID?) {
        if !MeetingsWindowOpener.shared.open(selecting: meeting) {
            if let meeting { session.windowSelection = meeting }
            openWindow(id: MeetingsWindowRoot.windowID)
        }
    }
}
