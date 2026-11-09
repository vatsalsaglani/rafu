import RafuCore
import SwiftUI

/// The companion's control pill: icons only. Each icon has `.help`, an
/// accessibility label, and a keyboard path (Tab to it, or the same item in
/// the Rafu menu, which keeps the words and shortcuts). A solid theme
/// surface, so Reduce Transparency needs nothing extra.
struct VoiceControlPill: View {
    let session: VoiceSession
    let showTimeline: () -> Void
    let openSettings: () -> Void
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    private var state: VoiceBlobState { session.blobState }
    private var latched: Bool { session.machine.mic == .latched }

    var body: some View {
        HStack(spacing: 2) {
            icon(
                latched ? "mic.fill" : "mic",
                label: latched ? "Stop Listening" : "Start Listening"
            ) {
                session.toggleLatched()
            }
            if state.isOpen {
                icon("speaker.slash.fill", label: "Stop Speaking") { session.stopSpeaking() }
                    .disabled(state != .speaking)
                icon("xmark", label: "End Voice Session") {
                    Task { await session.close(reason: .user) }
                }
            }
            if case .error = state {
                icon("arrow.counterclockwise", label: "Dismiss") { session.dismissError() }
            }
            icon("list.bullet.rectangle", label: "Show Voice Timeline", action: showTimeline)
            icon("gearshape", label: "Voice Settings", action: openSettings)
        }
        .padding(3)
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
