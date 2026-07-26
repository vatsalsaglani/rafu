import Foundation

/// Persists whether the user has completed (or explicitly skipped) the
/// first-launch experience ("The Unfolding," pass 1) at least once. Mirrors
/// `PreferredShellStore`'s suite-name — not a `UserDefaults` instance —
/// pattern: `UserDefaults` is not `Sendable` on this toolchain, so a stored
/// instance would break this struct's honest `Sendable` conformance, and
/// storing a suite name instead lets tests inject and clean up an isolated
/// suite rather than touching real prefs.
nonisolated struct OnboardingCompletionStore: Sendable {
    static let defaultsKey = "firstLaunchExperienceVersion"

    /// Bumping this re-invites a user who already completed the current
    /// intro to a future revision, without ever auto-replaying today's cut.
    static let currentVersion = 1

    /// `nil` uses the standard defaults; tests inject a suite they clean up.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// An absent key reads 0 via `UserDefaults.integer(forKey:)`, which is
    /// always below `currentVersion` — a fresh install reads `false`.
    var hasCompleted: Bool {
        defaults.integer(forKey: Self.defaultsKey) >= Self.currentVersion
    }

    func markCompleted() {
        defaults.set(Self.currentVersion, forKey: Self.defaultsKey)
    }

    /// Re-arms the intro as if it had never been shown. Used by tests and by
    /// debugging paths; not wired to any user-facing control in pass 1.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
