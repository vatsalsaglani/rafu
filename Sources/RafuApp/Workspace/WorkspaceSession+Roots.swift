import AppKit
import Foundation
import RafuCore

/// What to apply after the primary root of a saved workspace is open.
nonisolated struct WorkspaceOpenPlan: Equatable, Sendable {
    var displayName: String?
    /// Folders after the primary root, in order. Each must be a readable
    /// directory; missing ones were already dropped by the reader.
    var additionalRoots: [URL]
    /// The `.rafuworkspace` file the window is bound to.
    var fileURL: URL?
}

/// Multi-folder workspaces: the ordered root list, adding and removing
/// folders, the Source Control root, search roots, and quick open across
/// roots.
///
/// The first root is the primary root and is the one `rootURL` names, so
/// every existing caller (terminals, Ensemble boards, language servers, the
/// CLI) keeps working on it. Each additional root has its own lazy tree,
/// file watcher, and quick-open index (`WorkspaceRootTree`).
extension WorkspaceSession {
    // MARK: - Roots

    /// The primary root. Its ID is the descriptor ID, so it is stable for
    /// the life of the open workspace.
    var primaryRoot: WorkspaceRoot? {
        guard let descriptor, let rootURL else { return nil }
        return WorkspaceRoot(id: descriptor.id, path: rootURL.path)
    }

    /// Every root in order; the first is primary. Empty with no workspace.
    var roots: [WorkspaceRoot] {
        guard let primaryRoot else { return [] }
        return [primaryRoot] + additionalRootTrees.map(\.root)
    }

    var hasMultipleRoots: Bool { !additionalRootTrees.isEmpty && rootURL != nil }

    /// Unique short labels, keyed by root ID.
    var rootDisplayNames: [UUID: String] { WorkspaceRootList.displayNames(for: roots) }

    func rootTree(for id: UUID) -> WorkspaceRootTree? {
        additionalRootTrees.first { $0.id == id }
    }

    func url(forRoot id: UUID) -> URL? {
        if id == descriptor?.id { return rootURL }
        return rootTree(for: id)?.url
    }

    /// Whether `url` lies in one of the additional (non-primary) roots.
    func isInAdditionalRoot(_ url: URL) -> Bool {
        guard hasMultipleRoots,
            let found = WorkspaceRootList.locate(absolutePath: url.path, in: roots)
        else { return false }
        return found.root.id != descriptor?.id
    }

    /// `url` as the user sees it: relative to its root, with the root label
    /// in front when the workspace has more than one root.
    func displayPath(for url: URL) -> String {
        let roots = roots
        guard let found = WorkspaceRootList.locate(absolutePath: url.path, in: roots) else {
            return (url.path as NSString).abbreviatingWithTildeInPath
        }
        return WorkspaceRootList.displayPath(
            relativePath: found.relativePath, rootID: found.root.id, roots: roots)
    }

    // MARK: - Adding and removing folders

