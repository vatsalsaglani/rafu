import Foundation
import RafuCore

// Owned by the two-track capture and recorder package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerRecorderParts() {
        guard availability.isAvailable, #available(macOS 26, *) else { return }
        // Making the recorder opens no device and asks for no permission;
        // that happens only at Start.
        register(.recorder(MeetingRecorder(dependencies: .live(feature: self))))
    }
}

@available(macOS 26, *)
extension MeetingRecorderDependencies {
    /// The real devices. The diagnostics recorder is read now (the
    /// diagnostics package registers first); the library is read at each
    /// Start, so a store registered later is still used.
    static func live(feature: MeetingsFeature) -> MeetingRecorderDependencies {
        let preferences = UserDefaultsMeetingPreferences()
        let start = ContinuousClock.now
        return MeetingRecorderDependencies(
            microphone: MeetingMicrophoneSource(choice: { preferences.microphoneChoice() }),
            systemAudio: MeetingSystemAudioSource(),
            permissions: MeetingSystemPermissions(),
            playingProcesses: MeetingCoreAudioPlayingProcesses(),
            hostClock: MachMeetingHostClock(),
            diagnostics: feature.diagnostics,
            store: { [weak feature] in await feature?.store },
            now: {
                let elapsed = ContinuousClock.now - start
                return Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            })
    }
}
