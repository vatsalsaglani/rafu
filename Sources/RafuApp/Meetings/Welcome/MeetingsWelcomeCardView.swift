import RafuCore
import SwiftUI

/// The content of the Meetings card on the Welcome screen: Record, All
/// meetings, and the three newest meetings. The Welcome screen draws it only
/// after the feature exists, so it never makes the feature.
struct MeetingsWelcomeCardView: View {
    let feature: MeetingsFeature

    @State private var list = MeetingsWorkspaceListModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.rafuTheme) private var theme

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            if let reason = feature.availability.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
            } else {
                HStack(spacing: RafuMetrics.space2) {
                    Button("Record", systemImage: "record.circle") {
                        // One explicit action: the window shows the recording.
                        openMeetings(selecting: nil)
                        session.startRecording()
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .disabled(!session.canStartRecording)
                    .help("Start recording a meeting")
                    Button("All meetings", systemImage: "list.bullet") {
                        openMeetings(selecting: nil)
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Open Meetings (⌘⇧M)")
                }
                ForEach(MeetingsWorkspacePresentation.newest(list.rows)) { row in
                    RafuHoverRow {
                        Button {
                            openMeetings(selecting: row.id)
                        } label: {
                            MeetingsListRowLabel(row: row, session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.libraryRevision) {
            guard feature.availability.isAvailable else { return }
            await list.reload(from: feature.store)
        }
    }

    private func openMeetings(selecting meeting: MeetingID?) {
        if !MeetingsWindowOpener.shared.open(selecting: meeting) {
            if let meeting { session.windowSelection = meeting }
            openWindow(id: MeetingsWindowRoot.windowID)
        }
    }
}
