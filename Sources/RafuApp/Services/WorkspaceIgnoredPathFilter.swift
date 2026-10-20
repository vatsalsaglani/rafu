import Foundation
import RafuCore

/// Drops FSEvents paths that Git ignores before they start a Git status, a
/// `git ls-files` index rebuild, and a symbol update.
///
/// A tool that writes into an ignored folder (`.venv`, `.next`, `tmp`, logs,
/// test caches) used to refresh all three on every debounced batch, which
/// keeps the CPU busy while the editor is idle. The filter asks Git with one
/// `git check-ignore --stdin -z` for each repository in the batch, off the
/// main actor. It remembers the answer, so later writes into the same place
/// start no process at all:
///
/// - An ignored path is remembered as is.
/// - An ignored folder covers every path inside it, but only after one
///   `git ls-files` shows that the folder holds no tracked file. Git cannot
///   re-include a path under an excluded folder, but a tracked file in it
///   is not ignored.
///
/// The memory restarts when the index, HEAD, or a ref changes, when a
/// `.gitignore` or `info/exclude` changes, and when the watcher stops.
/// Every bound fails open: when the batch is too large or Git fails, no path
/// is dropped, and the workspace refreshes as before.
nonisolated struct WorkspaceIgnoredPathFilter: Sendable {
    /// Above this many paths to ask about, the batch is not filtered.
    static let maximumQueryPaths = 8_192
    /// The remembered paths and folders are cleared above this size.
    static let maximumRememberedEntries = 1_024
    /// At most this many new folders are checked for tracked files at once.
    static let maximumNewDirectoriesPerBatch = 64
    static let maximumOutputBytes = 1_024 * 1_024

    /// Root-relative paths Git ignores (exact matches only).
    private(set) var ignoredPaths: Set<String> = []
    /// Root-relative folders Git ignores that hold no tracked file. They
    /// cover every path inside them.
    private(set) var ignoredDirectories: Set<String> = []

    /// One repository's share of the paths to ask about. Paths are
    /// root-relative; `repositoryRelativePath` is "" for the root itself.
    struct Group: Equatable, Sendable {
        let repositoryRelativePath: String
        var paths: [String] = []
        /// Parent folders of `paths` inside this repository, asked about so
        /// an ignored folder can be remembered.
        var directories: [String] = []
    }

    struct Plan: Equatable, Sendable {
        /// Paths already known to be ignored. No process is needed for them.
        var knownIgnored: Set<String> = []
        var groups: [Group] = []
    }

    struct Result: Equatable, Sendable {
        var ignoredPaths: Set<String> = []
        /// Ignored folders that hold no tracked file.
        var cleanIgnoredDirectories: Set<String> = []
    }

    mutating func reset() {
        ignoredPaths = []
        ignoredDirectories = []
    }

    /// Whether the memory alone says `path` is ignored.
    func isKnownIgnored(_ path: String) -> Bool {
        if ignoredPaths.contains(path) { return true }
        guard !ignoredDirectories.isEmpty else { return false }
        var current = Substring(path)
        while true {
            if ignoredDirectories.contains(String(current)) { return true }
            guard let slash = current.lastIndex(of: "/") else { return false }
            current = current[..<slash]
        }
    }

    /// Splits `candidates` into what the memory already answers and what
    /// Git must be asked, one group per repository. A path belongs to the
    /// nested repository whose folder is its longest prefix; the nested
    /// folder itself belongs to the outer repository.
    func plan(candidates: [String], nestedRepositories: [String]) -> Plan {
        var plan = Plan()
        let nested = nestedRepositories.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var groups: [String: Group] = [:]
        var order: [String] = []
        var seenDirectories: Set<String> = []
        var queryCount = 0
        for path in candidates {
            if isKnownIgnored(path) {
                plan.knownIgnored.insert(path)
                continue
            }
            let repository = nested.first { path.hasPrefix($0 + "/") } ?? ""
            if groups[repository] == nil {
                groups[repository] = Group(repositoryRelativePath: repository)
                order.append(repository)
            }
            groups[repository]?.paths.append(path)
            queryCount += 1
            // Parent folders strictly inside the repository folder.
            var current = Substring(path)
            while let slash = current.lastIndex(of: "/") {
                current = current[..<slash]
                let directory = String(current)
                guard directory != repository, !repository.isEmpty || !directory.isEmpty,
                    directory.count > repository.count
                else { break }
                guard seenDirectories.insert(directory).inserted else { break }
                groups[repository]?.directories.append(directory)
                queryCount += 1
            }
        }
        guard queryCount <= Self.maximumQueryPaths else { return plan }
        plan.groups = order.compactMap { groups[$0] }
        return plan
    }

    /// Remembers what one batch learned. The memory is cleared, not grown,
    /// above its bound.
    mutating func learn(_ result: Result) {
        guard !result.ignoredPaths.isEmpty || !result.cleanIgnoredDirectories.isEmpty else {
            return
        }
        let count =
            ignoredPaths.count + ignoredDirectories.count + result.ignoredPaths.count
            + result.cleanIgnoredDirectories.count
        if count > Self.maximumRememberedEntries { reset() }
        ignoredPaths.formUnion(result.ignoredPaths)
        ignoredDirectories.formUnion(result.cleanIgnoredDirectories)
    }

    /// The outermost folders of `directories`: a folder inside another
    /// listed folder is dropped. Sorted, at most `limit`.
    static func outermost(_ directories: Set<String>, limit: Int) -> [String] {
        let sorted = directories.sorted()
        var result: [String] = []
        for directory in sorted {
            if let last = result.last, directory.hasPrefix(last + "/") { continue }
            result.append(directory)
            if result.count == limit { break }
        }
        return result
    }

    /// `git check-ignore -z` output (repository-relative, NUL-separated) as
    /// root-relative paths.
    static func parseReportedPaths(_ output: Data, repositoryRelativePath: String) -> Set<String> {
        var paths: Set<String> = []
        for field in output.split(separator: 0, omittingEmptySubsequences: true) {
            let path = String(decoding: field, as: UTF8.self)
            paths.insert(
                repositoryRelativePath.isEmpty ? path : repositoryRelativePath + "/" + path)
        }
        return paths
    }

    /// Folders of `directories` with no path of `trackedPaths` inside them.
    static func directoriesWithoutTrackedFiles(
        _ directories: [String], trackedPaths: [String]
    ) -> Set<String> {
        Set(
            directories.filter { directory in
                !trackedPaths.contains { $0 == directory || $0.hasPrefix(directory + "/") }
            })
    }

    /// Asks Git about each group of `plan`. Runs off the main actor. A group
    /// whose folder is not in a Git work tree, or whose Git run fails, adds
    /// nothing.
    @concurrent
    static func resolve(_ plan: Plan, rootPath: String) async -> Result {
        var result = Result()
        let runner = GitCommandRunner()
        for group in plan.groups {
            guard !Task.isCancelled else { return Result() }
            let repositoryPath =
                group.repositoryRelativePath.isEmpty
                ? rootPath : rootPath + "/" + group.repositoryRelativePath
            guard
                WorkspaceRootList.isInsideGitWorkTree(
                    path: repositoryPath, fileExists: { FileManager.default.fileExists(atPath: $0) }
                )
            else { continue }
            let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            let prefixLength =
                group.repositoryRelativePath.isEmpty ? 0 : group.repositoryRelativePath.count + 1
            let queries = group.paths + group.directories
            var input = Data()
            for path in queries {
                input.append(contentsOf: path.utf8.dropFirst(prefixLength))
                input.append(0)
            }
            guard
                let output = try? await runner.run(
                    arguments: ["check-ignore", "--stdin", "-z"], at: repositoryURL,
                    standardInput: input, maximumOutputBytes: maximumOutputBytes),
                output.terminationStatus == 0
            else { continue }  // 1 means nothing is ignored; other codes are errors.
            let reported = parseReportedPaths(
                output.standardOutput, repositoryRelativePath: group.repositoryRelativePath)
            result.ignoredPaths.formUnion(reported.intersection(group.paths))
            let ignoredDirectories = outermost(
                reported.intersection(group.directories),
                limit: maximumNewDirectoriesPerBatch)
            guard !ignoredDirectories.isEmpty else { continue }
            // A tracked file inside an ignored folder is not ignored, so a
            // folder is remembered only when Git tracks nothing in it.
            let pathspecs = ignoredDirectories.map {
                ":(literal)" + String($0.dropFirst(prefixLength))
            }
            guard
                let tracked = try? await runner.run(
                    arguments: ["ls-files", "-z", "--"] + pathspecs, at: repositoryURL,
                    maximumOutputBytes: maximumOutputBytes),
                tracked.terminationStatus == 0
            else { continue }
            let trackedPaths = Array(
                parseReportedPaths(
                    tracked.standardOutput, repositoryRelativePath: group.repositoryRelativePath))
            result.cleanIgnoredDirectories.formUnion(
                directoriesWithoutTrackedFiles(ignoredDirectories, trackedPaths: trackedPaths))
        }
        return result
    }
}
