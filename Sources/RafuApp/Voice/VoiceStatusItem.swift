import AppKit
import RafuCore
import SwiftUI

/// The voice item in every workspace window's status bar: a glyph that says
/// if the microphone is on (mic, pause, mic off, a ring while idle) and,
/// while a session is open, the state word. Not colour only. The companion
/// orb is the window's main voice surface (voice-presence.md). Its menu holds
/// every voice action, one click away, so none needs the key chord.
struct VoiceStatusItem: View {
    let session: VoiceSession
    @Environment(\.rafuTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var showsTimeline = false

    private var state: VoiceBlobState { session.blobState }

    var body: some View {
        HStack(spacing: 4) {
            menu
            if state.isOpen {
                Text(status.word)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }

    private var menu: some View {
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
            Image(nsImage: Self.glyph(status.symbol, description: status.spoken))
                .renderingMode(.template)
                .foregroundStyle(state.isOpen ? theme.palette.accent : theme.palette.textMuted)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(state.isOpen ? theme.palette.accent : theme.palette.textMuted)
        .help(helpText)
        .accessibilityLabel("Rafu voice")
        .accessibilityValue(state.accessibilityLabel)
        .accessibilityAction(named: "Show Voice Timeline") { showsTimeline = true }
        .popover(isPresented: $showsTimeline, arrowEdge: .top) {
            VoiceTimelinePopover(session: session)
        }
    }

    private var status: VoiceRunStatus {
        VoiceRunStatus(
            state: state, micOpen: session.isMicOpen, latched: session.machine.mic == .latched)
    }

    /// An SF Symbol as an 11 pt template image (a borderless menu label
    /// draws an image, not an arbitrary view).
    static func glyph(_ symbol: String, description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image =
            NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
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
        if let hint = session.hint { return "Rafu voice: \(state.word). \(hint)" }
        return state == .idle
            ? "Rafu voice. \(Self.chordHint), or choose Start Listening."
            : "Rafu voice: \(state.word)"
    }
}
