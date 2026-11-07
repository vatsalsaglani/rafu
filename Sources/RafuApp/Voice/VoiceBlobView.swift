import RafuCore
import SwiftUI

/// The voice blob: the state glyph, a ring while the microphone is open, and
/// a three-bar level meter while capturing. It replaces the notch mascot
/// while a voice session is open. The meter is written at 20 Hz from a task
/// that runs only while the microphone is open and motion is allowed; under
/// Reduce Motion or a closed motion gate it is still.
struct VoiceBlobView: View {
    let session: VoiceSession
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.rafuTheme) private var theme
    @State private var level = 0.0
    @State private var showsTimeline = false

    static let frameInterval: Duration = .milliseconds(50)

    private var state: VoiceBlobState { session.blobState }
    private var metering: Bool { session.isMicOpen && motionAllowed && !reduceMotion }

    var body: some View {
        Button(action: activate) {
            ZStack {
                Circle()
                    .fill(theme.palette.accent.opacity(state == .idle ? 0.25 : 0.9))
                if session.isMicOpen {
                    Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                }
                if metering, level > 0 {
                    VoiceLevelBars(level: level).frame(width: size * 0.5, height: size * 0.45)
                } else {
                    Image(systemName: state.symbol)
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint(helpText)
        .accessibilityAction(named: "Show Voice Timeline") { showsTimeline = true }
        .contextMenu {
            Button("Show Voice Timeline") { showsTimeline = true }
        }
        .popover(isPresented: $showsTimeline, arrowEdge: .bottom) {
            VoiceTimelinePopover(session: session)
        }
        .task(id: metering) { await meter() }
    }

    private var helpText: String {
        switch state {
        case .speaking: "Stop speaking"
        case .error: "Dismiss"
        case .listeningLatched, .checkIn: "Stop listening"
        default: "Keep listening without the key"
        }
    }

    private func activate() {
        switch state {
        case .speaking: session.stopSpeaking()
        case .error: session.dismissError()
        default: session.toggleLatched()
        }
    }

    private func meter() async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { level = 0 }
        guard metering else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.frameInterval, tolerance: .milliseconds(10))
            } catch {
                return
            }
            let next = session.inputLevel
            if abs(next - level) > 0.02 { withTransaction(still) { level = next } }
        }
    }
}

/// Three bars for the microphone level, 0…1. No animation of its own.
struct VoiceLevelBars: View {
    let level: Double

    var body: some View {
        Canvas { context, size in
            let weights = [0.6, 1.0, 0.75]
            let width = size.width / 5
            for (index, weight) in weights.enumerated() {
                let height = max(2, size.height * min(1, level * weight * 1.4))
                let rect = CGRect(
                    x: Double(index) * width * 2, y: (size.height - height) / 2, width: width,
                    height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}
