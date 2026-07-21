import Foundation

/// Persists WHERE a bell-worthy terminal attention event surfaces
/// (terminal-notch-hud.md, product decision 1) — the single
/// `TerminalAttentionSurface` arbitration enum that REPLACES the old
/// `terminalBellNotificationsEnabled` boolean
/// (`TerminalNotificationPreferenceStore`, superseded by this type).
///
/// Migration: the new key absent → read the legacy boolean ONCE — legacy
/// absent or `true` → `.both` (the old default was on); legacy `false` →
/// `.none` — then write the migrated enum to the new key and remove the
/// legacy key, so the legacy key is never consulted again. A new-key value
/// that fails to parse is treated as absent and re-migrates (self-healing).
///
/// Mirrors the shape of every other suite-injectable store here: stores the
/// SUITE NAME, not a `UserDefaults` instance (`UserDefaults` is not
/// `Sendable` on this toolchain), and constructs the defaults on demand.
/// `nil` uses the standard defaults; tests inject a suite they clean up.
nonisolated struct TerminalAttentionSurfaceStore: Sendable {
    static let defaultsKey = "terminalAttentionSurface"
    /// The superseded boolean key, read once for migration and then
    /// removed. Kept as a literal here — the type that used to own it is
    /// gone; this store is the only place that may still reference it.
    static let legacyEnabledKey = "terminalBellNotificationsEnabled"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The user's chosen surface, migrating from the legacy boolean on
    /// first read when the new key has never been written.
    func surface() -> TerminalAttentionSurface {
        if let raw = defaults.string(forKey: Self.defaultsKey),
            let value = TerminalAttentionSurface(rawValue: raw)
        {
            return value
        }
        let migrated: TerminalAttentionSurface
        if defaults.object(forKey: Self.legacyEnabledKey) != nil {
            migrated = defaults.bool(forKey: Self.legacyEnabledKey) ? .both : .none
        } else {
            migrated = .both
        }
        defaults.set(migrated.rawValue, forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyEnabledKey)
        return migrated
    }

    func setSurface(_ value: TerminalAttentionSurface) {
        defaults.set(value.rawValue, forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyEnabledKey)
    }
}
