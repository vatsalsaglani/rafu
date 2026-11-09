import RafuCore
import SwiftUI

/// The voice orb in the notch wing: a 20 pt compact `VoiceLiveOrb` that
/// takes the mascot's place while a voice session is open. At this size the
/// dots would be about 1 pt, so it has no face and no badge; the marble
/// still rocks and swells while something moves it, else it is one still
/// frame.
struct VoiceNotchOrb: View {
    let session: VoiceSession
    var size: CGFloat = 20
    @State private var showsTimeline = false

    private var state: VoiceBlobState { session.blobState }

    var body: some View {
        Button(action: activate) {
            VoiceLiveOrb(session: session, size: size, isCompact: true)
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
