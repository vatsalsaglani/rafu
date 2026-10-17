import Foundation
import Testing

@testable import RafuApp

// Source checks below enforce construction policy. They do not prove UI behavior.
@Suite("Responsive navigation source policy")
struct ResponsiveNavigationPresentationTests {
    @Test("Compact category navigation is in the page column before its header")
    func compactHierarchyContract() throws {
        let source = try Self.source("Sources/RafuApp/Settings/RafuSettingsView.swift")
        let identityStart = try #require(source.range(of: "private func pageIdentity"))
        let paneHostStart = try #require(source.range(of: "private var paneContent"))
        let identity = String(source[identityStart.lowerBound..<paneHostStart.lowerBound])
        let navigation = try #require(
            identity.range(of: "SettingsPaneNavigation(selection: $pane, variant: .compact)")
        )
        let header = try #require(identity.range(of: "SettingsPageHeader(pane: pane)"))

        #expect(source.contains("pageColumn(isCompact: isCompact)"))
        #expect(identity.contains("if isCompact {"))
        #expect(navigation.lowerBound < header.lowerBound)
        #expect(identity.contains("spacing: SettingsPresentationLayout.navigationPageGap"))
    }

    @Test("Compact disclosure keeps category order and collapses on selection or Escape")
    func compactDisclosureSelectionAndEscapeContract() throws {
        let source = try Self.source("Sources/RafuApp/Settings/SettingsPaneNavigation.swift")

        #expect(
            SettingsPane.allCases == [
                .general, .appearance, .ai, .languageServers, .usage, .agents, .ensemble,
            ])
        #expect(source.contains("case .compact:"))
        #expect(source.contains("@State private var isCompactNavigationExpanded = false"))
        #expect(source.contains("Button(action: toggleCompactNavigation)"))
        #expect(source.contains("if isCompactNavigationExpanded"))
        #expect(source.contains("ForEach(SettingsPane.allCases)"))
        #expect(source.contains("select: { selectCompactPane(pane) }"))
        #expect(source.contains("selection = pane\n        isCompactNavigationExpanded = false"))
        #expect(source.contains(".onExitCommand(perform: collapseCompactNavigation)"))
        #expect(source.contains("private func collapseCompactNavigation()"))
        #expect(source.contains("isCompactNavigationExpanded = false"))
        #expect(source.contains(".onChange(of: variant)"))
        #expect(source.contains("if newVariant == .regular"))
    }

    @Test("Compact navigation uses themed full-width controls with a vertical text escape path")
    func compactAccessibilityAndThemeContract() throws {
        let source = try Self.source("Sources/RafuApp/Settings/SettingsPaneNavigation.swift")
        let settings = try Self.source("Sources/RafuApp/Settings/RafuSettingsView.swift")

        #expect(
            source.components(separatedBy: ".fixedSize(horizontal: false, vertical: true)").count
                - 1
                >= 2
        )
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(source.contains(".accessibilityLabel(\"Settings category\")"))
        #expect(source.contains(".accessibilityValue(selection.title)"))
        #expect(source.contains(".accessibilityAddTraits(.isSelected)"))
        #expect(source.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"))
        #expect(source.contains("theme.palette.tabBarBackground"))
        #expect(source.contains("theme.palette.accentSoft"))
        #expect(!source.contains("ScrollView(.horizontal)"))
        #expect(!source.contains("Menu {"))
        #expect(!source.contains(".popover("))
        #expect(settings.contains(".rafuTheme(activeTheme)"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ResponsiveNavigationPresentationTestError.repositoryRootNotFound
    }

    private enum ResponsiveNavigationPresentationTestError: Error {
        case repositoryRootNotFound
    }
}
