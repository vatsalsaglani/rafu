import SwiftUI

// Owned by the meeting detail package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerDetailParts() {
        register(
            .meetingDetailView { feature, meeting in
                AnyView(MeetingDetailView(feature: feature, meeting: meeting))
            })
    }
}
