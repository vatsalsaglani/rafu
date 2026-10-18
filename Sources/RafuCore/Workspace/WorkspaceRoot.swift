import Foundation

/// One folder of a workspace. A workspace has one or more roots; the first
/// is the primary root (`WorkspaceSession.rootURL` keeps meaning that one).
///
/// Paths are local file-system paths. A root never holds a remote path.
public struct WorkspaceRoot: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// Standardized absolute path, with no trailing slash.
    public let path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = WorkspaceRootList.normalizedPath(path)
    }

    /// The folder name, or the whole path for `/`.
    public var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }
}

/// A file found in one root of a multi-folder workspace (quick open).
public struct WorkspaceFileMatch: Hashable, Identifiable, Sendable {
    public let rootID: UUID
    /// Path relative to the root, never starting with `/`.
    public let relativePath: String
    /// What the user sees: `relativePath`, or `root/relativePath` when the
    /// workspace has more than one root.
    public let displayPath: String

    public init(rootID: UUID, relativePath: String, displayPath: String) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.displayPath = displayPath
    }

    public var id: String { rootID.uuidString + ":" + relativePath }
}

/// Pure rules for the ordered root list of a workspace. All functions are
/// value-in, value-out, so they are easy to test and safe off the main actor.
public enum WorkspaceRootList {
    /// Upper bound on folders in one workspace. File watchers and indexes
    /// are per root, so the count stays small on purpose.
    public static let maximumRoots = 16

    public enum AddOutcome: Equatable, Sendable {
        case added([WorkspaceRoot])
        /// The folder is already a root (the ID of that root).
        case duplicate(UUID)
        case limitReached
        case invalidPath
    }

    /// Standardizes `path`: resolves `.` and `..`, removes a trailing slash.
    /// Does not touch the file system (no symlink resolution). A relative
    /// path is returned as it is: it is never resolved against the process's
    /// current directory.
    public static func normalizedPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    /// Appends a root for `path` unless it is already present or the list is
    /// full. Order is kept: new roots go to the end.
    public static func adding(
        path: String, id: UUID = UUID(), to roots: [WorkspaceRoot]
    ) -> AddOutcome {
        let normalized = normalizedPath(path)
        guard normalized.hasPrefix("/"), !normalized.contains("\u{0}") else {
            return .invalidPath
        }
        if let existing = roots.first(where: { $0.path == normalized }) {
            return .duplicate(existing.id)
        }
        guard roots.count < maximumRoots else { return .limitReached }
        return .added(roots + [WorkspaceRoot(id: id, path: normalized)])
    }

    /// Removes the root with `id`. The primary (first) root is never removed
    /// here; the caller closes the workspace for that.
    public static func removing(id: UUID, from roots: [WorkspaceRoot]) -> [WorkspaceRoot] {
        guard let index = roots.firstIndex(where: { $0.id == id }), index > 0 else { return roots }
        var result = roots
        result.remove(at: index)
        return result
    }

    /// Moves the root at `primaryIndex` to the front and keeps the order of
    /// the rest. An index out of range keeps the list as it is.
    public static func reordered<Element>(_ items: [Element], primaryIndex: Int?) -> [Element] {
        guard let primaryIndex, items.indices.contains(primaryIndex), primaryIndex > 0 else {
            return items
        }
        var result = items
        let primary = result.remove(at: primaryIndex)
        result.insert(primary, at: 0)
        return result
    }

    /// A short, unique label per root. Folder names are used as they are;
    /// when two roots share a name, the parent folder is added
    /// (`client/app`, `server/app`); when that is still the same, the full
    /// path is used.
    public static func displayNames(for roots: [WorkspaceRoot]) -> [UUID: String] {
        var counts: [String: Int] = [:]
        for root in roots { counts[root.name, default: 0] += 1 }
        var withParent: [UUID: String] = [:]
        var parentCounts: [String: Int] = [:]
        for root in roots where counts[root.name, default: 0] > 1 {
            let parent = ((root.path as NSString).deletingLastPathComponent as NSString)
                .lastPathComponent
            let label = parent.isEmpty || parent == "/" ? root.name : parent + "/" + root.name
            withParent[root.id] = label
            parentCounts[label, default: 0] += 1
        }
        var result: [UUID: String] = [:]
        for root in roots {
            if let label = withParent[root.id] {
                result[root.id] = parentCounts[label, default: 0] > 1 ? root.path : label
            } else {
                result[root.id] = root.name
            }
        }
        return result
    }

    /// The root that contains `absolutePath` and the path relative to it.
    /// When roots nest, the deepest root wins.
    public static func locate(
        absolutePath: String, in roots: [WorkspaceRoot]
    ) -> (root: WorkspaceRoot, relativePath: String)? {
        let target = normalizedPath(absolutePath)
        var best: (root: WorkspaceRoot, relativePath: String)?
        for root in roots {
            let relative: String
            if target == root.path {
                relative = ""
            } else if root.path == "/" {
                relative = String(target.dropFirst())
            } else if target.hasPrefix(root.path + "/") {
                relative = String(target.dropFirst(root.path.count + 1))
            } else {
                continue
            }
            if root.path.count > best?.root.path.count ?? -1 {
                best = (root, relative)
            }
        }
        return best
    }

    /// `relativePath` as the user sees it: unchanged for a one-root
    /// workspace, prefixed with the root label when there are more roots, so
    /// the same relative path in two roots never reads the same.
    public static func displayPath(
        relativePath: String, rootID: UUID, roots: [WorkspaceRoot]
    ) -> String {
        guard roots.count > 1, let label = displayNames(for: roots)[rootID] else {
            return relativePath
        }
        return relativePath.isEmpty ? label : label + "/" + relativePath
    }

    /// Whether `path` or one of its parents holds a `.git` entry (a folder,
    /// or a file for linked worktrees and submodules). A cheap check with no
    /// Git process, used to decide which roots Source Control can show.
    /// `fileExists` is injected for tests; the walk stops at `/`.
    public static func isInsideGitWorkTree(
        path: String, fileExists: (String) -> Bool
    ) -> Bool {
        var current = normalizedPath(path)
        guard current.hasPrefix("/") else { return false }
        for _ in 0..<64 {
            let candidate = current == "/" ? "/.git" : current + "/.git"
            if fileExists(candidate) { return true }
            guard current != "/" else { return false }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
        return false
    }

    /// Merges per-root ranked lists into one list of at most `limit` items,
    /// round robin, so every root gets its best matches near the top.
    public static func interleave<Element>(_ lists: [[Element]], limit: Int) -> [Element] {
        guard limit > 0 else { return [] }
        var result: [Element] = []
        result.reserveCapacity(min(limit, lists.reduce(0) { $0 + $1.count }))
        var index = 0
        var didAppend = true
        while didAppend, result.count < limit {
            didAppend = false
            for list in lists where index < list.count {
                result.append(list[index])
                didAppend = true
                if result.count == limit { break }
            }
            index += 1
        }
        return result
    }
}
