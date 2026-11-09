import AppKit
import RafuCore
import SwiftUI

/// The voice item in every workspace window's status bar: a 7 pt dot, the
/// accent while a session is open and muted while idle. The state word is in
/// the help text and the accessibility value; the companion orb is the
/// window's main voice surface (voice-presence.md). Its menu holds every
/// voice action, one click away, so none needs the key chord.
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
            Image(nsImage: Self.dot(open: state.isOpen))
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

    static let dotDiameter: CGFloat = 7

    /// A 7 pt circle as a template image (a borderless menu label draws an
    /// image, not an arbitrary shape): filled while a session is open, a
    /// ring while idle, so colour is not the only signal. The help text and
    /// the accessibility value carry the state word.
    static func dot(open: Bool) -> NSImage {
        let size = NSSize(width: dotDiameter, height: dotDiameter)
        let image = NSImage(size: size, flipped: false) { rect in
            if open {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                NSColor.black.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = open ? "Voice session open" : "Voice off"
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
