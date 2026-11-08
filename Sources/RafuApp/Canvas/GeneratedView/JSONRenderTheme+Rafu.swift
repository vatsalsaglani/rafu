import AppKit
import JSONRenderSwiftUI
import SwiftUI
import os

extension JSONRenderTheme {
    /// The generated-view theme for a Rafu palette: colour roles from the
    /// palette, radii from `RafuMetrics`, and the package's native type,
    /// spacing, elevation, motion and chart tokens (one scale, not two).
    ///
    /// A role that fails the package contrast rules steps to a stronger role
    /// of the same palette (muted → secondary → primary text; on-accent →
    /// black or white). The fallback is reported once per theme by
    /// `GeneratedViewThemeCache`; it is a theme fact, not hidden.
    nonisolated static func rafu(_ palette: RafuThemePalette) -> JSONRenderTheme {
        rafuWithFallbacks(palette).theme
    }

    /// The mapped theme and the role names that needed a fallback.
    nonisolated static func rafuWithFallbacks(_ palette: RafuThemePalette)
        -> (theme: JSONRenderTheme, fallbacks: [String])
    {
        var theme = JSONRenderTheme.native
        theme.color = ColorRoles(
            surface: palette.cardBackground, surfaceRaised: palette.elevatedBackground,
            text: palette.textPrimary, textSecondary: palette.textSecondary,
            textMuted: palette.textMuted, hairline: palette.borderSubtle, accent: palette.accent,
            onAccent: palette.onAccent, good: palette.success, warning: palette.warning,
            critical: palette.error, info: palette.info, focus: palette.focusRing)
        theme.radius = RadiusScale(
            control: RafuMetrics.radiusControl, field: RafuMetrics.radiusField,
            card: RafuMetrics.radiusDenseCard)
        var fallbacks: [String] = []
        // Three passes: a fallback can itself fail one rule (muted → secondary
        // → primary).
        for _ in 0..<3 {
            let failing = Set(theme.contrastReport().filter { !$0.passes }.map(\.foreground))
            guard !failing.isEmpty else { break }
            var changed = false
            for role in failing.sorted() {
                switch role {
                case "textMuted" where theme.color.textMuted != theme.color.textSecondary:
                    theme.color.textMuted = theme.color.textSecondary
                case "textSecondary" where theme.color.textSecondary != theme.color.text:
                    theme.color.textSecondary = theme.color.text
                    theme.color.textMuted = theme.color.text
                case "onAccent":
                    let better = GeneratedViewContrast.blackOrWhite(on: theme.color.accent)
                    guard better != theme.color.onAccent else { continue }
                    theme.color.onAccent = better
                case "accent" where theme.color.accent != theme.color.text:
                    theme.color.accent = theme.color.text
                    theme.color.focus = theme.color.text
                    theme.color.onAccent = GeneratedViewContrast.blackOrWhite(on: theme.color.text)
                default:
                    continue
                }
                fallbacks.append(role)
                changed = true
            }
            if !changed { break }
        }
        return (theme, fallbacks)
    }
}

/// Black or white text on a colour, by WCAG relative luminance.
nonisolated enum GeneratedViewContrast {
    static func blackOrWhite(on color: Color) -> Color {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance =
            0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722
            * linear(srgb.blueComponent)
        // Contrast with black is (L + 0.05) / 0.05; with white 1.05 / (L + 0.05).
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
    }
}

/// One mapped theme per Rafu theme, so a card body does not measure contrast
/// on every render. Logs a fallback once per theme, with role names only.
@MainActor
enum GeneratedViewThemeCache {
    private static var themes: [String: JSONRenderTheme] = [:]
    private static let logger = Logger(
        subsystem: "dev.vatsalsaglani.rafu", category: "GeneratedViewTheme")

    static func theme(for rafuTheme: RafuTheme) -> JSONRenderTheme {
        let palette = rafuTheme.palette
        let key = [
            rafuTheme.name, rafuTheme.appearance, palette.cardBackground.description,
            palette.textPrimary.description, palette.accent.description,
        ].joined(separator: "|")
        if let cached = themes[key] { return cached }
        let (theme, fallbacks) = JSONRenderTheme.rafuWithFallbacks(palette)
        if !fallbacks.isEmpty {
            logger.notice(
                "View theme contrast fallback for \(rafuTheme.name, privacy: .public): \(fallbacks.joined(separator: ", "), privacy: .public)"
            )
        }
        if themes.count > 16 { themes.removeAll() }
        themes[key] = theme
        return theme
    }
}
