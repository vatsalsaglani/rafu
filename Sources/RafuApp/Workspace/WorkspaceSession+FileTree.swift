import AppKit
import Foundation
import RafuCore

/// The Move to Trash confirmation for one or more Files rows.
nonisolated struct WorkspaceTrashRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Top-level items only (see `WorkspaceFileService.topLevelWorkspaceItems`).
    let urls: [URL]
    /// Open documents (and Ensemble files) under `urls` with unsaved changes.
    let unsavedNames: [String]

    var title: String {
        if urls.count == 1, let url = urls.first {
            return "Move “\(url.lastPathComponent)” to the Trash?"
        }
        return "Move \(urls.count) items to the Trash?"
    }

    var message: String {
        var text = "You can undo this with Edit > Undo."
        if !unsavedNames.isEmpty {
            text +=
                " Unsaved changes in \(unsavedNames.joined(separator: ", ")) stay open "
                + "as unsaved documents. Save them to keep them."
        }
        return text
    }
}

/// A short status-bar message. A new `id` restarts its 2-second display.
nonisolated struct TransientStatusNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
}

/// Files tree multi-selection, Move to Trash, and path copying for one
/// workspace window. See docs/references/files-tree-selection-and-trash.md.
extension WorkspaceSession {
    // MARK: - Selection

    /// Every selected Files row (absolute paths).
    var selectedTreePaths: Set<String> { treeSelection.paths }

    /// The Files rows the user can see, top to bottom: the primary root,
    /// then each additional root, skipping collapsed roots and folders.
    var treeVisibleOrder: [String] {
        var trees = [
            FileTreeVisibleOrder.Tree(
                loadedChildren: loadedChildren, expandedDirectories: expandedDirectories,
                isCollapsed: hasMultipleRoots
                    && descriptor.map { collapsedTreeRootIDs.contains($0.id) } == true)
        ]
        for tree in additionalRootTrees {
            trees.append(
                FileTreeVisibleOrder.Tree(
                    loadedChildren: tree.loadedChildren,
                    expandedDirectories: tree.expandedDirectories,
                    isCollapsed: collapsedTreeRootIDs.contains(tree.id)))
        }
        return FileTreeVisibleOrder.paths(in: trees)
    }

    /// One row click. Only a plain click on a file opens it; ⌘ and ⇧
    /// clicks only change the selection.
    func activateTreeRow(_ node: WorkspaceFileNode, modifier: FileTreeClickModifier) {
        let order = modifier == .extend ? treeVisibleOrder : []
        treeSelection.click(node.url.path, modifier: modifier, visibleOrder: order)
        if modifier == .none, !node.isDirectory { open(node) }
    }

    /// ⇧↑ / ⇧↓ in the Files List.
    @discardableResult
    func extendTreeSelection(by offset: Int) -> Bool {
        treeSelection.extend(by: offset, visibleOrder: treeVisibleOrder)
    }

    /// Selected paths in visible order; selected rows that are not visible
    /// (under a since-collapsed folder) follow in path order.
    var orderedSelectedTreePaths: [String] {
        let selected = treeSelection.paths
        let visible = treeVisibleOrder.filter(selected.contains)
        let rest = selected.subtracting(visible).sorted()
        return visible + rest
    }

    /// What a context-menu action on `path` acts on: the whole selection
    /// when the row is part of it, otherwise only that row (Finder's rule).
    func treeContextTargets(for path: String) -> [String] {
        treeSelection.paths.contains(path) ? orderedSelectedTreePaths : [path]
    }

    // MARK: - Multi-row drag

    /// Called when a row drag starts: remembers the selection when the
    /// dragged row is part of a multi-row selection.
    func noteTreeDragStart(_ path: String) {
        let selected = treeSelection.paths
        treeDragSelection =
            selected.count > 1 && selected.contains(path)
            ? orderedSelectedTreePaths.map { URL(filePath: $0) } : nil
    }

