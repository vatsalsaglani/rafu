import Testing

@testable import RafuApp

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
