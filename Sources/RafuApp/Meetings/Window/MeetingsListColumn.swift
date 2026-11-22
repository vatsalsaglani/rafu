import RafuCore
import SwiftUI

/// The left column of the Meetings window: the title, Record, the meeting
/// list in groups, and "Open Folder…". It pins to the top; the empty state
/// expands and centres.
struct MeetingsListColumn: View {
    let feature: MeetingsFeature
    let model: MeetingsWindowModel
    let commands: MeetingsWindowCommands
    let onRename: (MeetingSummaryRecord) -> Void
    let onDelete: (MeetingSummaryRecord) -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.rafuTheme) private var theme

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        VStack(spacing: 0) {
            RafuUtilityPanelHeader(title: "Meetings") {
                EmptyView()
            } actions: {
                MeetingsRecordButton(feature: feature, commands: commands, prominent: false)
            }
            Divider()
            listBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            Button("Open Folder…", systemImage: "folder") {
                openWindow(id: "workspace")
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            .help("Open a workspace window beside Meetings")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RafuMetrics.space2)
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
                Button("Try again") { model.retry() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Read the meetings again")
            }
            .padding(RafuMetrics.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.isEmpty {
                RafuPanelEmptyState(
                    icon: "waveform", title: "No meetings yet", message: "Press Record to start.",
                    compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        @Bindable var session = session
        return List(selection: $session.windowSelection) {
            ForEach(model.sections) { section in
                Section(section.group.rawValue) {
                    ForEach(section.rows) { row in
                        MeetingsListRow(
                            row: row,
                            status: MeetingsWindowPresentation.status(
                                for: row.summary, recorderState: session.recorderState,
                                step: session.processing[row.id]),
                            canDelete: commands.canDelete(row.id),
                            onRename: { onRename(row.summary) },
                            onDelete: { onDelete(row.summary) }
                        )
                        .tag(row.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// The Record button: not active when a recording cannot start, with the
/// reason as help text. It never starts a second recording.
struct MeetingsRecordButton: View {
    let feature: MeetingsFeature
    let commands: MeetingsWindowCommands
    let prominent: Bool

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let session = feature.session
        let reason = MeetingsWindowPresentation.recordDisabledReason(
            availability: feature.availability, recorderState: session.recorderState,
            isDriverInstalled: session.isDriverInstalled)
        let button = Button {
            commands.record()
        } label: {
            Label {
                Text("Record")
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(reason == nil ? theme.palette.error : theme.palette.textMuted)
            }
        }
        .disabled(reason != nil || !session.canStartRecording)
        .help(reason ?? "Start a new recording")
        .accessibilityLabel("Record")
        .accessibilityHint(reason ?? "Starts a new recording")

        if prominent {
            button
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
    }
}

/// One meeting row: the title, the subtitle, the state word with a shape,
/// and a "…" menu that the keyboard reaches. The same actions are in the
/// context menu.
struct MeetingsListRow: View {
    let row: MeetingsListRowModel
    let status: MeetingsRowStatus?
    let canDelete: Bool
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.summary.title.isEmpty ? "Untitled meeting" : row.summary.title)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                if let status {
                    MeetingsStatusLabel(status: status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 11))
            .fixedSize()
            .accessibilityLabel("Meeting actions")
            .help("Rename or delete this meeting")
        }
        .padding(.vertical, 2)
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Rename…", action: onRename)
        Button("Delete…", role: .destructive, action: onDelete)
            .disabled(!canDelete)
    }
}

/// A state word with its shape. The colour only repeats the word.
struct MeetingsStatusLabel: View {
    let status: MeetingsRowStatus

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Label {
            Text(status.word)
        } icon: {
            Image(systemName: status.symbol)
                .imageScale(.small)
                .foregroundStyle(color)
        }
        .font(.caption)
        .foregroundStyle(theme.palette.textSecondary)
    }

    private var color: Color {
        switch status {
        case .recording: theme.palette.error
        case .paused, .stopping: theme.palette.textSecondary
        case .processing: theme.palette.accent
        case .failed: theme.palette.warning
        }
    }
}
