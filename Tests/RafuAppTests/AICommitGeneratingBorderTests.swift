import AppKit
import SwiftUI
import Testing

@testable import RafuApp

/// Resolves two SwiftUI `Color`s to sRGB and compares components (mirrors
/// `RafuThemeTests.sameColor` — `Color` has no reliable `==`).
@MainActor
private func sameColor(_ lhs: Color, _ rhs: Color, tolerance: CGFloat = 0.001) -> Bool {
    guard
        let l = NSColor(lhs).usingColorSpace(.sRGB),
        let r = NSColor(rhs).usingColorSpace(.sRGB)
    else { return false }
    return abs(l.redComponent - r.redComponent) < tolerance
        && abs(l.greenComponent - r.greenComponent) < tolerance
        && abs(l.blueComponent - r.blueComponent) < tolerance
        && abs(l.alphaComponent - r.alphaComponent) < tolerance
}

@Test(
    "gradientColors mixes the theme's accent, info, and git tokens, starting and ending on accent")
@MainActor
func gradientColorsMixesThemeTokens() {
    for theme in [RafuThemeCatalog.indigo, RafuThemeCatalog.khadi] {
        let palette = theme.palette
        let colors = AICommitGeneratingBorder.gradientColors(from: palette)

        #expect(colors.count == 5)
        #expect(sameColor(colors[0], palette.accent))
        #expect(sameColor(colors[1], palette.info))
        #expect(sameColor(colors[2], palette.gitAdded))
        #expect(sameColor(colors[3], palette.gitModified))
        // An AngularGradient's first and last stop must match for a seamless
        // loop at the 0°/360° wrap.
        #expect(sameColor(colors[4], colors[0]))
    }
}

@Test("gradientColors differs across themes with distinct accents")
@MainActor
func gradientColorsDiffersAcrossThemes() {
    let indigoColors = AICommitGeneratingBorder.gradientColors(
        from: RafuThemeCatalog.indigo.palette)
    let khadiColors = AICommitGeneratingBorder.gradientColors(from: RafuThemeCatalog.khadi.palette)
    #expect(!sameColor(indigoColors[0], khadiColors[0]))
}
