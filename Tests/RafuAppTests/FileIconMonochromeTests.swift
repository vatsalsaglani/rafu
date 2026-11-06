import Foundation
import Testing

@testable import RafuApp

/// UX Round C, F1: file icons are monochrome at rest.
@Suite("Monochrome file icons")
@MainActor
struct FileIconMonochromeTests {
    private let swift = FileIconProvider.fileIcon(named: "main.swift")

    @Test("Rest is textSecondary, a selected row is textPrimary")
    func monochromeTint() {
        #expect(swift.tint != .secondary)
        #expect(FileIconMonochrome.tint(swift, coloured: false, isSelected: false) == .secondary)
        #expect(FileIconMonochrome.tint(swift, coloured: false, isSelected: true) == .primary)
        let muted = FileIconProvider.fileIcon(named: ".env")
        #expect(FileIconMonochrome.tint(muted, coloured: false, isSelected: false) == .secondary)
    }

    @Test("The Coloured file icons preference keeps the icon's own tint")
    func colouredTint() {
        #expect(FileIconMonochrome.tint(swift, coloured: true, isSelected: false) == swift.tint)
        #expect(FileIconMonochrome.tint(swift, coloured: true, isSelected: true) == swift.tint)
    }

    @Test("A coloured asset draws as a template only in monochrome mode")
    func assetTemplateRule() {
        let claude = FileIconProvider.directoryIcon(named: ".claude")
        #expect(claude.assetName != nil && !claude.assetIsTemplate)
        #expect(FileIconMonochrome.drawsAssetAsTemplate(claude, coloured: false))
        #expect(!FileIconMonochrome.drawsAssetAsTemplate(claude, coloured: true))
        let codex = FileIconProvider.directoryIcon(named: ".codex")
        #expect(codex.assetIsTemplate)
        #expect(FileIconMonochrome.drawsAssetAsTemplate(codex, coloured: true))
        #expect(FileIconMonochrome.drawsAssetAsTemplate(codex, coloured: false))
    }

    @Test("The preference key, the Settings toggle and the window root agree")
    func preferenceWiring() throws {
        #expect(FileIconProvider.colouredFileIconsKey == "colouredFileIcons")
        let settings = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Settings/RafuSettingsView.swift")
        #expect(settings.contains("Toggle(\"Coloured file icons\", isOn: $colouredFileIcons)"))
        let window = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Views/WorkspaceWindowView.swift")
        #expect(window.contains(".environment(\\.rafuColouredFileIcons, colouredFileIcons)"))
        let sidebar = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        #expect(sidebar.contains("FileIconView(icon: icon, size: 12, isSelected: isSelected)"))
        // Agent identity marks keep their colour.
        let agent = try CanvasBoardKeyMapTests.source("Sources/RafuApp/Support/AgentIdentity.swift")
        #expect(agent.contains("isAgentMark: true"))
    }
}
