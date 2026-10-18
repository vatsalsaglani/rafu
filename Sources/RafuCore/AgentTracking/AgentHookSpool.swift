import Foundation

/// Where agent tracking keeps its files, below the app identity's own
/// Application Support folder (`RafuAppIdentity.applicationSupportRoot`):
///
/// - `AgentTracking/spool/`: one JSON file per hook event (0700 directory,
///   0600 files). The helper writes; the app reads and deletes.
/// - `AgentTracking/bin/rafu-agent-events`: the hook helper copied out of the
///   app bundle on Connect, so hook commands survive an app move or update.
public struct AgentTrackingPaths: Equatable, Sendable {
    public static let helperName = "rafu-agent-events"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(
        identity: RafuAppIdentity,
        baseDirectory: URL = RafuAppIdentity.defaultApplicationSupportBaseDirectory
    ) {
        root = identity.applicationSupportRoot(baseDirectory: baseDirectory)
            .appending(path: "AgentTracking", directoryHint: .isDirectory)
    }

    public var spool: URL { root.appending(path: "spool", directoryHint: .isDirectory) }

    public var helper: URL {
        root.appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: Self.helperName, directoryHint: .notDirectory)
    }

    /// The helper accepts only a spool argument of this shape, so a mistyped
    /// hook command cannot make it write somewhere else.
    public static func isSpoolDirectory(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return url.path.hasPrefix("/") && components.count >= 3
            && components.suffix(2) == ["AgentTracking", "spool"]
    }
}

public enum AgentHookSpoolError: Error, Equatable, Sendable {
    case symlinkedDirectory
    case spoolFull
    case eventTooLarge
}

/// The spool file format and its bounds. The helper calls `write`; the app
/// calls `drain`. Both sides use only file-system calls, so both are tested on
/// any platform.
public enum AgentHookSpool {
    /// The largest spool file, in bytes.
    public static let maximumFileBytes = 8_192
    /// The helper stops writing when the spool holds this many files (the app
    /// is not running or not draining).
    public static let maximumFiles = 2_048
    /// At most this many files are read per drain, oldest first.
    public static let drainLimit = 256

    /// Writes `event` as `<id>.json` (0600) into `directory` (0700). The file
    /// is created under a hidden temporary name and renamed into place, so
    /// the app never reads a partial file.
    public static func write(_ event: AgentHookEvent, to directory: URL) throws {
        let fileManager = FileManager.default
        try requireRealDirectoryPath(directory)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard try fileManager.contentsOfDirectory(atPath: directory.path).count < maximumFiles
        else { throw AgentHookSpoolError.spoolFull }
        let data = try JSONEncoder().encode(event)
        guard data.count <= maximumFileBytes else { throw AgentHookSpoolError.eventTooLarge }
        let name = event.id.uuidString + ".json"
        let temporary = directory.appending(path: "." + name + ".tmp")
        guard
            fileManager.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            try fileManager.moveItem(at: temporary, to: directory.appending(path: name))
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Reads at most `limit` spool files, oldest first by modification date,
    /// and deletes each file it read, valid or not. Returns the valid events
    /// sorted by event time. A missing spool gives an empty result.
    public static func drain(directory: URL, limit: Int = drainLimit) throws -> [AgentHookEvent] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        try requireRealDirectoryPath(directory)
        let keys: [URLResourceKey] = [
            .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let candidates = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { url in (url, try? url.resourceValues(forKeys: Set(keys))) }
        .sorted { lhs, rhs in
            let left = lhs.1?.contentModificationDate ?? .distantPast
            let right = rhs.1?.contentModificationDate ?? .distantPast
            return left == right
                ? lhs.0.lastPathComponent < rhs.0.lastPathComponent : left < right
        }
        .prefix(max(0, limit))
        var events: [AgentHookEvent] = []
        let decoder = JSONDecoder()
        for (url, values) in candidates {
            defer { try? fileManager.removeItem(at: url) }
            guard values?.isSymbolicLink != true, values?.isRegularFile == true,
                (values?.fileSize ?? Int.max) <= maximumFileBytes,
                let data = try? Data(contentsOf: url),
                let event = try? decoder.decode(AgentHookEvent.self, from: data),
                event.schemaVersion == AgentHookEvent.currentSchemaVersion
            else { continue }
            events.append(event)
        }
        return events.sorted { lhs, rhs in
            lhs.time == rhs.time ? lhs.id.uuidString < rhs.id.uuidString : lhs.time < rhs.time
        }
    }

    /// Refuses a spool (or its `AgentTracking` parent) that is a symbolic
    /// link. Only these two components are checked: system paths such as
    /// `/var` on macOS are links themselves.
    static func requireRealDirectoryPath(_ directory: URL) throws {
        if AgentTrackingFileCheck.isSymbolicLink(directory)
            || AgentTrackingFileCheck.isSymbolicLink(directory.deletingLastPathComponent())
        {
            throw AgentHookSpoolError.symlinkedDirectory
        }
    }
}

/// `lstat`-style checks that never follow the final link.
enum AgentTrackingFileCheck {
    static func isSymbolicLink(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
