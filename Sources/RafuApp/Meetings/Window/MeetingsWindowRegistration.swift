import SwiftUI

// Owned by the Meetings window, Welcome card, workspace tab and activity strip package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    /// Registers the Meetings window content. On macOS 15 the view shows
    /// "Meetings needs macOS 26" and no control.
    func registerWindowParts() {
        register(.windowView { feature in AnyView(MeetingsWindowView(feature: feature)) })
    }
}
