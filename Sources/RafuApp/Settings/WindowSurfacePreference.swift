import Foundation

/// Pure rules for Settings ▸ Appearance ▸ Window background (Solid or
/// Frosted) and its Frost strength.
///
/// Frosted shows the desktop, blurred and tinted with the theme's frame
/// colour, through the window frame (titlebar row, Activity Rail, sidebar,
/// status bar, and the gutter round the deck). The deck card and its editor,
/// terminal and previews stay opaque. Solid is the default.
///
/// Reduce Transparency or Increase Contrast always gives Solid, whatever the
/// stored setting. The resolver applies this itself: an
/// `NSVisualEffectView` falls back to a system grey, not the theme colour.
nonisolated enum WindowSurfacePreference {
    static let styleKey = "windowSurfaceStyle"
    static let frostLevelKey = "windowSurfaceFrost"

    nonisolated enum Style: String, CaseIterable, Sendable {
        case solid
        case frosted

        var title: String {
            switch self {
            case .solid: "Solid"
            case .frosted: "Frosted"
            }
        }
    }

    nonisolated enum FrostLevel: String, CaseIterable, Sendable {
        case subtle
        case balanced
        case strong

        var title: String {
            switch self {
            case .subtle: "Subtle"
            case .balanced: "Balanced"
            case .strong: "Strong"
            }
        }
    }

    /// What a window paints. `tintOpacity` is the opacity of the theme's
    /// `appBackground` laid over the blur: lower shows more of the desktop.
    nonisolated enum Resolved: Equatable, Sendable {
        case solid
        case frosted(tintOpacity: Double)

        var isFrosted: Bool {
            if case .frosted = self { return true }
            return false
        }

        /// 1 for Solid: the frame colour is fully opaque.
        var tintOpacity: Double {
            switch self {
            case .solid: 1
            case .frosted(let opacity): opacity
            }
        }
    }

    /// Why the stored Frosted setting does not apply, for the Settings
    /// footnote.
    nonisolated enum ForcedSolidReason: Equatable, Sendable {
        case reduceTransparency
        case increaseContrast

        var explanation: String {
            switch self {
            case .reduceTransparency:
                "Reduce Transparency is on in System Settings, so Rafu uses the solid window background."
            case .increaseContrast:
                "Increase Contrast is on in System Settings, so Rafu uses the solid window background."
            }
        }
    }

    static func forcedSolidReason(
        reduceTransparency: Bool, increaseContrast: Bool
    ) -> ForcedSolidReason? {
        if reduceTransparency { return .reduceTransparency }
        if increaseContrast { return .increaseContrast }
        return nil
    }

    /// Unknown or missing `style` is Solid; unknown or missing `level` is
    /// Balanced.
    static func resolve(
        style: String?,
        level: String?,
        isDark: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Resolved {
        guard Style(rawValue: style ?? "") == .frosted,
            forcedSolidReason(
                reduceTransparency: reduceTransparency, increaseContrast: increaseContrast) == nil
        else { return .solid }
        let frost = FrostLevel(rawValue: level ?? "") ?? .balanced
        return .frosted(tintOpacity: tintOpacity(for: frost, isDark: isDark))
    }

    /// Tint opacity per strength and theme appearance. A dark tint over a
    /// bright desktop reads darker than a light tint over a dark one, so dark
    /// themes need less tint for the same amount of frost. Balanced dark is
    /// 0.50, the value the user chose by eye in Indigo during the spike.
    static func tintOpacity(for level: FrostLevel, isDark: Bool) -> Double {
        switch (level, isDark) {
        case (.subtle, true): 0.62
        case (.balanced, true): 0.50
        case (.strong, true): 0.38
        case (.subtle, false): 0.86
        case (.balanced, false): 0.74
        case (.strong, false): 0.60
        }
    }

    // MARK: Spike migration

    /// The debug defaults of the Step 0 spike (`RafuFrostSpike*`).
    static let spikeKeys = [
        "RafuFrostSpike",
        "RafuFrostSpikeMaterial",
        "RafuFrostSpikeState",
        "RafuFrostSpikeTint",
        "RafuFrostSpikeWedge",
        "RafuFrostSpikeClear",
        "RafuFrostSpikeTerminalProbe",
        "RafuFrostSpikeTerminalClearLayer",
    ]

    /// One-time move from the spike's debug default to the real setting: a
    /// window that showed the spike's behind-window frost keeps it (Frosted,
    /// Balanced), and every spike key is removed. A setting the user already
    /// chose is never overwritten. Returns whether it changed the setting.
    @discardableResult
    static func migrateFrostSpike(defaults: UserDefaults) -> Bool {
        let presentKeys = spikeKeys.filter { defaults.object(forKey: $0) != nil }
        guard !presentKeys.isEmpty else { return false }
        var migrated = false
        if defaults.string(forKey: "RafuFrostSpike") == "visualEffect",
            defaults.object(forKey: styleKey) == nil
        {
            defaults.set(Style.frosted.rawValue, forKey: styleKey)
            defaults.set(FrostLevel.balanced.rawValue, forKey: frostLevelKey)
            migrated = true
        }
        for key in presentKeys {
            defaults.removeObject(forKey: key)
        }
        return migrated
    }
}
