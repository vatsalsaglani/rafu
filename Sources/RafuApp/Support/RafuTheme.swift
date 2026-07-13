import AppKit
import SwiftUI

enum RafuThemeChoice: String, CaseIterable, Identifiable {
    case system
    case indigo
    case khadi
    case dracula
    case notionLight
    case notionDark
    case githubLight
    case githubDark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .indigo: "Indigo"
        case .khadi: "Khadi"
        case .dracula: "Dracula"
        case .notionLight: "Notion Light"
        case .notionDark: "Notion Dark"
        case .githubLight: "GitHub Light"
        case .githubDark: "GitHub Dark"
        }
    }
}

/// Pre-resolved SwiftUI colors for every theme token. Built once at decode so
/// view bodies never parse hex strings.
nonisolated struct RafuThemePalette: Sendable {
    // ui
    let appBackground: Color
    let sidebarBackground: Color
    let editorBackground: Color
    let elevatedBackground: Color
    let statusBarBackground: Color
    let tabBarBackground: Color
    let tabActiveBackground: Color
    let selection: Color
    let hover: Color
    let borderSubtle: Color
    let borderStrong: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color
    let accentHover: Color
    let onAccent: Color
    let focusRing: Color
    let error: Color
    let warning: Color
    let info: Color
    let success: Color
    let remoteIndicator: Color

    // editor extras used by chrome
    let gutterForeground: Color
    let gutterActiveForeground: Color
    let lineHighlight: Color

    // git
    let gitAdded: Color
    let gitModified: Color
    let gitDeleted: Color
    let gitRenamed: Color
    let gitUntracked: Color
    let gitIgnored: Color
    let gitConflict: Color
    let gitStaged: Color

    // diff
    let diffAddedBackground: Color
    let diffRemovedBackground: Color
    let diffAddedGutter: Color
    let diffRemovedGutter: Color
    let diffAddedWordBackground: Color
    let diffRemovedWordBackground: Color
}

