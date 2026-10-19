import SwiftUI

/// The colours a usage card and its rings use. Every value comes from the
/// active Rafu theme (or the notch's `NotchInk`, which derives from it), so
/// callers choose the surface and the ring never hardcodes a colour.
struct UsageCardInk {
    let primary: Color
    let secondary: Color
    let muted: Color
    /// The ring's track: the subtle border token.
    let track: Color
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
    /// order. A level above `.normal` overrides the tone entirely (see
    /// `color(for:level:)`), so the signal never depends on which ring
    /// happens to carry it.
    let toneColors: [Color]

    /// The notch panel is always dark, so light themes use white ink there
    /// (`NotchInk`) and a light track instead of the light theme's border.
    static func notch(theme: RafuTheme) -> UsageCardInk {
        let ink = NotchInk(theme: theme)
        return UsageCardInk(
            primary: ink.primary, secondary: ink.secondary, muted: ink.muted,
            track: theme.isDark ? theme.palette.borderSubtle : Color.white.opacity(0.18),
            arc: ink.accent, warning: theme.palette.warning, critical: theme.palette.error,
            cardBackground: Color.white.opacity(0.05),
            // Same ramp as `.settings` for now — the notch panel is always
            // dark, so `info`/`success` may read too close to `accent`
            // there. Flagged for the ring launch pass rather than guessed
            // at here; see docs/decisions and the usage-rings phase note.
            toneColors: [theme.palette.accent, theme.palette.info, theme.palette.success])
    }

    /// Settings uses system text styles inside the grouped form.
    static func settings(theme: RafuTheme) -> UsageCardInk {
        UsageCardInk(
            primary: Color.primary, secondary: Color.secondary, muted: Color.secondary,
            track: theme.palette.borderSubtle, arc: theme.palette.accent,
            warning: theme.palette.warning, critical: theme.palette.error,
            cardBackground: nil,
            toneColors: [theme.palette.accent, theme.palette.info, theme.palette.success])
    }

    /// The colour for one ring/legend row: its tone at `.normal`, else the
    /// warning/critical token — never colour alone (a glyph/triangle beside
    /// it in `UsageRingClusterView` carries the non-colour signal).
    func color(for tone: UsageRingTone, level: UsageRingLevel) -> Color {
        switch level {
        case .normal: toneColor(for: tone)
        case .warning: warning
        case .critical: critical
        }
    }

    private func toneColor(for tone: UsageRingTone) -> Color {
        let index: Int
        switch tone {
        case .primary: index = 0
        case .secondary: index = 1
        case .tertiary: index = 2
        }
        return toneColors.indices.contains(index) ? toneColors[index] : arc
    }
}
