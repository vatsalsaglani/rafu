import RafuCore

// Owned by the recording session and processing pipeline package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    func registerSessionParts() {
        installSessionDriver(preferences: UserDefaultsMeetingPreferences())
    }

    /// Makes the session driver and keeps it for the life of the feature.
    /// With no recorder (macOS 15) Record says why it cannot start.
    @discardableResult
    func installSessionDriver(preferences: any MeetingPreferencesReading)
        -> MeetingsSessionDriver?
    {
        guard availability.isAvailable, let recorder else {
            let reason = availability.unavailableReason ?? "Meetings needs macOS 26"
            session.handlers.start = { [weak session] _ in
                session?.startFailure = .notAvailable(reason: reason)
            }
            return nil
        }
        let driver = MeetingsSessionDriver(
            feature: self, recorder: recorder, feeds: recorder as? any MeetingsRecorderFeeds,
            preferences: preferences)
        MeetingsSessionDrivers.drivers[ObjectIdentifier(self)] = driver
        driver.install()
        return driver
    }
}

/// Keeps each feature's driver alive (the app makes one feature).
enum MeetingsSessionDrivers {
    static var drivers: [ObjectIdentifier: MeetingsSessionDriver] = [:]
}
