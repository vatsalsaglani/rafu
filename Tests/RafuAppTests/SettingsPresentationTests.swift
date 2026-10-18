import Foundation
import Testing

@testable import RafuApp

@Suite("Settings presentation")
struct SettingsPresentationTests {
    @Test("All Settings panes keep a title and a unique glyph")
    func paneMetadataIsComplete() {
        #expect(
            SettingsPane.allCases == [
                .general, .appearance, .ai, .languageServers, .usage, .agents, .ensemble,
            ])
        #expect(
            SettingsPane.allCases.map(\.title) == [
                "General", "Appearance", "AI", "Language Servers", "Usage", "Agents", "Ensemble",
            ])
        #expect(SettingsPane.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(SettingsPane.allCases.allSatisfy { !$0.systemImage.isEmpty })
        #expect(Set(SettingsPane.allCases.map(\.systemImage)).count == SettingsPane.allCases.count)
    }

    @Test("The Settings window is 680 points wide and popups never shrink below 140")
    func windowMeasure() {
        #expect(SettingsPresentationLayout.windowWidth == 680)
        #expect(SettingsPresentationLayout.minimumPopupWidth == 140)
        #expect(
            SettingsPresentationLayout.minimumPaneHeight
                <= SettingsPresentationLayout.idealPaneHeight)
        #expect(
            SettingsPresentationLayout.idealPaneHeight
                <= SettingsPresentationLayout.maximumPaneHeight)
    }

    // This is a source policy check. Runtime retention and initialization counts
    // require a mounted Settings view and tab selection events.
    @Test("Source policy hosts the panes as native toolbar tabs, built on first visit")
    func toolbarPaneHostSourcePolicy() throws {
        let source = try Self.source("Sources/RafuApp/Settings/RafuSettingsView.swift")
        #expect(source.contains("TabView(selection: $pane)"))
        #expect(source.contains("ForEach(SettingsPane.allCases)"))
        #expect(source.contains("Label(candidate.title, systemImage: candidate.systemImage)"))
        #expect(source.contains(".tabItem"))
        #expect(source.contains(".formStyle(.grouped)"))
        #expect(source.contains("@State private var visitedPanes: Set<SettingsPane> = [.general]"))
        #expect(source.contains("visitedPanes.insert(newPane)"))
        #expect(source.contains("visitedPanes.contains(candidate)"))
        #expect(!source.contains("ZStack {"))
    }

    @MainActor
    @Test("General offers the Canvas haptics toggle bound to the shared defaults key")
    func canvasHapticsToggle() throws {
        let source = try Self.source("Sources/RafuApp/Settings/RafuSettingsView.swift")
        #expect(source.contains("@AppStorage(RafuHaptics.canvasHapticsDefaultsKey)"))
        #expect(source.contains("Toggle(\"Haptic feedback on the Canvas\""))
        #expect(source.contains("Plays only on Force Touch trackpads."))
        #expect(RafuHaptics.canvasHapticsDefaultsKey == "canvasHapticsEnabled")
    }

    @Test("Settings panes are grouped forms, not the old custom section container")
    func panesUseGroupedFormContent() throws {
        let paths = [
            "Sources/RafuApp/Settings/RafuSettingsView.swift",
            "Sources/RafuApp/Settings/ThemeSettingsSection.swift",
            "Sources/RafuApp/Settings/AIThemeGeneratorSection.swift",
            "Sources/RafuApp/Settings/ConductorSettingsTab.swift",
            "Sources/RafuApp/Settings/EnsembleSettingsTab.swift",
            "Sources/RafuApp/Settings/LanguageServersSettingsSection.swift",
            "Sources/RafuApp/Settings/UsageSettingsTab.swift",
            "Sources/RafuApp/AI/AIProviderSettingsSection.swift",
        ]
        for path in paths {
            let source = try Self.source(path)
            #expect(!source.contains("RafuSettingsSection"), Comment(rawValue: path))
            #expect(!source.contains("RafuSettingsRow"), Comment(rawValue: path))
        }
    }

    @Test("Settings opens only the standard Settings window")
    func settingsOpensOnlyTheSettingsScene() throws {
        let commands = try Self.source("Sources/RafuApp/App/RafuAppCommands.swift")
        #expect(commands.contains("openSettings()"))
        #expect(!commands.contains("showSettings"))
        #expect(!commands.contains("SettingsCommandRouter"))

        let statusBar = try Self.source("Sources/RafuApp/Views/WorkspaceStatusBar.swift")
        #expect(statusBar.contains("openSettings()"))
        #expect(!statusBar.contains("showSettings"))

        let app = try Self.source("Sources/RafuApp/App/RafuApp.swift")
        #expect(app.contains("Settings {"))
        #expect(app.contains("RafuSettingsView()"))

        let canvas = try Self.source("Sources/RafuApp/Settings/SettingsCanvas.swift")
        #expect(!canvas.contains("RafuSettingsView()"))
        #expect(canvas.contains("openSettings()"))
        #expect(canvas.contains("session.closeSettings()"))
    }

    @Test("Settings headers are title case and the old icon-only theme buttons are gone")
    func labelsAreWordsInTitleCase() throws {
        let theme = try Self.source("Sources/RafuApp/Settings/ThemeSettingsSection.swift")
        for label in ["Duplicate…", "Import…", "Reload Themes", "Show Theme Folder"] {
            #expect(theme.contains("Button(\"\(label)\""), Comment(rawValue: label))
        }
        #expect(!theme.contains(".labelStyle(.iconOnly)"))
        #expect(theme.contains("Follow System Appearance"))
        #expect(theme.contains("Light appearance"))
        #expect(theme.contains("Dark appearance"))

        let servers = try Self.source(
            "Sources/RafuApp/Settings/LanguageServersSettingsSection.swift")
        #expect(servers.contains(".help(\"Refresh\")"))
        #expect(servers.contains("Table(rows)"))

        let ensemble = try Self.source("Sources/RafuApp/Settings/EnsembleSettingsTab.swift")
        #expect(!ensemble.contains("Verb version"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SettingsPresentationTestError.repositoryRootNotFound
    }

    private enum SettingsPresentationTestError: Error {
        case repositoryRootNotFound
    }
}
