import RafuCore
import SwiftUI

/// The voice item in every workspace window's status bar: the one visible
/// voice surface on a Mac without a notch. A symbol at rest; a symbol and a
/// short word while a session is open. Its menu holds every voice action, so
/// none needs the key chord.
struct VoiceStatusItem: View {
    let session: VoiceSession
    @Environment(\.rafuTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var showsTimeline = false

    private var state: VoiceBlobState { session.blobState }

    var body: some View {
        Menu {
            Button(isListening ? "Stop Listening" : "Start Listening") {
                session.toggleLatched()
            }
            Button("Stop Speaking") { session.stopSpeaking() }
                .disabled(state != .speaking)
            if state.isOpen {
                Button("End Voice Session") {
                    Task { await session.close(reason: .user) }
                }
            }
            if case .error = state {
                Button("Dismiss") { session.dismissError() }
            }
            Button("Show Voice Timeline") { showsTimeline = true }
            Divider()
            Text(VoiceStatusItem.chordHint)
            Button("Voice Settings…") {
                SettingsPaneRouter.shared.request(.voice)
                openSettings()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: state.symbol)
                if state != .idle {
                    Text(state.word).lineLimit(1)
                }
                if session.isMicOpen {
                    Circle().fill(theme.palette.accent).frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(state == .idle ? theme.palette.textMuted : theme.palette.textSecondary)
        .help(helpText)
        .accessibilityLabel("Rafu voice")
        .accessibilityValue(state.accessibilityLabel)
        .accessibilityAction(named: "Show Voice Timeline") { showsTimeline = true }
        .popover(isPresented: $showsTimeline, arrowEdge: .top) {
            VoiceTimelinePopover(session: session)
        }
    }

    /// Where ⌃⌥Space works: in any app with the global hot key, else only
    /// while Rafu is in front.
    static var chordHint: String {
        VoiceHotkey.shared.isGlobal
            ? "Hold ⌃⌥Space to talk, in any app" : "Hold ⌃⌥Space to talk while Rafu is in front"
    }

    private var isListening: Bool {
        session.machine.mic == .latched
    }

    private var helpText: String {
        if case .error(let reason) = state { return "Rafu voice: \(reason)" }
        return state == .idle
            ? "Rafu voice. \(Self.chordHint), or choose Start Listening."
            : "Rafu voice: \(state.word)"
    }
}
