import Foundation

/// Pure rules for the "Follow System" light/dark theme pair.
///
/// Persistence stays backward compatible with the original single
/// `themeChoice` default:
///
/// - `themeChoice == "system"` means **Follow System is on**. The theme is then
///   the light or dark pair member for the current system appearance. Before
///   the pair existed, "system" meant Khadi (light) or Indigo (dark), which are
///   exactly the pair defaults, so an old "System" selection behaves the same.
/// - Any other `themeChoice` is a fixed theme and Follow System is off. An old
///   specific selection therefore keeps working unchanged.
///
/// The pair itself lives in two extra defaults keys; a missing, empty, or
/// self-referencing value falls back to the defaults.
nonisolated enum ThemeAppearancePreference {
    static let lightChoiceKey = "themeLightChoice"
    static let darkChoiceKey = "themeDarkChoice"

    /// Mirrors `RafuThemeChoice.system.rawValue` (asserted by a test); a
    /// literal here keeps this type free of `MainActor` isolation.
    static let systemIdentifier = "system"
    static let defaultLightIdentifier = "khadi"
    static let defaultDarkIdentifier = "indigo"

    /// The three stored values, grouped so one pure function can update them
    /// together.
    nonisolated struct Selection: Equatable, Sendable {
        var themeChoice: String
        var lightIdentifier: String
        var darkIdentifier: String

        init(themeChoice: String, lightIdentifier: String?, darkIdentifier: String?) {
            self.themeChoice = themeChoice
            self.lightIdentifier = ThemeAppearancePreference.pairMember(
                lightIdentifier, fallback: ThemeAppearancePreference.defaultLightIdentifier)
            self.darkIdentifier = ThemeAppearancePreference.pairMember(
                darkIdentifier, fallback: ThemeAppearancePreference.defaultDarkIdentifier)
        }

        var followsSystem: Bool {
            themeChoice == ThemeAppearancePreference.systemIdentifier
        }

        /// The theme identifier that applies for the given system appearance.
        func activeIdentifier(systemIsDark: Bool) -> String {
            guard followsSystem else { return themeChoice }
            return systemIsDark ? darkIdentifier : lightIdentifier
        }

        /// Whether `identifier` is currently in use (for check marks).
        func isActive(_ identifier: String) -> Bool {
            if followsSystem {
                return identifier == lightIdentifier || identifier == darkIdentifier
            }
            return identifier == themeChoice
        }

        /// Turns Follow System on or off. Turning it off pins the theme that is
        /// active right now, so the window does not change when the toggle does.
        func settingFollowsSystem(_ follows: Bool, systemIsDark: Bool) -> Selection {
            var copy = self
            copy.themeChoice =
                follows
                ? ThemeAppearancePreference.systemIdentifier
                : activeIdentifier(systemIsDark: systemIsDark)
            return copy
        }

        /// Chooses `identifier`. With Follow System on it fills the light or
        /// dark slot that matches the theme's own appearance; otherwise it
        /// replaces the fixed theme.
        func selecting(_ identifier: String, isDark: Bool) -> Selection {
            guard identifier != ThemeAppearancePreference.systemIdentifier else {
                return settingFollowsSystem(true, systemIsDark: isDark)
            }
            var copy = self
            if followsSystem {
                if isDark {
                    copy.darkIdentifier = identifier
                } else {
                    copy.lightIdentifier = identifier
                }
            } else {
                copy.themeChoice = identifier
            }
            return copy
        }
    }

    /// The pair identifier that applies for the system appearance, read from
    /// `defaults`. Used by the theme catalog when `themeChoice` is "system".
    static func pairIdentifier(defaults: UserDefaults, systemIsDark: Bool) -> String {
        let selection = Selection(
            themeChoice: systemIdentifier,
            lightIdentifier: defaults.string(forKey: lightChoiceKey),
            darkIdentifier: defaults.string(forKey: darkChoiceKey))
        return selection.activeIdentifier(systemIsDark: systemIsDark)
    }

    /// Empty, whitespace-only, or "system" values cannot be pair members: the
    /// last would make the catalog resolve "system" through itself.
    fileprivate static func pairMember(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == systemIdentifier { return fallback }
        return trimmed
    }
}
