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

    var isEmpty: Bool {
        !treeChanged && !gitChanged && changedDocumentPaths.isEmpty
    }
}

/// Pure classification of raw FSEvents paths into a `WorkspaceChangeSet`.
/// Kept nonisolated and value-typed so it is unit-testable without a stream.
nonisolated struct WorkspaceChangeClassifier: Sendable {
    /// Path components whose events are dropped entirely. The `.git`
    /// directory is special-cased first: only HEAD and index matter.
    static let noisePathComponents: Set<String> =
        WorkspaceFileService.excludedDirectories.union([".DS_Store"])

    func classify(
        paths: [String],
        rootPath: String,
        openDocumentPaths: Set<String>
    ) -> WorkspaceChangeSet {
        var changes = WorkspaceChangeSet()
        let gitDirectoryPath = rootPath + "/.git"
        for rawPath in paths {
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            if path == gitDirectoryPath || path.hasPrefix(gitDirectoryPath + "/") {
                // Only ref/stage tips matter; object and lock churn is noise.
                if path == gitDirectoryPath + "/HEAD" || path == gitDirectoryPath + "/index" {
                    changes.gitChanged = true
                }
                continue
            }
            if path == rootPath {
                changes.treeChanged = true
                changes.changedDirectoryRelativePaths.insert("")
                continue
            }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativeComponents = path.dropFirst(rootPath.count + 1).split(separator: "/")
            guard
                !relativeComponents.contains(where: {
                    Self.noisePathComponents.contains(String($0))
                })
            else { continue }
            changes.treeChanged = true
            let parentRelativePath = relativeComponents.dropLast().joined(separator: "/")
            changes.changedDirectoryRelativePaths.insert(parentRelativePath)
            if openDocumentPaths.contains(path) {
                changes.changedDocumentPaths.insert(path)
            }
        }
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

    private var streamRef: FSEventStreamRef?
    private var relay: FSEventRelay?
    private var consumeTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingPaths: [String] = []
    private var rootPath: String?
    private var openDocumentPaths: (@MainActor () -> Set<String>)?
    private var onChanges: (@MainActor (WorkspaceChangeSet) async -> Void)?
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
        let changes = WorkspaceChangeClassifier().classify(
            paths: paths,
            rootPath: rootPath,
            openDocumentPaths: openDocumentPaths()
        )
        guard !changes.isEmpty else { return }
        await onChanges(changes)
    }
}
