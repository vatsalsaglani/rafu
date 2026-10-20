import SwiftUI

/// The colours a usage card and its rings use. Every value comes from the
/// active Rafu theme (or the notch's `NotchInk`, which derives from it), so
/// callers choose the surface and the ring never hardcodes a colour.
struct UsageCardInk {
    let primary: Color
    let secondary: Color
    let muted: Color
    /// The single-ring fallback colour for a tone with no entry in
    /// `toneColors` (kept so an out-of-range tone never traps).
    let arc: Color
    let warning: Color
    let critical: Color
    /// The card fill, or `nil` where the container already draws one (a
    /// grouped `Form` row in Settings).
    let cardBackground: Color?
    /// Up to three ring/legend tone colours, outermost ring first —
    /// `UsageRingTone.primary`/`.secondary`/`.tertiary` index into this in
    /// order. A STABLE colour per ring (Activity style): `color(for:)` never
    /// recolours a ring by `UsageRingLevel`, so the colour always identifies
    /// WHICH window a ring is, never how urgent it is. Warning/critical
    /// meaning lives only in the legend's glyph and text
    /// (`warningTint(for:)`, `UsageRingClusterView`). `UsageRingPalette`
    /// picks three hues or one neutral ink at stepped opacities.
    let toneColors: [Color]
    /// One shared track colour for every ring, or `nil` to let each ring
    /// tint its track from its own colour (`RafuProgressRing`). Monochrome
    /// sets it, so a faint ring's track is not fainter still.
    let trackColor: Color?

    /// Monochrome ring opacities over the ink's primary text colour,
    /// outermost first. Steps of roughly 0.25–0.4 keep three nested rings
    /// apart on the dark notch and in a light or dark Settings form;
    /// Increase Contrast lifts the two fainter rings, keeping the order.
    nonisolated static func monochromeOpacities(increasedContrast: Bool) -> [Double] {
        increasedContrast ? [1.0, 0.78, 0.58] : [1.0, 0.62, 0.38]
    }

    /// The monochrome track opacity over the same ink. It stays under the
    /// faintest ring's opacity so an unfilled track never reads as a fill.
    nonisolated static func monochromeTrackOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.24 : 0.14
    }

    /// The notch panel is always dark, so light themes use white ink there
    /// (`NotchInk`).
    static func notch(
        theme: RafuTheme, palette: UsageRingPalette = .color, increasedContrast: Bool = false
    ) -> UsageCardInk {
        let ink = NotchInk(theme: theme)
        let rings = RingInk(
            palette: palette, theme: theme, neutral: ink.primary,
            increasedContrast: increasedContrast)
        return UsageCardInk(
            primary: ink.primary, secondary: ink.secondary, muted: ink.muted,
            arc: rings.fallback ?? ink.accent, warning: theme.palette.warning,
            critical: theme.palette.error,
            cardBackground: Color.white.opacity(0.05),
            toneColors: rings.tones, trackColor: rings.track)
    }

    /// Settings uses system text styles inside the grouped form.
    static func settings(
        theme: RafuTheme, palette: UsageRingPalette = .color, increasedContrast: Bool = false
    ) -> UsageCardInk {
        let rings = RingInk(
            palette: palette, theme: theme, neutral: Color.primary,
            increasedContrast: increasedContrast)
        return UsageCardInk(
            primary: Color.primary, secondary: Color.secondary, muted: Color.secondary,
            arc: rings.fallback ?? theme.palette.accent, warning: theme.palette.warning,
            critical: theme.palette.error,
            cardBackground: nil,
            toneColors: rings.tones, trackColor: rings.track)
    }

    /// The STABLE ring/legend-swatch colour for one tone — identifies which
    /// window a ring is, never how urgent it is. See `warningTint(for:)`
    /// for the separate, non-colour-alone warning signal.
    func color(for tone: UsageRingTone) -> Color {
        let index: Int
        switch tone {
        case .primary: index = 0
        case .secondary: index = 1
        case .tertiary: index = 2
        }
        return toneColors.indices.contains(index) ? toneColors[index] : arc
    }

    /// The legend glyph's colour for a level above `.normal`. Callers
    /// already guard `level != .normal` before reading this. Unchanged by
    /// `UsageRingPalette`: warning colour is meaning, not decoration.
    func warningTint(for level: UsageRingLevel) -> Color {
        level == .critical ? critical : warning
    }
}

/// The ring colours one `UsageRingPalette` resolves to on one surface.
private struct RingInk {
    let tones: [Color]
    let track: Color?
    /// Overrides the surface's out-of-range fallback; `nil` keeps it.
    let fallback: Color?

    init(palette: UsageRingPalette, theme: RafuTheme, neutral: Color, increasedContrast: Bool) {
        switch palette {
        case .color:
            // `accent`/`info`/`success` sit at roughly 35°/220°/135° of hue
            // in both Indigo and Khadi — far enough apart to read as three
            // distinct rings on the always-dark notch panel as well as in
            // Settings, light or dark.
            tones = [theme.palette.accent, theme.palette.info, theme.palette.success]
            track = nil
            fallback = nil
        case .monochrome:
            let opacities = UsageCardInk.monochromeOpacities(increasedContrast: increasedContrast)
            tones = opacities.map { neutral.opacity($0) }
            track = neutral.opacity(
                UsageCardInk.monochromeTrackOpacity(increasedContrast: increasedContrast))
            fallback = neutral
        }
    }
}
