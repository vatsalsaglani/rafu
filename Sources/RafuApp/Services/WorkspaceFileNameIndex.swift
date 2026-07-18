import Foundation

/// Background filename index backing the command palette's file mode. Builds
/// a compact `[String]` of workspace-relative paths — never the sidebar's
/// materialized `WorkspaceFileNode` tree — so ⌘P can search every file in a
/// monorepo without the lazy sidebar tree recursing into it.
///
/// Git workspaces are indexed with `git ls-files` (`.gitignore`-aware, no
/// process needed to walk the filesystem); non-git workspaces fall back to a
/// cancellable `FileManager` enumeration sharing `WorkspaceFileService`'s
/// directory exclusions. Actor isolation makes the build and every query
/// off-main automatically.
actor WorkspaceFileNameIndex {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case building
        case ready(count: Int, isTruncated: Bool)
    }

    /// Safety cap shared by both sources. Git workspaces very rarely
    /// approach this; it mainly bounds the non-git enumerator fallback.
    static let maximumEntries = 200_000

    private let runner = GitCommandRunner()
    /// Defaults to `maximumEntries`; overridable only so tests can exercise
    /// truncation without materializing hundreds of thousands of files.
    private let entryCap: Int
    private var paths: [String] = []
    private(set) var state: State = .idle

    init(entryCap: Int = WorkspaceFileNameIndex.maximumEntries) {
        self.entryCap = entryCap
    }

    var currentState: State { state }

    /// Rebuilds the index from scratch. A cancelled build leaves the
    /// previous `paths`/`state` untouched — the caller (`WorkspaceSession`)
    /// always re-requests a fresh build for a superseded one, so there is
    /// nothing partial to publish.
    func build(rootURL: URL) async {
        state = .building
        do {
            try Task.checkCancellation()
            if let gitPaths = try await gitLSFilesPaths(rootURL: rootURL) {
                try Task.checkCancellation()
                publish(gitPaths, cappedAt: entryCap)
                return
            }
            let (enumerated, isTruncated) = try await enumeratedPaths(rootURL: rootURL)
            paths = enumerated.sorted()
            state = .ready(count: paths.count, isTruncated: isTruncated)
        } catch is CancellationError {
            return
        } catch {
            // A failed build (git/enumerator hiccup on open) must NOT latch as
            // `.ready(count: 0)` — `ensureFileIndexReady()` only rebuilds an
            // `.idle` index, so latching empty would pin file search at "no
            // matching files" until the folder is reopened. Reset to `.idle`
            // so the next palette query transparently retries the build.
            paths = []
            state = .idle
        }
    }

    func reset() {
        paths = []
        state = .idle
    }

    /// Clears the index back to `.idle` under memory pressure
    /// (`MemoryPressureMonitor` / `WorkspaceSession.respondToMemoryPressure`).
    /// Identical to `reset()`; kept as a distinct name so a pressure-driven
    /// shed reads clearly at its call site, separate from the "opening a new
    /// workspace" reset path.
    func shed() {
        reset()
    }

    /// Ranks the index against `term`, filename-over-path, off-main and
    /// cancellable. An empty term returns the first `limit` paths.
    func query(term: String, limit: Int) async throws -> [String] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(paths.prefix(max(0, limit))) }
        return try await CommandPaletteMatcher.rankFiles(query: needle, paths: paths, limit: limit)
    }

    private func publish(_ collected: [String], cappedAt cap: Int) {
        let isTruncated = collected.count > cap
        paths = Array(collected.prefix(cap)).sorted()
        state = .ready(count: paths.count, isTruncated: isTruncated)
    }

    /// `nil` means "not a git workspace (or `git` failed)" — the caller
    /// falls back to the filesystem enumerator. `--deduplicate` merges the
    /// `--cached`/`--others` result sets so untracked and tracked files
    /// never appear twice.
    ///
    /// Known limitation: `--cached` still lists a file `git rm`'d from the
    /// worktree but not yet committed, until the next rebuild. Follow-up:
    /// subtract `git ls-files -d` (deleted-in-worktree) from the result.
    private func gitLSFilesPaths(rootURL: URL) async throws -> [String]? {
        let output = try await runner.run(
            arguments: [
                "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z",
            ],
            at: rootURL
        )
        guard output.terminationStatus == 0 else { return nil }
        return Self.splitNulSeparated(output.standardOutput)
    }

    private func enumeratedPaths(rootURL: URL) async throws -> (paths: [String], isTruncated: Bool)
    {
        try Task.checkCancellation()
        // `FileManager.enumerator(at:)` can return symlink-resolved child
        // URLs (e.g. `/private/var/...` for a `/var/...` root under macOS's
        // temporary-directory symlink) regardless of whether the starting
        // URL was resolved. Resolving both the root and every enumerated
        // child before computing a relative path keeps them aligned,
        // matching `WorkspaceSearchService`'s enumerator handling.
        let resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: resolvedRootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else { return ([], false) }

        var paths: [String] = []
        var visited = 0
        var isTruncated = false
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited.isMultiple(of: 2_000) { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if WorkspaceFileService.excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent != ".DS_Store" else {
                continue
            }
            guard paths.count < entryCap else {
                isTruncated = true
                break
            }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            paths.append(relativePath(for: resolvedURL, rootURL: resolvedRootURL))
        }
        return (paths, isTruncated)
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    private static func splitNulSeparated(_ data: Data) -> [String] {
        data.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
    }
}
