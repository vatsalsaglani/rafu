import Foundation
import RafuCore
import SwiftUI

// Owned by the status surfaces (Dynamic Island, notch, HUD, menu bar) package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerCompanionParts() {
        register(
            .companionSection { feature in AnyView(MeetingsCompanionSectionView(feature: feature)) }
        )
        // Only the app's feature makes the menu bar item and the floating
        // bar: the shared factory sets its `feature` before it calls the
        // registration functions, so a test feature never matches. Never on
        // macOS 15.
        guard availability.isAvailable, self === MeetingsFeatureFactory.shared.feature else {
            return
        }
        MeetingsStatusSurfaces.install(for: self)
    }
}

/// Keeps the menu bar item and the floating bar alive until Rafu quits.
/// Empty in each test process.
@MainActor
enum MeetingsStatusSurfaces {
    private(set) static var statusItem: MeetingsStatusItemController?
    private(set) static var floatingBar: MeetingsFloatingBarController?

    static var isInstalled: Bool { statusItem != nil || floatingBar != nil }

    static func install(for feature: MeetingsFeature) {
        guard !isInstalled else { return }
        let setting = MeetingsFloatingBarSetting()
        let floatingBar = MeetingsFloatingBarController(session: feature.session, setting: setting)
        self.floatingBar = floatingBar
        statusItem = MeetingsStatusItemController(
            session: feature.session, setting: setting,
            onFloatingBarSettingChanged: { [weak floatingBar] in floatingBar?.update() })
    }
}

/// The user's choice "Show Floating Recording Bar". Default off.
@MainActor
final class MeetingsFloatingBarSetting {
    static let key = "meetings.companion.floatingBar"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Builds the policy input from the session model, and runs an action.
@MainActor
enum MeetingsStatusActions {
    static func input(
        session: MeetingsSessionModel, canOpenWindow: Bool, floatingBarEnabled: Bool
    ) -> MeetingsStatusInput {
        MeetingsStatusInput(
            recorderState: session.recorderState, elapsed: session.liveElapsed,
            processing: session.processing, warnings: session.warnings,
            canStartRecording: session.canStartRecording, canOpenWindow: canOpenWindow,
            floatingBarEnabled: floatingBarEnabled)
    }

    /// Runs `action` on the session. `openWindow` opens the Meetings window
    /// on the given meeting; `toggleFloatingBar` flips the user setting.
    static func perform(
        _ action: MeetingsStatusAction, session: MeetingsSessionModel,
        openWindow: (MeetingID?) -> Void = { MeetingsWindowOpener.shared.open(selecting: $0) },
        toggleFloatingBar: () -> Void = {}
    ) {
        switch action {
        case .startRecording: session.startRecording()
        case .pause: session.pause()
        case .resume: session.resume()
        case .stop: session.stop()
        case .openMeetings: openWindow(session.liveMeeting)
        case .toggleFloatingBar: toggleFloatingBar()
        }
    }
}
