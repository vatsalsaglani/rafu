import Foundation
import Observation
import RafuCore

/// Lazy Files-tree state, file watcher, and quick-open index for one
/// additional (non-primary) root of a multi-folder workspace.
///
/// The primary root keeps using `WorkspaceSession`'s own tree state, so a
/// one-folder workspace behaves exactly as before. Like the primary tree,
/// only directories the user expands are listed; nothing is preloaded. The
/// quick-open index builds only when the palette first asks for files.
@MainActor
@Observable
final class WorkspaceRootTree: Identifiable {
    let root: WorkspaceRoot
    let url: URL
    /// One listed directory level per key, keyed by root-relative path
    /// ("" for the root itself).
    var loadedChildren: [String: [WorkspaceFileNode]] = [:]
    var expandedDirectories: Set<String> = [""]
    var loadingDirectories: Set<String> = []
    private(set) var loadError: String?
    private(set) var fileIndexState: WorkspaceFileNameIndex.State = .idle

    @ObservationIgnored private let fileService = WorkspaceFileService()
    @ObservationIgnored private let liveness = WorkspaceLivenessService()
    @ObservationIgnored private let fileIndex = WorkspaceFileNameIndex()
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var securityScopedURL: URL?

    var id: UUID { root.id }

    /// `hasSecurityScope` is true when the caller already started access on
    /// `url`; the tree then stops it when the root is removed.
    init(root: WorkspaceRoot, url: URL, hasSecurityScope: Bool) {
        self.root = root
        self.url = url
        self.securityScopedURL = hasSecurityScope ? url : nil
    }

    isolated deinit {
        stop()
    }

    /// Starts the FSEvents watcher for this root. `onChanges` runs on the
    /// main actor after the tree has re-listed what changed.
    func start(
        openDocumentPaths: @escaping @MainActor () -> Set<String>,
        onChanges: @escaping @MainActor (WorkspaceChangeSet) async -> Void
    ) {
        liveness.start(rootURL: url, openDocumentPaths: openDocumentPaths) {
            [weak self] changes in
            guard let self else { return }
            await self.apply(changes)
            await onChanges(changes)
        }
    }

    /// Folders of the nested repositories in this root, so the watcher asks
    /// each one about ignored paths with its own rules.
    func setNestedRepositoryPaths(_ paths: [String]) {
        liveness.nestedRepositoryRelativePaths = paths
    }

    /// Stops the watcher and index work and ends the security scope. Safe to
    /// call more than once.
    func stop() {
        liveness.stop()
        indexTask?.cancel()
        indexTask = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Lazy listing

    func loadChildrenIfNeeded(_ relativeDirectoryPath: String) {
        guard loadedChildren[relativeDirectoryPath] == nil,
            !loadingDirectories.contains(relativeDirectoryPath)
        else { return }
        Task { await loadChildren(relativeDirectoryPath) }
    }

    func setExpanded(_ isExpanded: Bool, _ relativeDirectoryPath: String) {
        if isExpanded {
            expandedDirectories.insert(relativeDirectoryPath)
        } else {
            expandedDirectories.remove(relativeDirectoryPath)
        }
    }

    private func loadChildren(_ relativeDirectoryPath: String) async {
        guard loadedChildren[relativeDirectoryPath] == nil,
            !loadingDirectories.contains(relativeDirectoryPath)
        else { return }
        loadingDirectories.insert(relativeDirectoryPath)
        defer { loadingDirectories.remove(relativeDirectoryPath) }
        do {
            loadedChildren[relativeDirectoryPath] = try await fileService.listDirectory(
                rootURL: url, relativeDirectoryPath: relativeDirectoryPath)
            if relativeDirectoryPath.isEmpty { loadError = nil }
        } catch is CancellationError {
            return
        } catch {
            if relativeDirectoryPath.isEmpty {
                loadError = "This folder could not be read."
                loadedChildren[""] = []
            }
        }
    }

    /// Re-lists every directory already shown (rename, create, Git checkout).
    func reloadMaterializedDirectories() async {
        var updated: [String: [WorkspaceFileNode]] = [:]
        for relativePath in Set(loadedChildren.keys).union([""]) {
            if let children = try? await fileService.listDirectory(
                rootURL: url, relativeDirectoryPath: relativePath)
            {
                updated[relativePath] = children
            }
        }
        loadedChildren = updated
        expandedDirectories.formIntersection(Set(updated.keys).union([""]))
    }

    private func apply(_ changes: WorkspaceChangeSet) async {
        if changes.isStorm {
            await reloadMaterializedDirectories()
        } else if changes.treeChanged || !changes.ignoredDirectoryRelativePaths.isEmpty {
            // Git-ignored paths re-list only what the tree shows; they do not
            // invalidate the quick-open index below.
            let scope = WorkspaceFileTreeRefreshScope.materializedDirectories(
                affectedBy: changes.changedDirectoryRelativePaths.union(
                    changes.ignoredDirectoryRelativePaths),
                among: Set(loadedChildren.keys))
            for relativePath in scope {
                if let children = try? await fileService.listDirectory(
                    rootURL: url, relativeDirectoryPath: relativePath)
                {
                    loadedChildren[relativePath] = children
                } else {
                    loadedChildren[relativePath] = nil
                }
            }
        }
        if changes.isStorm || changes.treeChanged, fileIndexState != .idle {
            invalidateFileIndex()
        }
    }

    // MARK: - Quick open

    /// Starts a build when the index is idle. `onBuilt` runs when the build
    /// ends, so the palette can query again.
    func ensureFileIndex(onBuilt: @escaping @MainActor () -> Void) {
        guard fileIndexState == .idle, indexTask == nil else { return }
        fileIndexState = .building
        let url = url
        indexTask = Task(name: "Build folder file index") { [weak self, fileIndex] in
            await fileIndex.build(rootURL: url)
            let state = await fileIndex.currentState
            guard let self, !Task.isCancelled else { return }
            fileIndexState = state
            indexTask = nil
            onBuilt()
        }
    }

    func queryFileIndex(term: String, limit: Int) async throws -> [String] {
        try await fileIndex.query(term: term, limit: limit)
    }

    /// Drops the index (memory pressure or a tree change); the next palette
    /// query rebuilds it.
    func invalidateFileIndex() {
        indexTask?.cancel()
        indexTask = nil
        fileIndexState = .idle
        Task { [fileIndex] in await fileIndex.shed() }
    }
}
