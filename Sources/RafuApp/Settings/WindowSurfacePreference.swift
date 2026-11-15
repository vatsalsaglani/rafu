import Foundation

/// Pure rules for Settings ▸ Appearance ▸ Window background (Solid or
/// Frosted) and its Frost strength.
///
/// Frosted shows the desktop, blurred and tinted with the theme's frame
/// colour, through the window frame (titlebar row, Activity Rail, sidebar,
/// status bar, and the gutter round the deck). The deck card shows a little
/// of it too, but less than the frame: its tab shelf, Ensemble board and
/// rows paint their tone at `deckOpacity`, Ensemble cards and board
/// controls opaque (`boardCard`), and the editor, terminals and previews at
/// `contentOpacity` (opaque when "Frost the editor and terminals" is off).
/// Solid is the default and paints every surface opaque.
///
/// Reduce Transparency or Increase Contrast always gives Solid, whatever the
/// stored setting. The resolver applies this itself: an
/// `NSVisualEffectView` falls back to a system grey, not the theme colour.
nonisolated enum WindowSurfacePreference {
    static let styleKey = "windowSurfaceStyle"
    static let frostLevelKey = "windowSurfaceFrost"
    /// Settings ▸ Appearance ▸ Window ▸ "Frost the editor and terminals".
    /// Missing means on.
    static let frostContentKey = "windowSurfaceFrostContent"

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

    /// The opacities of one Frosted window. Every value is the opacity a
    /// surface reaches over the blurred desktop, not the alpha its own fill
    /// uses: a fill that lies over another translucent fill uses
    /// `paintOpacity(for:)` so the two do not stack.
    nonisolated struct Frost: Equatable, Sendable {
        /// The frame's `appBackground` tint over the blur.
        var tintOpacity: Double
        /// The deck's own surfaces: tab shelf, rows, Ensemble board, empty
        /// states. Higher than the frame, so the middle stays calmer.
        var deckOpacity: Double
        /// The `card` layer's target over the board (the tab shelf fade)
        /// and the `pinned` header's floor. Ensemble cards and board
        /// controls are opaque (`boardCard`).
        var cardOpacity: Double
        /// "Frost the editor and terminals". Off keeps text surfaces opaque.
        var frostsContent: Bool

        /// The editor, terminals, previews and diffs.
        var contentOpacity: Double { frostsContent ? deckOpacity : 1 }
    }

    /// Where a fill sits in the deck. Picks the opacity it paints with.
    nonisolated enum DeckLayer: Equatable, Sendable, CaseIterable {
        /// A deck surface painted straight over the frame: tab shelf, rows,
        /// Ensemble board, empty states.
        case deck
        /// A text surface painted straight over the frame: editor,
        /// terminal, preview, diff.
        case content
        /// A translucent card tone painted over the board (the tab shelf
        /// fade uses its alpha). Ensemble cards and board controls use
        /// `boardCard`.
        case card
        /// An Ensemble card or a floating board control. Always opaque:
        /// cards and controls lie over other cards, and any alpha below 1
        /// lets the card below show through.
        case boardCard
        /// Editor-like content inside a card (a note being edited, a
        /// code view), painted over the card's own fill: clear when frosted,
        /// so the card's fill shows. Terminals use
        /// `terminalBackgroundAlpha` instead (see there).
        case cardContent
        /// A sticky header painted over scrolled content of the same tone.
        case pinned
        /// A fill of the same tone as the base already under it. Needed
        /// only in Solid; it paints nothing in Frosted.
        case underlay
        /// The opposite of `underlay`: a deck base needed only in Frosted,
        /// where the opaque base Solid has under it is gone. Paints nothing
        /// in Solid.
        case frostedBase
    }

    /// What a window paints.
    nonisolated enum Resolved: Equatable, Sendable {
        case solid
        case frosted(Frost)

        var isFrosted: Bool {
            if case .frosted = self { return true }
            return false
        }

        /// The frame's tint over the blur. 1 for Solid: fully opaque.
        var tintOpacity: Double { frost?.tintOpacity ?? 1 }
        /// 1 for Solid.
        var deckOpacity: Double { frost?.deckOpacity ?? 1 }
        /// 1 for Solid.
        var cardOpacity: Double { frost?.cardOpacity ?? 1 }
        /// 1 for Solid, and when the editor and terminals are kept opaque.
        var contentOpacity: Double { frost?.contentOpacity ?? 1 }
        /// False for Solid.
        var frostsContent: Bool { frost?.frostsContent ?? false }

        private var frost: Frost? {
            if case .frosted(let frost) = self { return frost }
            return nil
        }

        /// The alpha a fill on `layer` paints with, so the surface reaches
        /// its target opacity over whatever lies under it. 1 in Solid
        /// (0 for `frostedBase`).
        func paintOpacity(for layer: DeckLayer) -> Double {
            guard let frost else { return layer == .frostedBase ? 0 : 1 }
            switch layer {
            case .deck, .frostedBase: return frost.deckOpacity
            case .content: return frost.contentOpacity
            case .card:
                return WindowSurfacePreference.layeredOpacity(
                    target: frost.cardOpacity, over: frost.deckOpacity)
            case .boardCard: return 1
            case .cardContent:
                return frost.frostsContent ? 0 : 1
            case .pinned:
                return WindowSurfacePreference.layeredOpacity(
                    target: max(frost.cardOpacity, frost.contentOpacity),
                    over: frost.contentOpacity)
            case .underlay: return 0
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
    /// Balanced. `frostsContent` is "Frost the editor and terminals".
    static func resolve(
        style: String?,
        level: String?,
        frostsContent: Bool = true,
        isDark: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Resolved {
        guard Style(rawValue: style ?? "") == .frosted,
            forcedSolidReason(
                reduceTransparency: reduceTransparency, increaseContrast: increaseContrast) == nil
        else { return .solid }
        let frost = FrostLevel(rawValue: level ?? "") ?? .balanced
        return .frosted(
            Frost(
                tintOpacity: tintOpacity(for: frost, isDark: isDark),
                deckOpacity: deckOpacity(for: frost, isDark: isDark),
                cardOpacity: cardOpacity(for: frost, isDark: isDark),
                frostsContent: frostsContent))
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

    /// The deck's opacity: well above the frame's tint, so the deck reads
    /// as a calm card that only hints at the desktop. Light themes need
    /// more, for the same reason as the tint.
    static func deckOpacity(for level: FrostLevel, isDark: Bool) -> Double {
        switch (level, isDark) {
        case (.subtle, true): 0.90
        case (.balanced, true): 0.82
        case (.strong, true): 0.72
        case (.subtle, false): 0.94
        case (.balanced, false): 0.88
        case (.strong, false): 0.80
        }
    }

    /// An Ensemble card's opacity over the desktop: above the deck, so a
    /// card stands out from the board and its text stays readable.
    static func cardOpacity(for level: FrostLevel, isDark: Bool) -> Double {
        switch (level, isDark) {
        case (.subtle, true): 0.96
        case (.balanced, true): 0.94
        case (.strong, true): 0.90
        case (.subtle, false): 0.98
        case (.balanced, false): 0.96
        case (.strong, false): 0.93
        }
    }

    /// The alpha a fill needs over a base of opacity `over` so the two
    /// together reach `target` (source-over: `a + over × (1 − a)`). 0 when
    /// the base already reaches the target; 1 when the base is opaque.
    static func layeredOpacity(target: Double, over base: Double) -> Double {
        guard base < 1 else { return 1 }
        guard target > base else { return 0 }
        return min(1, (target - base) / (1 - base))
    }

    /// The alpha of SwiftTerm's `nativeBackgroundColor`, in a terminal
    /// tab, a Terminal Group pane and an Ensemble card alike. SwiftTerm
    /// draws inverse-video text (SGR 7) in this same colour, so it must
    /// never be 0 or that text vanishes: it is the content opacity (at
    /// least 0.72), never the "clear over a base" alpha. The RGB stays the
    /// theme's, so dim text (SGR 2) still mixes toward it.
    static func terminalBackgroundAlpha(_ surface: Resolved) -> Double {
        surface.contentOpacity
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
