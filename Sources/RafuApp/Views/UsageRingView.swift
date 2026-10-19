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
    /// order. A STABLE hue per ring (Activity style): `color(for:)` never
    /// recolours a ring by `UsageRingLevel`, so hue always identifies
    /// WHICH window a ring is, never how urgent it is. Warning/critical
    /// meaning lives only in the legend's glyph and text
    /// (`warningTint(for:)`, `UsageRingClusterView`).
    let toneColors: [Color]

    /// The notch panel is always dark, so light themes use white ink there
    /// (`NotchInk`).
    static func notch(theme: RafuTheme) -> UsageCardInk {
        let ink = NotchInk(theme: theme)
        return UsageCardInk(
            primary: ink.primary, secondary: ink.secondary, muted: ink.muted,
            arc: ink.accent, warning: theme.palette.warning, critical: theme.palette.error,
            cardBackground: Color.white.opacity(0.05),
            // Same ramp as `.settings`: `accent`/`info`/`success` sit at
            // roughly 35°/220°/135° of hue in both Indigo and Khadi — far
            // enough apart to read as three distinct rings on the always-
            // dark notch panel as well as in Settings, light or dark.
            toneColors: [theme.palette.accent, theme.palette.info, theme.palette.success])
    }

    /// Settings uses system text styles inside the grouped form.
    static func settings(theme: RafuTheme) -> UsageCardInk {
        UsageCardInk(
            primary: Color.primary, secondary: Color.secondary, muted: Color.secondary,
            arc: theme.palette.accent, warning: theme.palette.warning,
            critical: theme.palette.error,
            cardBackground: nil,
            toneColors: [theme.palette.accent, theme.palette.info, theme.palette.success])
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
    /// already guard `level != .normal` before reading this.
    func warningTint(for level: UsageRingLevel) -> Color {
        level == .critical ? critical : warning
    }
}
