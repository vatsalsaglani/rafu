import Foundation
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Theme appearance pair")
struct ThemeAppearancePreferenceTests {
    private typealias Selection = ThemeAppearancePreference.Selection

    @MainActor
    @Test("The system identifier matches RafuThemeChoice.system")
    func systemIdentifierMatchesChoice() {
        #expect(ThemeAppearancePreference.systemIdentifier == RafuThemeChoice.system.rawValue)
        #expect(RafuThemeChoice(rawValue: ThemeAppearancePreference.defaultLightIdentifier) == .khadi)
        #expect(RafuThemeChoice(rawValue: ThemeAppearancePreference.defaultDarkIdentifier) == .indigo)
    }

    @Test("An old System selection follows the system with Khadi light and Indigo dark")
    func oldSystemSelectionMapsToDefaults() {
        let selection = Selection(themeChoice: "system", lightIdentifier: nil, darkIdentifier: nil)
        #expect(selection.followsSystem)
        #expect(selection.activeIdentifier(systemIsDark: false) == "khadi")
        #expect(selection.activeIdentifier(systemIsDark: true) == "indigo")
    }

    @Test("An old specific selection stays fixed with Follow System off")
    func oldSpecificSelectionStaysFixed() {
        let selection = Selection(themeChoice: "dracula", lightIdentifier: nil, darkIdentifier: nil)
        #expect(!selection.followsSystem)
        #expect(selection.activeIdentifier(systemIsDark: false) == "dracula")
        #expect(selection.activeIdentifier(systemIsDark: true) == "dracula")
    }

    @Test("A custom pair is used when the system appearance changes")
    func pairFollowsSystemAppearance() {
        let selection = Selection(
            themeChoice: "system", lightIdentifier: "githubLight", darkIdentifier: "dracula")
        #expect(selection.activeIdentifier(systemIsDark: false) == "githubLight")
        #expect(selection.activeIdentifier(systemIsDark: true) == "dracula")
        #expect(selection.isActive("githubLight"))
        #expect(selection.isActive("dracula"))
        #expect(!selection.isActive("indigo"))
    }

    @Test("Missing, empty, or self-referencing pair members fall back to the defaults")
    func invalidPairMembersFallBack() {
        let selection = Selection(
            themeChoice: "system", lightIdentifier: "system", darkIdentifier: "  ")
        #expect(selection.lightIdentifier == "khadi")
        #expect(selection.darkIdentifier == "indigo")
    }

    @Test("Turning Follow System off pins the theme that is active right now")
    func turningFollowSystemOffPinsCurrentTheme() {
        let selection = Selection(
            themeChoice: "system", lightIdentifier: "notionLight", darkIdentifier: "dracula")
        let lightPinned = selection.settingFollowsSystem(false, systemIsDark: false)
        #expect(lightPinned.themeChoice == "notionLight")
        #expect(!lightPinned.followsSystem)
        let darkPinned = selection.settingFollowsSystem(false, systemIsDark: true)
        #expect(darkPinned.themeChoice == "dracula")
        // The pair survives, so turning it back on restores it.
        let restored = darkPinned.settingFollowsSystem(true, systemIsDark: true)
        #expect(restored == selection)
    }

    @Test("Choosing a theme fills the matching slot while following, else replaces the fixed theme")
    func selectingRespectsMode() {
        let following = Selection(themeChoice: "system", lightIdentifier: nil, darkIdentifier: nil)
        let light = following.selecting("notionLight", isDark: false)
        #expect(light.followsSystem)
        #expect(light.lightIdentifier == "notionLight")
        #expect(light.darkIdentifier == "indigo")
        let dark = following.selecting("dracula", isDark: true)
        #expect(dark.followsSystem)
        #expect(dark.darkIdentifier == "dracula")
        #expect(dark.lightIdentifier == "khadi")

        let fixed = Selection(themeChoice: "khadi", lightIdentifier: nil, darkIdentifier: nil)
        let changed = fixed.selecting("dracula", isDark: true)
        #expect(changed.themeChoice == "dracula")
        #expect(!changed.followsSystem)
        #expect(changed.lightIdentifier == "khadi")
        #expect(changed.darkIdentifier == "indigo")
    }

    @Test("A fixed theme is the only active card")
    func fixedThemeIsOnlyActive() {
        let selection = Selection(themeChoice: "khadi", lightIdentifier: nil, darkIdentifier: nil)
        #expect(selection.isActive("khadi"))
        #expect(!selection.isActive("indigo"))
    }

    @Test("The pair is read from defaults, with defaults for unset keys")
    func pairReadsFromDefaults() throws {
        let suite = "RafuThemePairTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ThemeAppearancePreference.pairIdentifier(defaults: defaults, systemIsDark: false) == "khadi")
        #expect(ThemeAppearancePreference.pairIdentifier(defaults: defaults, systemIsDark: true) == "indigo")

        defaults.set("githubLight", forKey: ThemeAppearancePreference.lightChoiceKey)
        defaults.set("dracula", forKey: ThemeAppearancePreference.darkChoiceKey)
        #expect(
            ThemeAppearancePreference.pairIdentifier(defaults: defaults, systemIsDark: false)
                == "githubLight")
        #expect(
            ThemeAppearancePreference.pairIdentifier(defaults: defaults, systemIsDark: true)
                == "dracula")
    }

    @MainActor
    @Test("The System theme resolves through the stored pair for the system scheme")
    func systemThemeResolvesThroughPair() throws {
        let suite = "RafuThemePairTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(RafuThemeCatalog.systemPairTheme(systemScheme: .light, defaults: defaults).name == "Khadi")
        #expect(RafuThemeCatalog.systemPairTheme(systemScheme: .dark, defaults: defaults).name == "Indigo")

        defaults.set("githubLight", forKey: ThemeAppearancePreference.lightChoiceKey)
        defaults.set("dracula", forKey: ThemeAppearancePreference.darkChoiceKey)
        #expect(
            RafuThemeCatalog.systemPairTheme(systemScheme: .light, defaults: defaults).name
                == RafuThemeCatalog.githubLight.name)
        #expect(
            RafuThemeCatalog.systemPairTheme(systemScheme: .dark, defaults: defaults).name
                == RafuThemeCatalog.dracula.name)

        // A deleted custom theme falls back to the built-in default.
        defaults.set("user:does-not-exist.json", forKey: ThemeAppearancePreference.darkChoiceKey)
        #expect(RafuThemeCatalog.systemPairTheme(systemScheme: .dark, defaults: defaults).name == "Indigo")
    }
}