    /// "Add Folder to Workspace…": a panel that accepts one or more folders.
    func requestAddFolder() {
        guard rootURL != nil, !isOpenFolderImporterPresented else { return }
        isOpenFolderImporterPresented = true
        let panel = WorkspaceFolderPicker.makePanel()
        panel.title = "Add Folder to Workspace"
        panel.prompt = "Add"
        panel.message = "Choose folders to add to this workspace."
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard let self else { return }
            isOpenFolderImporterPresented = false
            guard response == .OK else { return }
            for url in panel.urls { addFolder(at: url) }
        }
    }

    /// Adds `url` as the last root. Returns false when it was not added (no
    /// workspace, not a readable folder, already a root, or the limit).
    @discardableResult
    func addFolder(at url: URL) -> Bool {
        guard rootURL != nil else { return false }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path)
        else {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            reportWorkspaceError(
                title: "Unable to Add Folder",
                message: "\(url.lastPathComponent) is not a folder Rafu can read.")
            return false
        }
        switch WorkspaceRootList.adding(path: url.path, to: roots) {
        case .added(let updated):
            guard let root = updated.last else { return false }
            // The tree keeps the granted URL, so it can end the scope later.
            let tree = WorkspaceRootTree(root: root, url: url, hasSecurityScope: hasSecurityScope)
            additionalRootTrees.append(tree)
            startWatching(tree)
            tree.loadChildrenIfNeeded("")
            refreshGitRepositoryRoots()
            fileIndexGeneration += 1
            scheduleCanvasWorkspaceSave()
            return true
        case .duplicate:
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            return false
        case .limitReached:
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            reportWorkspaceError(
                title: "Unable to Add Folder",
                message: "A workspace can hold up to \(WorkspaceRootList.maximumRoots) folders.")
            return false
        case .invalidPath:
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            return false
        }
    }

    /// Adds the folders of a saved workspace (missing ones are skipped).
    func applyAdditionalRoots(_ urls: [URL]) {
        for url in urls { addFolder(at: url) }
    }

    /// "Remove Folder from Workspace". The primary root cannot be removed.
    /// Open tabs from the folder stay open; they are ordinary files.
    func removeFolder(_ id: UUID) {
        guard let index = additionalRootTrees.firstIndex(where: { $0.id == id }) else { return }
        let tree = additionalRootTrees.remove(at: index)
        tree.stop()
        if sourceControlRootID == id { sourceControlRootID = nil }
        gitRepositoryRootIDs.remove(id)
        fileIndexGeneration += 1
        scheduleCanvasWorkspaceSave()
    }

    /// Ends every additional root (workspace replaced or window closed).
    func tearDownAdditionalRoots() {
        for tree in additionalRootTrees { tree.stop() }
        additionalRootTrees = []
        gitRepositoryRootIDs = []
        workspaceFileURL = nil
        if sourceControlRootID != nil { sourceControlRootID = nil }
    }

    /// Relaunch restoration of the extra folders. Bookmarks resolve off the
    /// main actor; a folder that no longer exists is skipped.
    func restoreAdditionalRoots(
        _ saved: [RestorableWorkspaceRoot], workspaceFilePath: String?
    ) async {
        let primary = rootURL
        if let workspaceFilePath, workspaceFilePath.hasPrefix("/") {
            workspaceFileURL = URL(fileURLWithPath: workspaceFilePath)
        }
        guard !saved.isEmpty else {
            refreshGitRepositoryRoots()
            return
        }
        let urls = await WorkspaceRootBookmarks.resolveFolders(
            saved.map { WorkspaceRootBookmarks.SavedFolder(bookmark: $0.bookmark, path: $0.path) })
        guard rootURL == primary else { return }
        applyAdditionalRoots(urls)
        refreshGitRepositoryRoots()
    }

    private func startWatching(_ tree: WorkspaceRootTree) {
        let rootID = tree.id
        tree.start { [weak self] in
            guard let self else { return [] }
            return Set(
                openDocuments.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        } onChanges: { [weak self] changes in
            await self?.handleAdditionalRootChanges(changes, rootID: rootID)
        }
    }

    /// FSEvents for an additional root: reload clean open files that changed
    /// on disk, and refresh Source Control when it shows this root.
    private func handleAdditionalRootChanges(_ changes: WorkspaceChangeSet, rootID: UUID) async {
        if sourceControlRootID == rootID {
            if changes.gitChanged || changes.isStorm {
                await refreshGit()
            } else if changes.treeChanged {
                await refreshGitSnapshotOnly()
            }
        }
        guard !changes.changedDocumentPaths.isEmpty else { return }
        for document in openDocuments where !document.isDirty {
            let path = document.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard changes.changedDocumentPaths.contains(path) else { continue }
            let diskDate =
                (try? FileManager.default.attributesOfItem(atPath: document.url.path))?[
                    .modificationDate] as? Date
            if let known = document.knownDiskModificationDate, let diskDate, known == diskDate {
                continue
            }
            document.revision += 1
        }
    }

    func reportWorkspaceError(title: String, message: String) {
        openFolderErrorTitle = title
        openFolderErrorMessage = message
        isOpenFolderErrorPresented = true
    }

    // MARK: - Source Control root

    /// The folder Source Control and the file-tree Git badges work on.
    var gitRootURL: URL? {
        if let id = sourceControlRootID, let tree = rootTree(for: id) { return tree.url }
        return rootURL
    }

    /// The root ID Source Control shows (primary when none is chosen).
    var effectiveSourceControlRootID: UUID? {
        if let id = sourceControlRootID, rootTree(for: id) != nil { return id }
        return descriptor?.id
    }

    /// Roots that are Git work trees. The Source Control navigator shows a
    /// root picker only when there is more than one.
    var sourceControlRootChoices: [WorkspaceRoot] {
        roots.filter { gitRepositoryRootIDs.contains($0.id) }
    }

    /// The Git badge for a Files-tree row. Badges are keyed relative to the
    /// Source Control root, so rows of any other root show none.
    /// `rootID` nil means the primary root.
    func gitTreeBadge(forRelativePath path: String, rootID: UUID?) -> GitTreeBadge? {
        guard (rootID ?? descriptor?.id) == effectiveSourceControlRootID else { return nil }
        return gitTreeBadges[path]
    }

    func selectSourceControlRoot(_ id: UUID) {
        sourceControlRootID = id == descriptor?.id ? nil : id
    }

    /// Re-checks which roots sit inside a Git work tree, off the main actor.
    func refreshGitRepositoryRoots() {
        let roots = roots
        guard !roots.isEmpty else {
            gitRepositoryRootIDs = []
            return
        }
        Task(name: "Find Git roots") { [weak self] in
            let ids = await WorkspaceRootBookmarks.gitRootIDs(roots)
            guard let self, self.roots.map(\.id) == roots.map(\.id) else { return }
            gitRepositoryRootIDs = ids
        }
    }

    // MARK: - Search and quick open

    /// Search covers every root, primary first; results carry the root label
    /// only when there is more than one root.
    var workspaceSearchRoots: [WorkspaceSearchRoot] {
        guard let rootURL else { return [] }
        guard hasMultipleRoots else { return [WorkspaceSearchRoot(url: rootURL, label: nil)] }
        let names = rootDisplayNames
        return roots.map { root in
            WorkspaceSearchRoot(
                url: url(forRoot: root.id) ?? URL(fileURLWithPath: root.path, isDirectory: true),
                label: names[root.id] ?? root.name)
        }
    }

    /// Builds the indexes of the additional roots the first time the palette
    /// asks for files (never eagerly).
    func ensureAdditionalFileIndexesReady() {
        for tree in additionalRootTrees {
            tree.ensureFileIndex { [weak self] in self?.fileIndexGeneration += 1 }
        }
    }

    /// Quick open across every root. Per-root ranked results are merged
    /// round robin, so each folder's best matches stay near the top.
    func queryWorkspaceFiles(term: String, limit: Int) async throws -> [WorkspaceFileMatch] {
        let roots = roots
        guard let primary = roots.first else { return [] }
        let primaryPaths = try await queryFileIndex(term: term, limit: limit)
        let trees = additionalRootTrees
        guard !trees.isEmpty else {
            return primaryPaths.map {
                WorkspaceFileMatch(rootID: primary.id, relativePath: $0, displayPath: $0)
            }
        }
        var lists: [[WorkspaceFileMatch]] = [
            primaryPaths.map { path in match(path, rootID: primary.id, roots: roots) }
        ]
        for tree in trees {
            try Task.checkCancellation()
            let paths = try await tree.queryFileIndex(term: term, limit: limit)
            lists.append(paths.map { path in match(path, rootID: tree.id, roots: roots) })
        }
        return WorkspaceRootList.interleave(lists, limit: limit)
    }

    private func match(
        _ path: String, rootID: UUID, roots: [WorkspaceRoot]
    ) -> WorkspaceFileMatch {
        WorkspaceFileMatch(
            rootID: rootID, relativePath: path,
            displayPath: WorkspaceRootList.displayPath(
                relativePath: path, rootID: rootID, roots: roots))
    }

    /// Opens a quick-open result in whichever root it came from.
    func openFile(_ match: WorkspaceFileMatch) {
        guard match.rootID != descriptor?.id, let tree = rootTree(for: match.rootID) else {
            openFile(atRelativePath: match.relativePath)
            return
        }
        let url = tree.url.appending(path: match.relativePath)
        open(WorkspaceFileNode(url: url, relativePath: match.relativePath, isDirectory: false))
    }
}

