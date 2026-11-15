import Foundation

// A stopped terminal starts in the folder its shell was last in (ADR 0023,
// "last working folder"). The shell's folder comes from two sources: the
// OSC 7 report a prompt can send, and the shell process's own current
// directory (`TerminalProcessInspecting.currentDirectory(processID:)`). Both
// are reduced here to a workspace-relative folder that is inside the root
// after symlinks resolve. A folder outside the root is never stored, and no
// command is ever stored.

/// Reads an OSC 7 working-directory report. Only a report from this Mac
/// counts: a shell inside `ssh host` sends the remote host name, and that
/// path does not exist here.
nonisolated enum TerminalWorkingDirectoryReport {
    /// The local path in `report`, or `nil` when the report is empty,
    /// malformed, or names another host. A bare absolute path (some shells
    /// send one) is accepted as local.
    static func localPath(_ report: String?, localHostNames: Set<String>) -> String? {
        guard let report, !report.isEmpty else { return nil }
        guard report.hasPrefix("file://") else {
            return report.hasPrefix("/") ? report : nil
        }
        guard let components = URLComponents(string: report) else { return nil }
        let host = (components.host ?? "").lowercased()
        guard host.isEmpty || host == "localhost" || localHostNames.contains(host) else {
            return nil
        }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.hasPrefix("/") ? path : nil
    }

    /// This Mac's names, lowercased: the full host name and its first label
    /// ("mac.local" and "mac"). Shells build the OSC 7 host from
    /// `gethostname`, which reads the kernel name and never does a network
    /// lookup (`ProcessInfo.hostName` can).
    static let currentHostNames: Set<String> = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return [] }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return hostNames(
            String(decoding: buffer.prefix(length).map(UInt8.init(bitPattern:)), as: UTF8.self))
    }()

    static func hostNames(_ hostName: String) -> Set<String> {
        let full = hostName.lowercased()
        guard !full.isEmpty else { return [] }
        var names: Set<String> = [full]
        if let first = full.split(separator: ".").first { names.insert(String(first)) }
        return names
    }
}

/// Converts an absolute folder to a workspace-relative one. Both paths are
/// resolved through symlinks first, so a link inside the workspace that
/// points outside it is refused.
nonisolated enum TerminalWorkspaceFolder {
    /// `path` as a folder relative to `root`, or `nil` when it is not an
    /// existing, readable directory inside `root`. The root itself is `.root`.
    static func relative(path: String, root: URL) -> TerminalWorkspaceRelativePath? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            FileManager.default.isReadableFile(atPath: candidate.path)
        else { return nil }
        let rootPath = resolvedRoot.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let relative = String(candidatePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return TerminalWorkspaceRelativePath(relative)
    }

    /// Whether `folder` below `root` still is a usable directory inside it.
    static func isUsable(_ folder: TerminalWorkspaceRelativePath, root: URL) -> Bool {
        relative(path: root.appending(path: folder.rawValue).path, root: root) != nil
    }

    /// Whether nothing exists at `folder` below `root` any more: no file, no
    /// folder, and no symlink (a symlink is not followed, so a link that now
    /// points outside the workspace is not "gone" and keeps the refusal).
    static func isMissing(_ folder: TerminalWorkspaceRelativePath, root: URL) -> Bool {
        let path = root.appending(path: folder.rawValue).path
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }
}

/// Chooses the folder a stopped ordinary shell starts in.
nonisolated enum TerminalStartFolderResolver {
    /// The last working folder when it is still usable, else the starting
    /// folder when it is usable, else the workspace folder (`.root`) when the
    /// starting folder is gone (`isMissing`) and the root is usable, else
    /// `nil`. The workspace-folder fallback is ADR 0023's 2026-11-15
    /// amendment: a saved folder that is gone no longer blocks a start. A
    /// starting folder that exists but is unusable (a symlink that now points
    /// outside the workspace, a file, an unreadable folder) keeps the refusal.
    /// A remote workspace has no local root, so its callers never reach this
    /// resolver.
    static func resolve(
        _ profile: TerminalPaneLaunchProfile,
        isUsable: (TerminalWorkspaceRelativePath) -> Bool,
        isMissing: (TerminalWorkspaceRelativePath) -> Bool
    ) -> TerminalWorkspaceRelativePath? {
        if let saved = savedFolder(profile, isUsable: isUsable) { return saved }
        return fallsBack(profile, isUsable: isUsable, isMissing: isMissing) ? .root : nil
    }

    /// True when neither saved folder is usable, the starting folder is gone,
    /// and a start falls back to the workspace folder. The stopped-pane and
    /// Ensemble card labels say so.
    static func fallsBackToWorkspaceFolder(
        _ profile: TerminalPaneLaunchProfile,
        isUsable: (TerminalWorkspaceRelativePath) -> Bool,
        isMissing: (TerminalWorkspaceRelativePath) -> Bool
    ) -> Bool {
        savedFolder(profile, isUsable: isUsable) == nil
            && fallsBack(profile, isUsable: isUsable, isMissing: isMissing)
    }

    private static func fallsBack(
        _ profile: TerminalPaneLaunchProfile,
        isUsable: (TerminalWorkspaceRelativePath) -> Bool,
        isMissing: (TerminalWorkspaceRelativePath) -> Bool
    ) -> Bool {
        isMissing(profile.startingFolder) && isUsable(.root)
    }

    /// The last working folder, else the starting folder, when usable.
    private static func savedFolder(
        _ profile: TerminalPaneLaunchProfile,
        isUsable: (TerminalWorkspaceRelativePath) -> Bool
    ) -> TerminalWorkspaceRelativePath? {
        if let last = profile.lastWorkingFolder, isUsable(last) { return last }
        return isUsable(profile.startingFolder) ? profile.startingFolder : nil
    }

    /// The profile restoration keeps: its last working folder is dropped when
    /// it is no longer usable, so the empty state names the folder a start
    /// will use.
    static func revalidated(
        _ profile: TerminalPaneLaunchProfile,
        isUsable: (TerminalWorkspaceRelativePath) -> Bool
    ) -> TerminalPaneLaunchProfile {
        guard let last = profile.lastWorkingFolder else { return profile }
        return isUsable(last) ? profile : profile.withoutLastWorkingFolder
    }

    /// The last working folder to persist for one pane. `observedPath` is the
    /// shell's current folder when this run saw one; it replaces the stored
    /// value, and a folder outside the workspace clears it. With no
    /// observation the stored value stays.
    static func persistedLastFolder(
        stored: TerminalPaneLaunchProfile, observedPath: String?, root: URL?
    ) -> TerminalPaneLaunchProfile {
        guard let observedPath else { return stored }
        guard let root else { return stored.withoutLastWorkingFolder }
        return stored.withLastWorkingFolder(
            TerminalWorkspaceFolder.relative(path: observedPath, root: root))
    }
}