    /// The URLs a tree drop acts on. One dropped URL that belongs to the
    /// remembered multi-row drag becomes that whole selection, minus the
    /// destination folder itself and anything that holds it. Consumes the
    /// remembered drag.
    func expandedTreeDrop(_ urls: [URL], into directory: URL) -> [URL] {
        defer { treeDragSelection = nil }
        guard urls.count == 1, let dropped = urls.first, let selection = treeDragSelection
        else { return urls }
        let droppedPath = dropped.standardizedFileURL.path
        guard selection.contains(where: { $0.standardizedFileURL.path == droppedPath }) else {
            return urls
        }
        let destination = directory.standardizedFileURL.path
        let movable = selection.filter { url in
            let path = url.standardizedFileURL.path
            return destination != path && !destination.hasPrefix(path + "/")
        }
        return WorkspaceFileService.topLevelWorkspaceItems(movable, roots: roots)
    }

    // MARK: - Move to Trash

    /// Whether File > Move to Trash (⌘⌫) is enabled: the Files navigator is
    /// on screen with keyboard focus and at least one row selected. The
    /// strict focus rule keeps ⌘⌫ for "delete to line start" in editors and
    /// terminals, and for Delete Link on an Ensemble board.
    var canMoveTreeSelectionToTrash: Bool {
        guard rootURL != nil, navigatorMode == .files, !isSidebarCollapsed, isFilesTreeFocused,
            pendingTrashRequest == nil
        else { return false }
        return !treeSelection.paths.isEmpty
    }

    /// Asks for confirmation before moving `paths` to the Trash.
    func requestTrash(paths: [String]) {
        let urls = WorkspaceFileService.topLevelWorkspaceItems(
            paths.map { URL(filePath: $0) }, roots: roots)
        guard !urls.isEmpty else { return }
        pendingTrashRequest = WorkspaceTrashRequest(
            urls: urls, unsavedNames: unsavedItemNames(under: urls))
    }

    /// The confirmed request. `undoManager` is the window's; Undo moves the
    /// items back when their places are still free.
    @discardableResult
    func performPendingTrash(undoManager: UndoManager?) async -> WorkspaceTrashOutcome {
        guard let request = pendingTrashRequest else { return WorkspaceTrashOutcome() }
        pendingTrashRequest = nil
        return await moveToTrash(request.urls, undoManager: undoManager)
    }

    /// Trashes without asking (the confirmed request, and Redo).
    @discardableResult
    func moveToTrash(_ urls: [URL], undoManager: UndoManager?) async -> WorkspaceTrashOutcome {
        let outcome = await WorkspaceFileService().trash(urls, roots: roots)
        let trashedPaths = outcome.items.map { $0.original.standardizedFileURL.path }
        if !trashedPaths.isEmpty {
            releaseOpenItems(under: trashedPaths)
            treeSelection.remove(itemsAt: trashedPaths)
            await refreshWorkspace()
            let count = outcome.items.count
            postStatusNotice(
                count == 1
                    ? "Moved \(outcome.items[0].original.lastPathComponent) to the Trash"
                    : "Moved \(count) items to the Trash")
            registerTrashUndo(outcome.items, undoManager: undoManager)
        }
        if let message = outcome.failureMessage {
            reportWorkspaceError(title: "Unable to Move to Trash", message: message)
        }
        return outcome
    }

    /// Undo of Move to Trash: puts the items back where their places are
    /// still free.
    @discardableResult
    func restoreTrashedItems(_ items: [WorkspaceTrashedItem]) async -> WorkspaceTrashOutcome {
        let outcome = await WorkspaceFileService().restoreFromTrash(items)
        if !outcome.items.isEmpty {
            await refreshWorkspace()
            let count = outcome.items.count
            postStatusNotice(count == 1 ? "Restored 1 item" : "Restored \(count) items")
        }
        if let message = outcome.failureMessage {
            reportWorkspaceError(title: "Unable to Put Back", message: message)
        }
        return outcome
    }