nonisolated struct RafuTheme: Decodable, Sendable {
    nonisolated struct UIColors: Decodable, Sendable {
        let appBackground: String
        let editorBackground: String
        let elevatedBackground: String
        let textPrimary: String
        let textSecondary: String
        let accent: String
        let borderSubtle: String
        let selection: String
        // Optional richer tokens; fall back to derived values when absent so
        // older user themes keep loading.
        let sidebarBackground: String?
        let statusBarBackground: String?
        let tabBarBackground: String?
        let tabActiveBackground: String?
        let hover: String?
        let borderStrong: String?
        let textMuted: String?
        let accentHover: String?
        let onAccent: String?
        let focusRing: String?
        let error: String?
        let warning: String?
        let info: String?
        let success: String?
        let remoteIndicator: String?
    }

    nonisolated struct EditorColors: Decodable, Sendable {
        let background: String
        let foreground: String
        let cursor: String
        let selectionBackground: String
        let lineHighlight: String
        let inactiveSelectionBackground: String?
        let gutterBackground: String?
        let gutterForeground: String?
        let gutterActiveForeground: String?
        let indentGuide: String?
        let indentGuideActive: String?
        let matchingBracketBorder: String?
        let findMatchBackground: String?
        let findMatchActiveBackground: String?
        let whitespace: String?
        let rulerBorder: String?
    }

    nonisolated struct GitColors: Decodable, Sendable {
        let added: String?
        let modified: String?
        let deleted: String?
        let renamed: String?
        let untracked: String?
        let ignored: String?
        let conflict: String?
        let staged: String?
    }

    nonisolated struct DiffColors: Decodable, Sendable {
        let addedBackground: String?
        let removedBackground: String?
        let addedGutter: String?
        let removedGutter: String?
        let addedWordBackground: String?
        let removedWordBackground: String?
    }

    nonisolated struct ThemeFonts: Decodable, Sendable {
        nonisolated struct EditorFont: Decodable, Sendable {
            let family: String?
            let size: Double?
            let lineHeightMultiple: Double?
        }

        let editor: EditorFont?
    }

    nonisolated struct SyntaxToken: Decodable, Sendable {
        let color: String?
        let fontStyle: String?
        let underline: Bool?
        let background: String?
    }

    let name: String
    let appearance: String
    let ui: UIColors
    let editor: EditorColors
    let git: GitColors?
    let diff: DiffColors?
    let fonts: ThemeFonts?
    let syntax: [String: SyntaxToken]
    let palette: RafuThemePalette

    private enum CodingKeys: String, CodingKey {
        case name, appearance, ui, editor, git, diff, fonts, syntax
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        appearance = try container.decode(String.self, forKey: .appearance)
        ui = try container.decode(UIColors.self, forKey: .ui)
        editor = try container.decode(EditorColors.self, forKey: .editor)
        git = try container.decodeIfPresent(GitColors.self, forKey: .git)
        diff = try container.decodeIfPresent(DiffColors.self, forKey: .diff)
        fonts = try? container.decodeIfPresent(ThemeFonts.self, forKey: .fonts)
        syntax = try container.decode([String: SyntaxToken].self, forKey: .syntax)
        palette = Self.makePalette(ui: ui, editor: editor, git: git, diff: diff)
    }

    var colorScheme: ColorScheme { appearance == "dark" ? .dark : .light }
    var isDark: Bool { appearance == "dark" }

    var editorFontSize: CGFloat {
        CGFloat(fonts?.editor?.size ?? 13)
    }

    var editorLineHeightMultiple: CGFloat {
        CGFloat(fonts?.editor?.lineHeightMultiple ?? 1.4)
    }

    /// Resolves the theme's editor font. "SF Mono"/"system"/missing map to the
    /// system monospaced font, which is SF Mono on macOS.
    func resolvedEditorFont(weight: NSFont.Weight = .regular) -> NSFont {
        let size = editorFontSize
        if let family = fonts?.editor?.family,
            !["system", "SF Mono", ""].contains(family),
            let font = NSFont(name: family, size: size)
        {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func makePalette(
        ui: UIColors,
        editor: EditorColors,
        git: GitColors?,
        diff: DiffColors?
    ) -> RafuThemePalette {
        func color(_ hex: String) -> Color { Color(rafuHex: hex) }
        func color(_ hex: String?, fallback: String) -> Color {
            color(hex ?? fallback)
        }

        let errorHex = ui.error ?? "#E06C75"
        let warningHex = ui.warning ?? "#D4A24E"
        let infoHex = ui.info ?? "#82A7F0"
        let successHex = ui.success ?? "#7CC08A"
        let accentHex = ui.accent

        return RafuThemePalette(
            appBackground: color(ui.appBackground),
            sidebarBackground: color(ui.sidebarBackground, fallback: ui.appBackground),
            editorBackground: color(ui.editorBackground),
            elevatedBackground: color(ui.elevatedBackground),
            statusBarBackground: color(ui.statusBarBackground, fallback: ui.appBackground),
            tabBarBackground: color(ui.tabBarBackground, fallback: ui.appBackground),
            tabActiveBackground: color(ui.tabActiveBackground, fallback: ui.editorBackground),
            selection: color(ui.selection),
            hover: color(ui.hover, fallback: ui.selection),
            borderSubtle: color(ui.borderSubtle),
            borderStrong: color(ui.borderStrong, fallback: ui.borderSubtle),
            textPrimary: color(ui.textPrimary),
            textSecondary: color(ui.textSecondary),
            textMuted: color(ui.textMuted, fallback: ui.textSecondary),
            accent: color(accentHex),
            accentHover: color(ui.accentHover, fallback: accentHex),
            onAccent: color(ui.onAccent, fallback: ui.appBackground),
            focusRing: color(ui.focusRing, fallback: accentHex + "66"),
            error: color(errorHex),
            warning: color(warningHex),
            info: color(infoHex),
            success: color(successHex),
            remoteIndicator: color(ui.remoteIndicator, fallback: infoHex),
            gutterForeground: color(
                editor.gutterForeground, fallback: ui.textMuted ?? ui.textSecondary),
            gutterActiveForeground: color(
                editor.gutterActiveForeground, fallback: ui.textSecondary),
            lineHighlight: color(editor.lineHighlight),
            gitAdded: color(git?.added, fallback: successHex),
            gitModified: color(git?.modified, fallback: warningHex),
            gitDeleted: color(git?.deleted, fallback: errorHex),
            gitRenamed: color(git?.renamed, fallback: infoHex),
            gitUntracked: color(git?.untracked, fallback: infoHex),
            gitIgnored: color(git?.ignored, fallback: ui.textMuted ?? ui.textSecondary),
            gitConflict: color(git?.conflict, fallback: errorHex),
            gitStaged: color(git?.staged, fallback: successHex),
            diffAddedBackground: color(diff?.addedBackground, fallback: successHex + "26"),
            diffRemovedBackground: color(diff?.removedBackground, fallback: errorHex + "26"),
            diffAddedGutter: color(diff?.addedGutter, fallback: successHex),
            diffRemovedGutter: color(diff?.removedGutter, fallback: errorHex),
            diffAddedWordBackground: color(diff?.addedWordBackground, fallback: successHex + "4D"),
            diffRemovedWordBackground: color(diff?.removedWordBackground, fallback: errorHex + "4D")
        )
    }
}

enum RafuThemeCatalog {
    static let indigo = load(named: "indigo")
    static let khadi = load(named: "khadi")
    static let dracula = load(named: "dracula")
    static let notionLight = load(named: "notion-light")
    static let notionDark = load(named: "notion-dark")
    static let githubLight = load(named: "github-light")
    static let githubDark = load(named: "github-dark")

    static func resolved(choice: RafuThemeChoice, systemScheme: ColorScheme) -> RafuTheme {
        switch choice {
        case .system: systemScheme == .dark ? indigo : khadi
        case .indigo: indigo
        case .khadi: khadi
        case .dracula: dracula
        case .notionLight: notionLight
        case .notionDark: notionDark
        case .githubLight: githubLight
        case .githubDark: githubDark
        }
    }

    static func resolved(identifier: String, systemScheme: ColorScheme) -> RafuTheme {
        if let choice = RafuThemeChoice(rawValue: identifier) {
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
        return resolved(choice: .system, systemScheme: systemScheme)
    }

    static func resourceURL(for choice: RafuThemeChoice) -> URL? {
        guard choice != .system else { return nil }
        let resourceName: String =
            switch choice {
            case .system: ""
            case .indigo: "indigo"
            case .khadi: "khadi"
            case .dracula: "dracula"
            case .notionLight: "notion-light"
            case .notionDark: "notion-dark"
            case .githubLight: "github-light"
            case .githubDark: "github-dark"
            }
        return Bundle.main.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "Themes"
        )
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Resources/Themes/\(resourceName).json")
    }

    private static func load(named name: String) -> RafuTheme {
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Themes"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Resources/Themes/\(name).json"),
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: candidate),
                let theme = try? JSONDecoder().decode(RafuTheme.self, from: data)
            {
                return theme
            }
        }
        fatalError("Missing bundled Rafu theme: \(name)")
    }
}

extension Color {
    nonisolated init(rafuHex: String) {
        self.init(nsColor: NSColor(rafuHex: rafuHex))
    }
}

extension NSColor {
    nonisolated convenience init(rafuHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var parsed: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&parsed)
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if hex.count == 8 {
            red = CGFloat((parsed >> 24) & 0xff) / 255
            green = CGFloat((parsed >> 16) & 0xff) / 255
            blue = CGFloat((parsed >> 8) & 0xff) / 255
            alpha = CGFloat(parsed & 0xff) / 255
        } else {
            red = CGFloat((parsed >> 16) & 0xff) / 255
            green = CGFloat((parsed >> 8) & 0xff) / 255
            blue = CGFloat(parsed & 0xff) / 255
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension EnvironmentValues {
    @Entry var rafuTheme: RafuTheme = RafuThemeCatalog.indigo
}
