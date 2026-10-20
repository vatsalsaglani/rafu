import CoreServices
import Foundation

/// What one debounced batch of filesystem events means for the workspace.
nonisolated struct WorkspaceChangeSet: Equatable, Sendable {
    var treeChanged = false
    var gitChanged = false
    /// Standardized absolute paths of open documents whose files changed.
    var changedDocumentPaths: Set<String> = []
    /// Workspace-relative paths ("" for the root) of directories whose
    /// direct listing may have changed. Lets the lazy tree re-list only
    /// materialized (already-expanded) directories instead of the whole
    /// workspace.
    var changedDirectoryRelativePaths: Set<String> = []
    /// True when the batch is large enough to skip per-directory work and
    /// force one coalesced full refresh.
    var isStorm = false
    /// Parent directories of changed paths that Git ignores. Only a tree
    /// directory that is already listed is re-listed for them: no Git
    /// status, no index rebuild, no symbol update
    /// (`WorkspaceIgnoredPathFilter`).
    var ignoredDirectoryRelativePaths: Set<String> = []
    /// Root-relative folders whose own `.git` HEAD, index, or refs changed
    /// (a nested repository, such as `child/.git/HEAD`).
    var nestedGitChangedDirectories: Set<String> = []

    var isEmpty: Bool {
        !treeChanged && !gitChanged && changedDocumentPaths.isEmpty
            && ignoredDirectoryRelativePaths.isEmpty && nestedGitChangedDirectories.isEmpty
    }
}

