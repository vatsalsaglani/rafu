import RafuCore
import SwiftUI

/// The companion's control pill: the run state in words ("Listening · Mic
/// on"), one main button that names its action ("Pause" or "Listen"), then
/// icons. Each icon has `.help`, an accessibility label, and a keyboard path
/// (Tab to it, or the same item in the Rafu menu). A solid theme surface, so
/// Reduce Transparency needs nothing extra. The companion places it with an
/// explicit rect, inside the window and off the orb.
struct VoiceControlPill: View {
    let session: VoiceSession
    let showTimeline: () -> Void
    let openSettings: () -> Void
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    private var state: VoiceBlobState { session.blobState }

    var body: some View {
        let status = VoiceRunStatus(
            state: state, micOpen: session.isMicOpen, latched: session.machine.mic == .latched)
        HStack(spacing: 2) {
            VoiceStatusChip(status: status)
                .padding(.trailing, 4)
            Button {
                session.toggleLatched()
            } label: {
                Label(status.actionTitle, systemImage: status.actionSymbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.onAccent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(theme.palette.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(status.actionTitle == "Pause" ? "Stop Listening" : "Start Listening")
            .accessibilityLabel(
                status.actionTitle == "Pause" ? "Stop Listening" : "Start Listening")
            if state.isOpen {
                icon("speaker.slash.fill", label: "Stop Speaking") { session.stopSpeaking() }
                    .disabled(state != .speaking)
            }
            if case .error = state {
                icon("arrow.counterclockwise", label: "Dismiss") { session.dismissError() }
            }
            icon("list.bullet.rectangle", label: "Show Voice Timeline", action: showTimeline)
            icon("gearshape", label: "Voice Settings", action: openSettings)
            if state.isOpen {
                icon("xmark", label: "End Voice Session") {
                    Task { await session.close(reason: .user) }
                }
            }
        }
        .padding(4)
        .background(theme.palette.cardBackground, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                contrast == .increased ? theme.palette.borderStrong : theme.palette.borderSubtle,
                lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rafu voice controls")
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
