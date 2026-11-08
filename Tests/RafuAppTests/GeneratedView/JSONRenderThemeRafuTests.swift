import JSONRenderSwiftUI
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Generated view theme mapping")
@MainActor
struct JSONRenderThemeRafuTests {
    static let themes: [(String, RafuTheme)] = [
        ("Indigo", RafuThemeCatalog.indigo), ("Khadi", RafuThemeCatalog.khadi),
        ("Dracula", RafuThemeCatalog.dracula), ("Notion Light", RafuThemeCatalog.notionLight),
        ("Notion Dark", RafuThemeCatalog.notionDark),
        ("GitHub Light", RafuThemeCatalog.githubLight),
        ("GitHub Dark", RafuThemeCatalog.githubDark),
    ]

    @Test("Every bundled theme maps to a view theme that passes the contrast rules")
    func everyThemeValidates() throws {
        for (name, theme) in Self.themes {
            let mapped = JSONRenderTheme.rafu(theme.palette)
            #expect(throws: Never.self, "\(name)") { _ = try mapped.validated() }
        }
    }

    @Test("Radii come from RafuMetrics; type and spacing stay the package's")
    func metrics() {
        let mapped = JSONRenderTheme.rafu(RafuThemeCatalog.indigo.palette)
        #expect(mapped.radius.control == RafuMetrics.radiusControl)
        #expect(mapped.radius.field == RafuMetrics.radiusField)
        #expect(mapped.radius.card == RafuMetrics.radiusDenseCard)
        #expect(mapped.space == JSONRenderTheme.native.space)
        #expect(mapped.type == JSONRenderTheme.native.type)
        #expect(mapped.motion == JSONRenderTheme.native.motion)
    }

    @Test("Roles map from the palette where they pass")
    func roles() {
        let palette = RafuThemeCatalog.indigo.palette
        let (mapped, fallbacks) = JSONRenderTheme.rafuWithFallbacks(palette)
        #expect(mapped.color.surface == palette.cardBackground)
        #expect(mapped.color.text == palette.textPrimary)
        #expect(mapped.color.critical == palette.error)
        if !fallbacks.contains("accent") { #expect(mapped.color.accent == palette.accent) }
    }

    /// Records which bundled themes need a fallback role (a theme fact for the
    /// documentation; the test passes either way).
    @Test("Theme contrast fallbacks are reported, never hidden")
    func fallbackReport() {
        for (name, theme) in Self.themes {
            let (_, fallbacks) = JSONRenderTheme.rafuWithFallbacks(theme.palette)
            if !fallbacks.isEmpty {
                print("[theme fallback] \(name): \(fallbacks.joined(separator: ", "))")
            }
        }
    }
}
