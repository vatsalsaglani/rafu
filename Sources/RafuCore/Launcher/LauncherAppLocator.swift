import Darwin
import Foundation

/// Locates the Rafu.app bundle that encloses the running CLI. The CLI ships
/// at `Rafu.app/Contents/SharedSupport/bin/rafu`, so the bundle root is four
/// path components up from the executable.
public enum LauncherAppLocator {
    /// - Parameter executablePath: Override for tests. In production this is
    ///   `nil`, so the real path of the running executable is used.
    ///
    /// The path is taken from `_NSGetExecutablePath()`, **not**
    /// `CommandLine.arguments.first`: when the CLI is invoked bare through
    /// `PATH` (e.g. `rafu .`), the shell sets `argv[0]` to just the basename
    /// (`"rafu"`), which resolves against the current directory and never
    /// finds the executable. The kernel still exec's the fully-resolved path
    /// even in that case, and that is exactly what `_NSGetExecutablePath()`
    /// reports — including the `~/.local/bin/rafu` symlink the CLI installer
    /// creates, which `resolvingSymlinksInPath()` then follows back into the
    /// enclosing `Rafu.app`.
    public static func enclosingAppBundle(
        executablePath: String? = nil
    ) -> URL? {
        let path = executablePath ?? currentExecutablePath() ?? CommandLine.arguments.first ?? ""
        let resolved = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return appBundle(forCLIExecutable: resolved)
    }

    /// The path used to exec the running process, from `_NSGetExecutablePath()`
    /// (the two-call size-probe form). Returns `nil` only if the probe fails,
    /// in which case `enclosingAppBundle` falls back to `argv[0]`.
    private static func currentExecutablePath() -> String? {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
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
