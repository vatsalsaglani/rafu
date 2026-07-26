import Foundation
import Testing

@testable import RafuApp

/// Rafu ships its own `RafuSegmentedPicker` and `RafuProminentButtonStyle`,
/// so AppKit's segmented picker and bordered-prominent button — both painted
/// with the *system* accent, not the active theme's — are defects wherever
/// they appear in Rafu's own chrome. A rendered-view assertion cannot see a
/// style modifier, so the honest guard is a source scan: it is the one that
/// keeps the fix from eroding as new views land.
///
/// Two later leaks widened the list, both found by dogfooding rather than by
/// the original scan, because neither is a control *style*:
///
/// - `TabView` — its macOS bar paints the selected tab with the system
///   accent and ignores `.tint`, exactly as `Picker(.segmented)` does.
///   Settings now draws `SettingsPaneStrip` instead.
/// - Stock SwiftUI controls Rafu does not hand-draw (`Toggle`'s switch,
///   determinate `ProgressView`, `Slider`, `Stepper`, `ColorPicker`, text
///   selection). Scanning for `Toggle(` is hopeless — dozens of legitimate
///   call sites, and correctness is not a property of the line the control
///   is written on. What *is* scannable is the single place that decides
///   their color: a theme root. `View.rafuTheme(_:)` sets `\.rafuTheme` and
///   `.tint` together, so banning every other `.environment(\.rafuTheme, …)`
///   guarantees no window, HUD or scene can install a theme while leaving
///   the stock controls system-blue.
///
/// `accentColor` is banned too, as of the UI-01/UI-03 integration. Its last
/// use seeded the custom terminal-tab `ColorPicker`, which reads as a data
/// value rather than chrome — but the swatch the picker opens on is the one
/// piece of Rafu the user sees before choosing, so a system-blue seed is the
/// same leak by another route. It now falls back to the theme accent.
@Suite("Themed control styles")
struct ThemedControlStyleScanTests {
    @Test("No system-accent control styles remain under Sources/RafuApp")
    func noSystemAccentControlStyles() throws {
        let root = try Self.repositoryRoot().appending(
            path: "Sources/RafuApp", directoryHint: .isDirectory)
        let banned = [
            "pickerStyle(.segmented)",
            ".borderedProminent",
            "TabView",
            #"environment(\.rafuTheme"#,
            "accentColor",
        ]

        var offenders: [String] = []
        for file in try Self.swiftFiles(under: root) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                // The scan is the guard's subject; its own literals must not
                // trip it, and neither may prose explaining the rule.
                guard !line.contains("themed-control-scan:allow") else { continue }
                for needle in banned where line.contains(needle) {
                    offenders.append(
                        "\(file.lastPathComponent):\(index + 1) — \(needle)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Use RafuSegmentedPicker / RafuProminentButtonStyle / \
            SettingsPaneStrip, and install themes with View.rafuTheme(_:) so \
            stock controls inherit the theme tint: \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    /// The pane bar is hand-drawn now, so "all seven panes are reachable" is
    /// no longer guaranteed by seven `Tab` literals the compiler sees. This
    /// is the behavioral half of the guard the scan cannot express.
    @Test("Settings still exposes all seven panes, each labelled and glyphed")
    func settingsPanesAreComplete() {
        #expect(
            SettingsPane.allCases == [
                .general, .appearance, .ai, .languageServers, .usage, .agents, .ensemble,
            ])
        #expect(
            SettingsPane.allCases.map(\.title) == [
                "General", "Appearance", "AI", "Language Servers", "Usage", "Agents", "Ensemble",
            ])
        // An empty glyph name renders a blank pill: legible only by label,
        // and invisible in the bar's icon-over-label anatomy.
        #expect(SettingsPane.allCases.allSatisfy { !$0.systemImage.isEmpty })
        #expect(Set(SettingsPane.allCases.map(\.systemImage)).count == SettingsPane.allCases.count)
    }

    /// Walks up from this test's own location to the directory holding
    /// `Package.swift`. Test bundles have no reliable pointer back to the
    /// checkout, and hardcoding a relative depth breaks the moment the file
    /// moves between test subdirectories.
    private static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ScanError.repositoryRootNotFound
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            throw ScanError.notEnumerable(root.path)
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private enum ScanError: Error {
        case repositoryRootNotFound
        case notEnumerable(String)
    }
}
