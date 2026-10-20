import Foundation

/// Throwaway `UserDefaults` suites for tests.
///
/// `name(_:)` returns an absolute path inside a fresh temporary directory.
/// CFPreferences keeps a path-named suite in a plist at that path, so a test
/// suite never lands in `~/Library/Preferences`. A plain `"dev.rafu.x.<UUID>"`
/// name always leaks a plist there: `removePersistentDomain(forName:)` only
/// empties the domain and cfprefsd still writes an empty plist back later, a
/// save that lands after teardown (a debounced workspace save) writes it back
/// with data, and deleting the file from the test process does not stick.
/// See `docs/references/test-defaults-suites.md`.
enum TestDefaultsSuite {
    private static let directoryPrefix = "rafu-test-defaults-"

    /// A new suite name. `label` only names the plist, for diagnostics.
    static func name(_ label: String) -> String {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: directoryPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: label).path
    }

    /// Empties the suite and removes its temporary directory. Call it in a
    /// `defer`. A name that `name(_:)` did not make is only emptied: nothing
    /// outside its own temporary directory is ever deleted.
    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        guard let directory = ownedDirectory(of: name) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The temporary directory `name(_:)` made for `name`, or nil.
    static func ownedDirectory(of name: String) -> URL? {
        guard name.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: name).deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard directory.lastPathComponent.hasPrefix(directoryPrefix),
            directory.deletingLastPathComponent().standardizedFileURL.path == temporary
        else { return nil }
        return directory
    }
}
