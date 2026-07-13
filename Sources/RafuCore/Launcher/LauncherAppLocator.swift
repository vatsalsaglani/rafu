import Foundation

/// Locates the Rafu.app bundle that encloses the running CLI. The CLI ships
/// at `Rafu.app/Contents/SharedSupport/bin/rafu`, so the bundle root is four
/// path components up from the executable.
public enum LauncherAppLocator {
    public static func enclosingAppBundle(
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> URL? {
        let resolved = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return appBundle(forCLIExecutable: resolved)
    }

    /// Pure path math, testable without a real bundle on disk when
    /// `requireOnDisk` is false.
    public static func appBundle(
        forCLIExecutable executable: URL,
        requireOnDisk: Bool = true
    ) -> URL? {
        let components = executable.pathComponents
        guard components.count >= 5 else { return nil }
        let tail = components.suffix(4).dropLast()
        guard Array(tail) == ["Contents", "SharedSupport", "bin"] else { return nil }
        let bundle =
            executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return nil }
        if requireOnDisk {
            let marker = bundle.appending(path: "Contents/MacOS")
            guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        }
        return bundle
    }
}
