import SwiftUI

extension RafuThemeCatalog {
    /// The theme "Follow System" resolves to: the user's Light or Dark
    /// appearance pick, read from `defaults` (defaults: Khadi light, Indigo
    /// dark — what "System" always meant). An unknown, deleted, or unreadable
    /// pick falls back to the built-in default for that appearance instead of
    /// resolving "system" through itself.
    static func systemPairTheme(
        systemScheme: ColorScheme,
        defaults: UserDefaults = .standard
    ) -> RafuTheme {
        let isDark = systemScheme == .dark
        let identifier = ThemeAppearancePreference.pairIdentifier(
            defaults: defaults, systemIsDark: isDark)
        if let choice = RafuThemeChoice(rawValue: identifier), choice != .system {
            return resolved(choice: choice, systemScheme: systemScheme)
        }
        if identifier.hasPrefix("user:") {
            let filename = String(identifier.dropFirst("user:".count))
            let url = ThemeFileService.themesDirectory.appending(path: filename)
            if let data = try? Data(contentsOf: url),
                let theme = try? JSONDecoder().decode(RafuTheme.self, from: data)
            {
                return theme
            }
        }
        return isDark ? indigo : khadi
    }
}