    /// Registers Undo for a finished move. The file work is async, so the
    /// Redo registration happens synchronously inside the Undo handler:
    /// a registration from a later task would land on the undo stack, and a
    /// second ⌘Z would move the items to the Trash again.
    private func registerTrashUndo(_ items: [WorkspaceTrashedItem], undoManager: UndoManager?) {
        guard let undoManager else { return }
        let originals = items.map(\.original)
        undoManager.registerUndo(withTarget: self) { session in
            undoManager.registerUndo(withTarget: session) { session in
                Task { await session.moveToTrash(originals, undoManager: undoManager) }
            }
            undoManager.setActionName("Move to Trash")
            Task { await session.restoreTrashedItems(items) }
        }
        undoManager.setActionName("Move to Trash")
    }

    /// Names of open documents with unsaved changes, and of Ensemble boards
    /// bound to a file, under any of `urls`.
    private func unsavedItemNames(under urls: [URL]) -> [String] {
        let paths = urls.map { $0.standardizedFileURL.path }
        let documents = openDocuments.filter {
            $0.isDirty && !$0.isUntitled && Self.path($0.url, isUnder: paths)
        }
        let boards = trashedEnsembleBindings(under: paths).filter(\.isDirty)
        return documents.map(\.displayName) + boards.map(\.name)
    }

    /// Open items under a trashed path: a clean document closes; a document
    /// with unsaved changes stays open as an unsaved, untitled document with
    /// the same name. A clean Ensemble board bound to a trashed file closes
    /// without saving (saving would write the file back); a board with
    /// unsaved changes stays open.
    private func releaseOpenItems(under paths: [String]) {
        for document in openDocuments
        where !document.isUntitled && Self.path(document.url, isUnder: paths) {
            if document.isDirty {
                let previousURL = document.url
                let detachedURL = document.detachFromDisk()
                if let tab = editorLayout.tab(matching: .file(previousURL)) {
                    editorLayout.updateResource(for: tab.id, to: .file(detachedURL))
                }
            } else {
                close(document)
            }
        }
        for board in trashedEnsembleBindings(under: paths) where !board.isDirty {
            closeCanvas(board.id, discarding: true)
        }
    }

    private struct EnsembleBinding {
        let id: CanvasID
        let name: String
        let isDirty: Bool
    }

    /// Open Ensemble boards bound to a `.rafuensemble` file in the primary
    /// root under one of `paths`.
    private func trashedEnsembleBindings(under paths: [String]) -> [EnsembleBinding] {
        guard let rootURL else { return [] }
        return canvas.fileBindings.compactMap { id, binding in
            let url = rootURL.appending(path: binding.relativePath)
            guard Self.path(url, isUnder: paths) else { return nil }
            return EnsembleBinding(
                id: id, name: url.lastPathComponent,
                isDirty: canvas.boards[id]?.isDirty == true)
        }
    }

    private static func path(_ url: URL, isUnder paths: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Copy path

    /// The file ⇧⌘C / ⌥⌘C copy: the Files selection while the tree has
    /// focus, else the selected file-backed document, else the Files
    /// selection. Nil disables both commands.
    var pathCopyTarget: URL? {
        let document = selectedDocument
        return PathCopier.target(
            documentURL: document?.url, documentIsUntitled: document?.isUntitled ?? false,
            treePath: selectedTreePath, treeHasFocus: isFilesTreeFocused)
    }

    func copyPathOfActiveItem(_ style: PathCopier.Style) {
        guard let url = pathCopyTarget else { return }
        copyPaths([url], style: style)
    }

    /// Writes one path per line to the general pasteboard and confirms it in
    /// the status bar.
    func copyPaths(_ urls: [URL], style: PathCopier.Style) {
        guard !urls.isEmpty else { return }
        let text = PathCopier.paths(for: urls, style: style, roots: roots)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let noun = style == .relative ? "Relative" : "Absolute"
        postStatusNotice(
            urls.count == 1 ? "Copied \(noun) Path" : "Copied \(urls.count) \(noun) Paths")
    }

    func postStatusNotice(_ text: String) {
        transientStatusNotice = TransientStatusNotice(text: text)
    }
}
