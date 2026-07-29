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

@MainActor
private var bundledThemes: [RafuTheme] {
    [
        RafuThemeCatalog.indigo,
        RafuThemeCatalog.khadi,
        RafuThemeCatalog.dracula,
        RafuThemeCatalog.notionLight,
        RafuThemeCatalog.notionDark,
        RafuThemeCatalog.githubLight,
        RafuThemeCatalog.githubDark,
    ]
}

@MainActor
private func contrastRatio(_ foreground: Color, against background: Color) -> CGFloat {
    guard
        let foreground = NSColor(foreground).usingColorSpace(.sRGB),
        let background = NSColor(background).usingColorSpace(.sRGB)
    else { return 0 }

    let alpha = foreground.alphaComponent
    let foregroundComponents = [
        foreground.redComponent,
        foreground.greenComponent,
        foreground.blueComponent,
    ]
    let backgroundComponents = [
        background.redComponent,
        background.greenComponent,
        background.blueComponent,
    ]
    let composited = zip(foregroundComponents, backgroundComponents).map {
        $0 * alpha + $1 * (1 - alpha)
    }

    func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    let foregroundLuminance = luminance(composited)
    let backgroundLuminance = luminance(backgroundComponents)
    return
        (max(foregroundLuminance, backgroundLuminance) + 0.05)
        / (min(foregroundLuminance, backgroundLuminance) + 0.05)
}

private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appending(path: "Package.swift").path
        ) {
            return directory
        }
        directory = directory.deletingLastPathComponent()
    }
    throw ThemeContractTestError.repositoryRootNotFound
}

private enum ThemeContractTestError: Error {
    case repositoryRootNotFound
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
    #expect(Set(bundledThemes.map(\.name)).count == bundledThemes.count)
    for theme in bundledThemes {
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

@Test("The converged-surface fixture resolves through the user-theme catalog path unchanged")
@MainActor
func convergedSurfaceFixtureUsesPublicThemePath() throws {
    let root = try repositoryRoot()
    let fixtureURL = root.appending(
        path: "Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json"
    )
    let data = try Data(contentsOf: fixtureURL)
    let filename = "wp00-\(UUID().uuidString).json"
    let installedURL = ThemeFileService.themesDirectory.appending(path: filename)
    try FileManager.default.createDirectory(
        at: ThemeFileService.themesDirectory,
        withIntermediateDirectories: true
    )
    try data.write(to: installedURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: installedURL) }

    let theme = RafuThemeCatalog.resolved(
        identifier: "user:\(filename)",
        systemScheme: .light
    )
    #expect(theme.name == "Workbench Converged Surfaces")
    #expect(theme.appearance == "dark")

    let surfaces = [
        theme.palette.appBackground,
        theme.palette.sidebarBackground,
        theme.palette.editorBackground,
        theme.palette.elevatedBackground,
        theme.palette.statusBarBackground,
        theme.palette.tabBarBackground,
        theme.palette.tabActiveBackground,
        theme.palette.cardBackground,
        theme.palette.fieldBackground,
    ]
    #expect(surfaces.allSatisfy { sameColor($0, Color(rafuHex: "#202020")) })
}

@Test("A required-legacy-key-only theme still decodes without a new workbench key")
@MainActor
func legacyRequiredKeysRemainSufficient() throws {
    let theme = try JSONDecoder().decode(RafuTheme.self, from: minimalThemeJSON())
    #expect(theme.name == "Probe")
    #expect(sameColor(theme.palette.sidebarBackground, theme.palette.appBackground))
    #expect(sameColor(theme.palette.tabActiveBackground, theme.palette.editorBackground))
    #expect(sameColor(theme.palette.cardBackground, theme.palette.elevatedBackground))
    #expect(sameColor(theme.palette.fieldBackground, theme.palette.appBackground))
}

@Test("Bundled primary and essential secondary text meet 4.5 to 1 on immediate surfaces")
@MainActor
func bundledTextContrast() {
    for theme in bundledThemes {
        let palette = theme.palette
        let surfaces: [(String, Color)] = [
            ("app", palette.appBackground),
            ("sidebar", palette.sidebarBackground),
            ("editor", palette.editorBackground),
            ("elevated", palette.elevatedBackground),
            ("status", palette.statusBarBackground),
            ("tab shelf", palette.tabBarBackground),
            ("active tab", palette.tabActiveBackground),
            ("card", palette.cardBackground),
            ("field", palette.fieldBackground),
        ]
        for (surfaceName, surface) in surfaces {
            #expect(
                contrastRatio(palette.textPrimary, against: surface) >= 4.5,
                "\(theme.name) primary text on \(surfaceName)"
            )
            #expect(
                contrastRatio(palette.textSecondary, against: surface) >= 4.5,
                "\(theme.name) essential secondary text on \(surfaceName)"
            )
        }
    }
}

@Test("Bundled essential icons, focus, and necessary control boundaries meet 3 to 1")
@MainActor
func bundledNonTextContrast() {
    for theme in bundledThemes {
        let palette = theme.palette
        for (surfaceName, surface) in [
            ("app", palette.appBackground),
            ("sidebar", palette.sidebarBackground),
            ("editor", palette.editorBackground),
            ("elevated", palette.elevatedBackground),
        ] {
            #expect(
                contrastRatio(palette.accent, against: surface) >= 3,
                "\(theme.name) essential accent icon on \(surfaceName)"
            )
        }
        for (surfaceName, surface) in [
            ("field", palette.fieldBackground),
            ("editor", palette.editorBackground),
        ] {
            #expect(
                contrastRatio(palette.focusRing, against: surface) >= 3,
                "\(theme.name) focus indication on \(surfaceName)"
            )
        }
        for (surfaceName, surface) in [
            ("field", palette.fieldBackground),
            ("active tab", palette.tabActiveBackground),
        ] {
            #expect(
                contrastRatio(palette.borderStrong, against: surface) >= 3,
                "\(theme.name) necessary control boundary on \(surfaceName)"
            )
        }
    }
}

@Test("Decorative subtle hairlines are explicitly outside the contrast gate")
@MainActor
func decorativeHairlinesRemainExempt() {
    #expect(
        bundledThemes.contains {
            contrastRatio($0.palette.borderSubtle, against: $0.palette.editorBackground) < 3
        }
    )
}
