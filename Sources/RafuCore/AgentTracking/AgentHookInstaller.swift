import Foundation

/// The file-system half of hook setup. Blocking: call it off the main actor.
///
/// - `prepare` reads the provider file and plans the change; it writes
///   nothing.
/// - `apply` writes only if the file is byte-for-byte what was reviewed. It
///   copies the bundled helper to its stable path (Connect only), keeps a
///   timestamped backup of the old file, and writes the new file through a
///   temporary file and a rename.
public enum AgentHookInstaller {
    /// Reads the provider's configuration and plans the change.
    public static func prepare(
        provider: AgentHookProvider,
        destination: URL,
        paths: AgentTrackingPaths,
        removing: Bool
    ) throws -> AgentHookChange {
        try AgentHookConfiguration.plan(
            provider: provider,
            destination: destination,
            existing: try readConfiguration(at: destination),
            helper: paths.helper,
            spool: paths.spool,
            removing: removing)
    }

    /// Whether the provider file has Rafu's entries. `false` when unreadable.
    public static func isConnected(
        provider: AgentHookProvider, destination: URL, paths: AgentTrackingPaths
    ) -> Bool {
        AgentHookConfiguration.isConnected(
            provider: provider,
            existing: try? readConfiguration(at: destination),
            helper: paths.helper)
    }

    /// Applies a reviewed change. Returns the backup URL, if one was made.
    @discardableResult
    public static func apply(
        _ change: AgentHookChange,
        paths: AgentTrackingPaths,
        bundledHelper: URL?,
        now: Date = Date()
    ) throws -> URL? {
        let fileManager = FileManager.default
        let current = try readConfiguration(at: change.destination)
        guard current == change.before else {
            throw AgentHookConfigurationError.changedSinceReview
        }
        if !change.removing {
            try stageHelper(from: bundledHelper, paths: paths)
            try AgentHookSpool.requireRealDirectoryPath(paths.spool)
            try fileManager.createDirectory(
                at: paths.spool, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        guard !change.isNoOp else { return nil }
        let folder = change.destination.deletingLastPathComponent()
        try requireNoSymlink(folder)
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var permissions = 0o600
        var backup: URL?
        if let before = change.before {
            let attributes = try? fileManager.attributesOfItem(atPath: change.destination.path)
            if let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue {
                permissions = mode & 0o777
            }
            let target = backupURL(for: change.destination, at: now)
            try writeNew(before, to: target, permissions: 0o600)
            backup = target
        }
        try writeReplacing(change.after, to: change.destination, permissions: permissions)
        return backup
    }

    /// `settings.json.rafu-backup-20261018-153000`, made unique if needed.
    public static func backupURL(for destination: URL, at date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String {
            let number = value ?? 0
            return number < 10 ? "0\(number)" : "\(number)"
        }
        let stamp =
            "\(parts.year ?? 0)\(two(parts.month))\(two(parts.day))-"
            + "\(two(parts.hour))\(two(parts.minute))\(two(parts.second))"
        let base = destination.lastPathComponent + ".rafu-backup-" + stamp
        let folder = destination.deletingLastPathComponent()
        var candidate = folder.appending(path: base)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = folder.appending(path: base + "-\(counter)")
        }
        return candidate
    }

    /// The configuration bytes, or `nil` when the file does not exist.
    /// Refuses a symbolic link and a file over the size bound.
    static func readConfiguration(at url: URL) throws -> Data? {
        let fileManager = FileManager.default
        try requireNoSymlink(url.deletingLastPathComponent())
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw AgentHookConfigurationError.symlinkedConfiguration
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw AgentHookConfigurationError.unexpectedStructure
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= AgentHookConfiguration.maximumConfigurationBytes else {
            throw AgentHookConfigurationError.configurationTooLarge
        }
        return try Data(contentsOf: url)
    }

    /// Copies the bundled helper to `paths.helper` (0700 file in a 0700
    /// folder). Refuses a symbolic link at the target.
    static func stageHelper(from bundledHelper: URL?, paths: AgentTrackingPaths) throws {
        let fileManager = FileManager.default
        guard let bundledHelper, fileManager.isExecutableFile(atPath: bundledHelper.path) else {
            throw AgentHookConfigurationError.helperMissing
        }
        let folder = paths.helper.deletingLastPathComponent()
        try requireNoSymlink(paths.root)
        try requireNoSymlink(folder)
        try requireNoSymlink(paths.helper)
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeReplacing(
            try Data(contentsOf: bundledHelper), to: paths.helper, permissions: 0o700)
    }

    /// Writes through a hidden temporary file in the same folder, then
    /// renames it over `url`, so readers see the old or the new file only.
    static func writeReplacing(_ data: Data, to url: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appending(path: "." + url.lastPathComponent + ".rafu-" + UUID().uuidString)
        guard
            fileManager.createFile(
                atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: permissions])
        else { throw CocoaError(.fileWriteUnknown) }
        // POSIX rename replaces the target atomically; a helper that is
        // running from the old file keeps its inode.
        guard rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func writeNew(_ data: Data, to url: URL, permissions: Int) throws {
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: data, attributes: [.posixPermissions: permissions])
        else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Refuses `url` when it is a symbolic link (not followed).
    private static func requireNoSymlink(_ url: URL) throws {
        if AgentTrackingFileCheck.isSymbolicLink(url) {
            throw AgentHookConfigurationError.symlinkedConfiguration
        }
    }
}
