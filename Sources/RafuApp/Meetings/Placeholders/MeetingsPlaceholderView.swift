import RafuCore
import SwiftUI

/// What each Meetings surface shows when no package has registered its
/// view: "Meetings needs macOS 26" on an older Mac, else "Meetings is being
/// built".
struct MeetingsPlaceholderView: View {
    var availability: MeetingsAvailability = .current
    var compact = false

    static func message(for availability: MeetingsAvailability) -> String {
        availability.unavailableReason ?? "Meetings is being built"
    }

    var body: some View {
        RafuPanelEmptyState(
            icon: "waveform.and.person.filled",
            title: "Meetings",
            message: Self.message(for: availability),
            compact: compact
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
