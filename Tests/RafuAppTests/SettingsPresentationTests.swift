import Foundation
import Testing

@testable import RafuApp

@Suite("Settings presentation")
struct SettingsPresentationTests {
    @Test("All Settings panes keep a title, subtitle, and unique glyph")
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
        #expect(SettingsPane.allCases.allSatisfy { !$0.subtitle.isEmpty })
        #expect(SettingsPane.allCases.allSatisfy { !$0.systemImage.isEmpty })
        #expect(Set(SettingsPane.allCases.map(\.systemImage)).count == SettingsPane.allCases.count)
    }

    @Test("Settings navigation switches only from available canvas width")
    func compactNavigationBreakpoint() {
        #expect(SettingsPresentationLayout.usesCompactNavigation(forAvailableCanvasWidth: 811))
        #expect(SettingsPresentationLayout.usesCompactNavigation(forAvailableCanvasWidth: 811.9))
        #expect(!SettingsPresentationLayout.usesCompactNavigation(forAvailableCanvasWidth: 812))
        #expect(!SettingsPresentationLayout.usesCompactNavigation(forAvailableCanvasWidth: 832))
        #expect(!SettingsPresentationLayout.usesCompactNavigation(forAvailableCanvasWidth: 1_440))
        #expect(SettingsPresentationLayout.navigationBreakpoint == 812)
    }

    @Test("Settings page measure preserves the compact desktop hierarchy")
    func pageMeasure() {
        #expect(SettingsPresentationLayout.regularNavigationWidth == 188)
        #expect(SettingsPresentationLayout.navigationPageGap == 16)
        #expect(SettingsPresentationLayout.pageMaximumWidth == 840)
        #expect(SettingsPresentationLayout.outerPadding == 24)
        #expect(SettingsPresentationLayout.regularCombinedMaximumWidth == 1_092)
    }

    // This is a source policy check. Runtime retention and initialization counts
    // require a mounted Settings view and resize/selection events.
    @Test("Source policy keeps one lazy pane host outside navigation variants")
    func retainedPaneHostSourcePolicy() throws {
        let source = try Self.source("Sources/RafuApp/Settings/RafuSettingsView.swift")
        #expect(source.components(separatedBy: "private var paneContent: some View").count - 1 == 1)
        #expect(source.components(separatedBy: "ZStack {").count - 1 == 1)
        #expect(source.contains("@State private var visitedPanes: Set<SettingsPane> = [.general]"))
        #expect(source.contains("visitedPanes.insert(newPane)"))
        #expect(source.contains("ForEach(SettingsPane.allCases.filter(visitedPanes.contains))"))
        #expect(!source.contains("ForEach(SettingsPane.allCases) { candidate in"))
        #expect(source.contains(".opacity(candidate == pane ? 1 : 0)"))
        #expect(source.contains(".disabled(candidate != pane)"))
        #expect(source.contains(".accessibilityHidden(candidate != pane)"))

        let pageColumnStart = try #require(source.range(of: "private func pageColumn"))
        let pageIdentityStart = try #require(source.range(of: "private func pageIdentity"))
        let pageColumn = String(source[pageColumnStart.lowerBound..<pageIdentityStart.lowerBound])
        #expect(pageColumn.contains("pageIdentity(isCompact: isCompact)"))
        #expect(pageColumn.contains("paneContent"))
        #expect(!pageColumn.contains("if isCompact"))
    }

    @Test("Settings page groups use the shared accessible section container")
    func settingsGroupsUseSharedSectionContainer() throws {
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
            #expect(
                try Self.source(path).contains("RafuSettingsSection"),
                Comment(rawValue: path)
            )
        }

        let styles = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        #expect(styles.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(styles.contains(".accessibilityElement(children: .contain)"))
        #expect(styles.contains("minHeight: RafuMetrics.settingsRowMinHeight"))
    }

    @Test("Editor-hosted Settings keeps the attached tab construction")
    func settingsCanvasUsesAttachedTab() throws {
        let source = try Self.source("Sources/RafuApp/Settings/SettingsCanvas.swift")
        #expect(source.contains("AttachedWorkbenchTab(isSelected: true)"))
        #expect(source.contains("AttachedWorkbenchTabCloseButton"))
        #expect(source.contains("action: session.closeSettings"))
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
