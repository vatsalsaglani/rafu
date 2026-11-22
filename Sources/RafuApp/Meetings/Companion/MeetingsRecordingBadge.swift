import RafuCore
import SwiftUI

/// The recording mark on the CLOSED companion surfaces (the resting notch
/// strip and the Dynamic Island capsule): "● 12:47" while a meeting records,
/// "❚❚ 12:47" while it is paused, nothing otherwise. It reads the feature
/// only when it already exists, so it never makes the Meetings feature, and
/// it shows no title, name or transcript text (security point 12: capture
/// always has an indicator). It is its own small view, so the twice-a-second
/// time change redraws only this view.
struct MeetingsRecordingBadge: View {
    var factory = MeetingsFeatureFactory.shared

    var body: some View {
        if let session = factory.feature?.session, session.isRecordingOrPaused {
            let paused = MeetingsRecordingBadge.isPaused(session.recorderState)
            let time = MeetingClockText.text(session.liveElapsed)
            HStack(spacing: 3) {
                Image(systemName: paused ? "pause.fill" : "circle.fill")
                    .font(.system(size: paused ? 8 : 7, weight: .bold))
                    .foregroundStyle(paused ? Color.secondary : Color.red)
                Text(time)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                (paused ? "Meeting recording paused, " : "Recording a meeting, ") + time)
        }
    }

    static func isPaused(_ state: MeetingRecorderState) -> Bool {
        if case .paused = state { return true }
        return false
    }

    /// True while the closed surfaces must show the badge.
    static var isShowing: Bool {
        MeetingsFeatureFactory.shared.feature?.session.isRecordingOrPaused ?? false
    }
}
