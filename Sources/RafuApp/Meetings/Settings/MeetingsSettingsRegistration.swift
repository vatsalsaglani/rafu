// Owned by the Settings ▸ Meetings, agent access and agent tools package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
import SwiftUI

extension MeetingsFeature {
    func registerSettingsParts() {
        register(.settingsView { feature in AnyView(MeetingsSettingsSections(feature: feature)) })
        register(
            .modelDownloadSheet { feature in
                AnyView(MeetingsModelDownloadSheet(feature: feature))
            })
    }
}