/// Pure classification of raw FSEvents paths into a `WorkspaceChangeSet`.
/// Kept nonisolated and value-typed so it is unit-testable without a stream.
nonisolated struct WorkspaceChangeClassifier: Sendable {
    /// Path components whose events are dropped entirely. The `.git`
    /// directory is special-cased first: only HEAD, index, and refs matter.
    static let noisePathComponents: Set<String> =
        WorkspaceFileService.excludedDirectories.union([".DS_Store"])

    /// Above this many surviving (non-noise, non-`.git`-internal) event
    /// occurrences in one batch, the batch is a storm. Strict `>` so a batch
    /// at exactly the threshold still takes the per-directory path — this is
    /// a bounded single-pass coalescing decision, not a hard cap.
    static let stormSurvivingPathThreshold = 1_000
    /// Above this many distinct changed directories in one batch, the batch
    /// is a storm even if the surviving-path count stays under its
    /// threshold. Strict `>` for the same reason as above.
    static let stormChangedDirectoryThreshold = 200

    /// What a path inside a `.git` directory means.
    enum GitDirectoryEvent: Equatable {
        /// HEAD, index, a ref, or packed-refs: the branch, the stage, or
        /// the commit graph changed.
        case stateChanged
        /// `info/exclude`: the ignore rules changed.
        case excludeRulesChanged
        /// Objects, logs, locks, and other churn.
        case noise
    }

    /// `relativePath` is the part after `.git/`.
    static func gitDirectoryEvent(_ relativePath: Substring) -> GitDirectoryEvent {
        if relativePath == "HEAD" || relativePath == "index" || relativePath == "packed-refs" {
            return .stateChanged
        }
        if relativePath == "info/exclude" { return .excludeRulesChanged }
        if relativePath.hasPrefix("refs/"), !relativePath.hasSuffix(".lock") {
            return .stateChanged
        }
        return .noise
    }

    /// Root-relative paths that survive the noise and `.git` filters, in
    /// batch order, once each. These are the paths the ignore filter asks
    /// Git about.
    func candidateRelativePaths(paths: [String], rootPath: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawPath in paths {
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard path.hasPrefix(rootPath + "/") else { continue }
            let components = path.dropFirst(rootPath.count + 1).split(separator: "/")
            guard !components.isEmpty,
                !components.contains(where: {
                    $0 == ".git" || Self.noisePathComponents.contains(String($0))
                })
            else { continue }
            let relative = components.joined(separator: "/")
            if seen.insert(relative).inserted { result.append(relative) }
        }
        return result
    }

    /// True when the batch may have changed what Git ignores: a
    /// `.gitignore` anywhere, or the `info/exclude` file of the root's or a
    /// nested repository's `.git`.
    func ignoreRulesMayHaveChanged(paths: [String], rootPath: String) -> Bool {
        paths.contains { rawPath in
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard path.hasPrefix(rootPath + "/") else { return false }
            if (path as NSString).lastPathComponent == ".gitignore" { return true }
            guard let range = path.range(of: "/.git/", options: .backwards) else {
                return false
            }
            return Self.gitDirectoryEvent(path[range.upperBound...]) == .excludeRulesChanged
        }
    }

    /// `isIgnored` gets a root-relative path and answers whether Git ignores
    /// it. An ignored path never marks the tree changed and never counts
    /// toward a storm. It still reloads an open document, and it re-lists
    /// its directory when the tree shows that directory.
    func classify(
        paths: [String],
        rootPath: String,
        openDocumentPaths: Set<String>,
        isIgnored: (String) -> Bool = { _ in false }
    ) -> WorkspaceChangeSet {
        var changes = WorkspaceChangeSet()
        let gitDirectoryPath = rootPath + "/.git"
        // Counts surviving event occurrences, not unique paths — a path
        // repeated across the batch counts each time. That only makes storm
        // detection more eager, never less, which is the safe direction.
        var survivingPathCount = 0
        for rawPath in paths {
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            if path == gitDirectoryPath || path.hasPrefix(gitDirectoryPath + "/") {
                // Only ref/stage tips matter; object and lock churn is noise.
                let inside = path.dropFirst(min(path.count, gitDirectoryPath.count + 1))
                if Self.gitDirectoryEvent(inside) == .stateChanged {
                    changes.gitChanged = true
                }
                continue
            }
            if path == rootPath {
                changes.treeChanged = true
                changes.changedDirectoryRelativePaths.insert("")
                survivingPathCount += 1
                continue
            }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativeComponents = path.dropFirst(rootPath.count + 1).split(separator: "/")
            if let gitIndex = relativeComponents.firstIndex(of: ".git") {
                // A nested repository's own `.git` (`child/.git/HEAD`).
                let inside = relativeComponents[(gitIndex + 1)...].joined(separator: "/")
                if gitIndex > 0, Self.gitDirectoryEvent(Substring(inside)) == .stateChanged {
                    changes.nestedGitChangedDirectories.insert(
                        relativeComponents[..<gitIndex].joined(separator: "/"))
                }
                continue
            }
            guard
                !relativeComponents.contains(where: {
                    Self.noisePathComponents.contains(String($0))
                })
            else { continue }
            let parentRelativePath = relativeComponents.dropLast().joined(separator: "/")
            if openDocumentPaths.contains(path) {
                changes.changedDocumentPaths.insert(path)
            }
            if isIgnored(relativeComponents.joined(separator: "/")) {
                changes.ignoredDirectoryRelativePaths.insert(parentRelativePath)
                continue
            }
            changes.treeChanged = true
            changes.changedDirectoryRelativePaths.insert(parentRelativePath)
            survivingPathCount += 1
        }
        // Computed before clearing changedDirectoryRelativePaths below, since
        // the directory-count threshold reads it.
        changes.isStorm =
            survivingPathCount > Self.stormSurvivingPathThreshold
            || changes.changedDirectoryRelativePaths.count > Self.stormChangedDirectoryThreshold
        if changes.isStorm { changes.changedDirectoryRelativePaths = [] }
        changes.ignoredDirectoryRelativePaths.subtract(changes.changedDirectoryRelativePaths)
        return changes
    }
}

/// Carries FSEvents callback batches into an `AsyncStream`. The only stored
/// property is the Sendable continuation, so the conformance is honest.
private nonisolated final class FSEventRelay: Sendable {
    let continuation: AsyncStream<[String]>.Continuation

    init(continuation: AsyncStream<[String]>.Continuation) {
        self.continuation = continuation
    }
}

/// C callback: captures nothing; all state flows through the unretained
/// relay in `info`, which the owning service keeps alive until the stream
/// is invalidated.
private nonisolated func workspaceLivenessEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let relay = Unmanaged<FSEventRelay>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes delivers eventPaths as a CFArray
    // of CFString.
    let array = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(eventPaths)).takeUnretainedValue()
    guard let paths = array as NSArray as? [String], !paths.isEmpty else { return }
    relay.continuation.yield(paths)
}

