import RafuCore
import SwiftUI

/// The voice orb in the notch wing: a 20 pt `VoiceLiveOrb` that takes the
/// mascot's place while a voice session is open. It follows the audio level
/// only while something moves it (the sampler's gate); otherwise it is one
/// still frame. No ring outside the disc and no shell glow at this size.
struct VoiceNotchOrb: View {
    let session: VoiceSession
    var size: CGFloat = 20
    @State private var showsTimeline = false

    private var state: VoiceBlobState { session.blobState }

    var body: some View {
        Button(action: activate) {
            VoiceLiveOrb(session: session, size: size, showsRing: false)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hintText)
        .accessibilityLabel("Rafu voice")
        .accessibilityValue(state.accessibilityLabel)
        .accessibilityHint(hintText)
        .accessibilityAction(named: "Show Voice Timeline") { showsTimeline = true }
        .contextMenu {
            Button("Show Voice Timeline") { showsTimeline = true }
        }
        .popover(isPresented: $showsTimeline, arrowEdge: .bottom) {
            VoiceTimelinePopover(session: session)
        }
    }

    private var helpText: String {
        switch state {
        case .speaking: "Stop speaking"
        case .error: "Dismiss"
        case .listeningLatched, .checkIn: "Stop listening"
        default: "Keep listening without the key"
        }
    }

    /// After a turn Rafu did not hear, the session's tip comes first.
    private var hintText: String {
        guard let hint = session.hint else { return helpText }
        return "\(hint) Click to \(helpText.lowercased())."
    }

    private func activate() {
        switch state {
        case .speaking: session.stopSpeaking()
        case .error: session.dismissError()
        default: session.toggleLatched()
        }
    }
}
