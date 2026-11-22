import RafuCore
import SwiftUI

/// The record button in the title bar. Idle: a small icon button. A recording
/// (or a pause) shows a menu labelled with a shape and the time. It shows
/// shape and time only, never a title or a name. There is no pulse, so
/// Reduce Motion needs no special case.
struct MeetingsTitleBarRecordButton: View {
    let feature: MeetingsFeature

    @Environment(\.openWindow) private var openWindow

    private var session: MeetingsSessionModel { feature.session }

    var body: some View {
        if feature.availability.isAvailable {
            switch MeetingsWorkspacePresentation.titleBar(
                recorder: session.recorderState, elapsed: 0)
            {
            case .record:
                Button("Record a meeting", systemImage: "record.circle") {
                    session.startRecording()
                }
                .buttonStyle(RafuIconButtonStyle())
                .disabled(!session.canStartRecording)
                .help("Record a meeting")
                .accessibilityLabel("Record a meeting")
            case .active(_, let isPaused, let canControl):
                MeetingsTitleBarActiveMenu(
                    session: session, isPaused: isPaused, canControl: canControl,
                    openMeetings: openMeetings)
            }
        }
    }

    private func openMeetings() {
        if !MeetingsWindowOpener.shared.open() {
            openWindow(id: MeetingsWindowRoot.windowID)
        }
    }
}

/// The menu while a recording is on. Only this view reads `liveElapsed`, so
/// the clock does not redraw the rest of the title bar.
private struct MeetingsTitleBarActiveMenu: View {
    let session: MeetingsSessionModel
    let isPaused: Bool
    let canControl: Bool
    let openMeetings: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let content = MeetingsWorkspacePresentation.titleBar(
            recorder: session.recorderState, elapsed: session.liveElapsed)
        let spoken = MeetingsWorkspacePresentation.titleBarAccessibility(
            recorder: session.recorderState, elapsed: session.liveElapsed)
        Menu {
            if canControl {
                if isPaused {
                    Button("Resume", systemImage: "play.fill") { session.resume() }
                } else {
                    Button("Pause", systemImage: "pause.fill") { session.pause() }
                }
                Button("Stop", systemImage: "stop.fill") { session.stop() }
                Divider()
            }
            Button("Open Meetings", systemImage: "macwindow") { openMeetings() }
        } label: {
            if case .active(let text, _, _) = content {
                Text(text)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.palette.textPrimary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording controls")
        .accessibilityLabel(spoken)
    }
}
