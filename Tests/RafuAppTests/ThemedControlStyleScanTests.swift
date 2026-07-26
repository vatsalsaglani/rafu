import Foundation
import Testing

/// Rafu ships its own `RafuSegmentedPicker` and `RafuProminentButtonStyle`,
/// so AppKit's segmented picker and bordered-prominent button — both painted
/// with the *system* accent, not the active theme's — are defects wherever
/// they appear in Rafu's own chrome. A rendered-view assertion cannot see a
/// style modifier, so the honest guard is a source scan: it is the one that
/// keeps the fix from eroding as new views land.
@Suite("Themed control styles")
struct ThemedControlStyleScanTests {
    @Test("No system-accent control styles remain under Sources/RafuApp")
    func noSystemAccentControlStyles() throws {
        let root = try Self.repositoryRoot().appending(
            path: "Sources/RafuApp", directoryHint: .isDirectory)
        let banned = ["pickerStyle(.segmented)", ".borderedProminent"]

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
            Use RafuSegmentedPicker / RafuProminentButtonStyle instead of the \
            system-accent styles: \(offenders.joined(separator: ", "))
            """
        )
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
