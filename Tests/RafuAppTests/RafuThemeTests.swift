import AppKit
import SwiftUI
import Testing

@testable import RafuApp

/// Resolves two SwiftUI `Color`s to sRGB and compares components so palette
/// fallback derivations can be asserted (Color has no reliable `==`).
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

/// Minimal valid theme JSON with only the required keys, plus overridable
/// extras appended verbatim inside the `ui` object.
private func minimalThemeJSON(extraUI: String = "") -> Data {
    """
    {
      "name": "Probe", "appearance": "dark",
      "ui": {
        "appBackground": "#101010", "editorBackground": "#151515",
        "elevatedBackground": "#1B1B1B", "textPrimary": "#EEEEEE",
        "textSecondary": "#AAAAAA", "accent": "#3366FF",
        "borderSubtle": "#262626", "selection": "#242424"\(extraUI.isEmpty ? "" : ",\n\(extraUI)")
      },
      "editor": {
        "background": "#151515", "foreground": "#EEEEEE", "cursor": "#FFFFFF",
        "selectionBackground": "#333333", "lineHighlight": "#1E1E1E"
      },
      "syntax": { "keyword": { "color": "#CC88FF" } }
    }
    """.data(using: .utf8)!
}

@Test("Bundled Indigo and Khadi JSON themes decode as distinct appearances")
@MainActor
func bundledThemesDecode() {
    #expect(RafuThemeCatalog.indigo.name == "Indigo")
    #expect(RafuThemeCatalog.indigo.appearance == "dark")
    #expect(RafuThemeCatalog.khadi.name == "Khadi")
    #expect(RafuThemeCatalog.khadi.appearance == "light")
    #expect(RafuThemeCatalog.indigo.ui.accent != RafuThemeCatalog.khadi.ui.accent)
}

@Test("Every bundled theme resolves with complete editor and syntax colors")
@MainActor
func allBundledThemesResolve() {
    let themes = [
        RafuThemeCatalog.indigo,
        RafuThemeCatalog.khadi,
        RafuThemeCatalog.dracula,
        RafuThemeCatalog.notionLight,
        RafuThemeCatalog.notionDark,
        RafuThemeCatalog.githubLight,
        RafuThemeCatalog.githubDark,
    ]

    #expect(Set(themes.map(\.name)).count == themes.count)
    for theme in themes {
        #expect(theme.editor.background.hasPrefix("#"))
        #expect(theme.editor.foreground.hasPrefix("#"))
        #expect(theme.syntax["keyword"]?.color?.hasPrefix("#") == true)
    }
}

@Test("Flat-refresh palette keys derive fallbacks when a theme omits them")
@MainActor
func flatRefreshFallbacksDerive() throws {
    let theme = try JSONDecoder().decode(RafuTheme.self, from: minimalThemeJSON())
    let palette = theme.palette
    // cardBackground → elevatedBackground; fieldBackground → appBackground;
    // chipBackground → hover (→ selection when hover absent); accentSoft →
    // accent at ~14% alpha.
    #expect(sameColor(palette.cardBackground, Color(rafuHex: "#1B1B1B")))
    #expect(sameColor(palette.fieldBackground, Color(rafuHex: "#101010")))
    #expect(sameColor(palette.chipBackground, Color(rafuHex: "#242424")))
    #expect(sameColor(palette.accentSoft, Color(rafuHex: "#3366FF24")))
}

@Test("Flat-refresh palette keys decode when a theme provides them")
@MainActor
func flatRefreshKeysDecode() throws {
    let extra = """
            "cardBackground": "#222831", "fieldBackground": "#0A0A0A",
            "chipBackground": "#303030", "accentSoft": "#3366FF40"
        """
    let theme = try JSONDecoder().decode(
        RafuTheme.self, from: minimalThemeJSON(extraUI: extra))
    let palette = theme.palette
    #expect(sameColor(palette.cardBackground, Color(rafuHex: "#222831")))
    #expect(sameColor(palette.fieldBackground, Color(rafuHex: "#0A0A0A")))
    #expect(sameColor(palette.chipBackground, Color(rafuHex: "#303030")))
    #expect(sameColor(palette.accentSoft, Color(rafuHex: "#3366FF40")))
}

@Test("Bundled themes expose the flat-refresh palette keys")
@MainActor
func bundledThemesHaveFlatRefreshKeys() {
    // The bundled JSONs do not define the new keys yet (U0 is invisible), so
    // each must fall back to its derivation: card == elevated, field == app.
    for theme in [RafuThemeCatalog.indigo, RafuThemeCatalog.khadi] {
        #expect(
            sameColor(theme.palette.cardBackground, Color(rafuHex: theme.ui.elevatedBackground)))
        #expect(sameColor(theme.palette.fieldBackground, Color(rafuHex: theme.ui.appBackground)))
    }
}
