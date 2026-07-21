import Foundation

/// Persists whether Rafu may post a system notification when a
/// parked/unfocused terminal session bells (terminal-manager.md T-E).
/// Mirrors `PreferredShellStore`'s shape: stores a `UserDefaults` *suite
/// name* rather than an instance (`UserDefaults` is not `Sendable` on this
/// toolchain), and the key matches what `RafuSettingsView`'s
/// `@AppStorage("terminalBellNotificationsEnabled")` toggle binds to
/// directly — both read/write the same standard-defaults key.
///
/// Default is ON when unset. The PREFERENCE and the permission PROMPT are
/// deliberately different gates: this defaults to enabled so the lazy,
/// first-bell authorization prompt has a chance to fire at all, but the
/// prompt itself never appears at launch (see
/// `WorkspaceSession.notifyIfNeeded(for:)`) — AGENTS' calm-defaults rule
/// governs the PROMPT's timing, not this toggle's default.
nonisolated struct TerminalNotificationPreferenceStore: Sendable {
    static let defaultsKey = "terminalBellNotificationsEnabled"

    /// `nil` uses the standard defaults; tests inject a suite they clean up.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// `true` unless the user has explicitly turned bell notifications off.
    func isEnabled() -> Bool {
        guard defaults.object(forKey: Self.defaultsKey) != nil else { return true }
        return defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.defaultsKey)
    }
}
