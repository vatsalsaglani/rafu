import Foundation

/// Finds Rafu's own SwiftPM resource bundle (`Rafu_RafuApp.bundle`).
///
/// Why this exists: the accessor SwiftPM generates for `Bundle.module` depends
/// on the toolchain. Older SwiftPM builds a flat bundle and looks for it only
/// at the `.app` root, where `codesign` cannot seal it: the release bundle
/// then carries an invalid signature, and macOS cannot keep a Keychain
/// "Always Allow" grant for it. Newer SwiftPM looks in `Contents/Resources`.
/// This lookup checks `Contents/Resources` first, then the root, so the
/// packaging script can put the bundle in `Contents/Resources` for every
/// toolchain. `Bundle.module` stays only as the last fallback (for
/// `swift test` and `swift run`), because the old accessor traps when it
/// cannot find the bundle. See `docs/references/build-and-run.md`.
nonisolated enum RafuResourceBundleLocator {
    static let bundleName = "Rafu_RafuApp.bundle"

    /// The first `bundleName` directory found under `directories`, in order.
    static func locate(
        in directories: [URL?], fileManager: FileManager = .default
    ) -> URL? {
        for directory in directories {
            guard
                let candidate = directory?.appendingPathComponent(
                    bundleName, isDirectory: true)
            else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
        }
        return nil
    }
}

extension Bundle {
    /// Rafu's own resource bundle. Use this instead of `Bundle.module` so a
    /// packaged app finds the bundle in `Contents/Resources`.
    static let rafuResources: Bundle = {
        let found = RafuResourceBundleLocator.locate(
            in: [Bundle.main.resourceURL, Bundle.main.bundleURL])
        if let found, let bundle = Bundle(url: found) {
            return bundle
        }
        return Bundle.module
    }()
}