/// Bookmark and file-system work for roots, always off the main actor.
nonisolated enum WorkspaceRootBookmarks {
    nonisolated struct SavedFolder: Sendable {
        let bookmark: Data?
        let path: String
    }

    /// Bookmark data for `url`: security-scoped when the system allows it,
    /// otherwise a plain bookmark, otherwise nil (the path still works).
    static func bookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        {
            return data
        }
        return try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @concurrent
    static func restorableRoots(for urls: [URL]) async -> [RestorableWorkspaceRoot] {
        urls.map { RestorableWorkspaceRoot(bookmark: bookmark(for: $0), path: $0.path) }
    }

    @concurrent
    static func bookmarks(for urls: [URL]) async -> [Data?] {
        urls.map { bookmark(for: $0) }
    }

    /// Resolves each folder: the bookmark first (it follows moves), then the
    /// last known path. Keeps only readable directories, in order.
    @concurrent
    static func resolveFolders(_ folders: [SavedFolder]) async -> [URL] {
        folders.compactMap { resolve($0) }
    }

    static func resolve(_ folder: SavedFolder) -> URL? {
        if let bookmark = folder.bookmark {
            for options: URL.BookmarkResolutionOptions in [[.withSecurityScope], []] {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
                    bookmarkDataIsStale: &isStale),
                    isReadableDirectory(url)
                {
                    return url
                }
            }
        }
        let url = URL(fileURLWithPath: folder.path, isDirectory: true)
        return isReadableDirectory(url) ? url : nil
    }

    static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }

    @concurrent
    static func gitRootIDs(_ roots: [WorkspaceRoot]) async -> Set<UUID> {
        Set(
            roots.filter { root in
                WorkspaceRootList.isInsideGitWorkTree(path: root.path) {
                    FileManager.default.fileExists(atPath: $0)
                }
            }.map(\.id))
    }
}