/// FSEvents-backed watcher for one workspace root. Owns the stream, the
/// consuming task, and a trailing debounce; classification and the change
/// handler run on the main actor. `start` restarts cleanly and `stop` is
/// idempotent.
@MainActor
final class WorkspaceLivenessService {
    static let debounceInterval: Duration = .milliseconds(400)

    /// Root-relative folders of nested repositories. Their paths are asked
    /// about with their own ignore rules, not the root's.
    var nestedRepositoryRelativePaths: [String] = []

    private var streamRef: FSEventStreamRef?
    private var relay: FSEventRelay?
    private var consumeTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingPaths: [String] = []
    private var rootPath: String?
    private var openDocumentPaths: (@MainActor () -> Set<String>)?
    private var onChanges: (@MainActor (WorkspaceChangeSet) async -> Void)?
    private var ignoreFilter = WorkspaceIgnoredPathFilter()
    private let eventQueue = DispatchQueue(label: "dev.rafu.fsevents")

    func start(
        rootURL: URL,
        openDocumentPaths: @escaping @MainActor () -> Set<String>,
        onChanges: @escaping @MainActor (WorkspaceChangeSet) async -> Void
    ) {
        stop()
        // FSEvents reports canonical paths (/private/tmp, not /tmp), so
        // resolve the root once and classify raw event paths against it.
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let relay = FSEventRelay(continuation: continuation)
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(relay).toOpaque()
        let flags =
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagIgnoreSelf
        guard
            let streamRef = FSEventStreamCreate(
                kCFAllocatorDefault,
                workspaceLivenessEventCallback,
                &context,
                [rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                FSEventStreamCreateFlags(flags)
            )
        else {
            continuation.finish()
            return
        }
        FSEventStreamSetDispatchQueue(streamRef, eventQueue)
        guard FSEventStreamStart(streamRef) else {
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
            continuation.finish()
            return
        }

        self.streamRef = streamRef
        self.relay = relay
        self.rootPath = rootPath
        self.openDocumentPaths = openDocumentPaths
        self.onChanges = onChanges
        consumeTask = Task(name: "Workspace liveness events") { [weak self] in
            for await batch in stream {
                guard let self, !Task.isCancelled else { return }
                accumulate(batch)
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        relay?.continuation.finish()
        if let streamRef {
            FSEventStreamStop(streamRef)
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
            self.streamRef = nil
        }
        relay = nil
        pendingPaths = []
        rootPath = nil
        openDocumentPaths = nil
        onChanges = nil
        ignoreFilter.reset()
    }

    isolated deinit {
        stop()
    }

    /// Trailing debounce: every batch restarts the timer so one burst of
    /// events collapses into a single classification and refresh.
    private func accumulate(_ batch: [String]) {
        pendingPaths.append(contentsOf: batch)
        debounceTask?.cancel()
        debounceTask = Task(name: "Workspace liveness debounce") { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        let paths = pendingPaths
        pendingPaths = []
        guard !paths.isEmpty, let rootPath, let openDocumentPaths, let onChanges else { return }
        let classifier = WorkspaceChangeClassifier()
        let documentPaths = openDocumentPaths()
        var changes = classifier.classify(
            paths: paths, rootPath: rootPath, openDocumentPaths: documentPaths)
        // Stage, ref, and ignore-rule changes can change what Git ignores
        // (a force-added file is no longer ignored), so the cache restarts.
        if changes.gitChanged || !changes.nestedGitChangedDirectories.isEmpty
            || classifier.ignoreRulesMayHaveChanged(paths: paths, rootPath: rootPath)
        {
            ignoreFilter.reset()
        }
        if changes.treeChanged {
            let plan = ignoreFilter.plan(
                candidates: classifier.candidateRelativePaths(paths: paths, rootPath: rootPath),
                nestedRepositories: nestedRepositoryRelativePaths)
            let result = await WorkspaceIgnoredPathFilter.resolve(plan, rootPath: rootPath)
            // `stop()` or a restart on another root drops a stale answer.
            guard !Task.isCancelled, self.rootPath == rootPath else { return }
            ignoreFilter.learn(result)
            let ignored = plan.knownIgnored.union(result.ignoredPaths)
            if !ignored.isEmpty {
                changes = classifier.classify(
                    paths: paths, rootPath: rootPath, openDocumentPaths: documentPaths,
                    isIgnored: { ignored.contains($0) })
            }
        }
        guard !changes.isEmpty else { return }
        await onChanges(changes)
    }
}
