import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Move to Trash uses the real Trash (`FileManager.trashItem`). Every test
/// removes what it trashed, so nothing stays in the user's Trash.
@Suite("Workspace Move to Trash")
struct WorkspaceTrashServiceTests {
    @Test("Trash moves items and returns where they went")
    func trashReturnsURLs() async throws {
        try await withTemporaryDirectory { base in
            let root = WorkspaceRoot(path: base.path)
            let file = base.appending(path: "a.txt")
            try Data("a".utf8).write(to: file)

            let outcome = await WorkspaceFileService().trash([file], roots: [root])
            defer {
                for item in outcome.items { try? FileManager.default.removeItem(at: item.trashed) }
            }

            #expect(outcome.failureMessage == nil)
            #expect(outcome.items.count == 1)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let trashed = try #require(outcome.items.first?.trashed)
            #expect(FileManager.default.fileExists(atPath: trashed.path))
        }
    }

    @Test("A workspace root and items outside the roots are refused")
    func refusesRoot() async throws {
        try await withTemporaryDirectory { base in
            let rootURL = base.appending(path: "app", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let outside = base.appending(path: "outside.txt")
            try Data("o".utf8).write(to: outside)
            let root = WorkspaceRoot(path: rootURL.path)

            let outcome = await WorkspaceFileService().trash([rootURL, outside], roots: [root])

            #expect(outcome.items.isEmpty)
            #expect(FileManager.default.fileExists(atPath: rootURL.path))
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    @Test("An item under a selected folder is skipped; the folder takes it")
    func skipsDescendants() throws {
        let root = WorkspaceRoot(path: "/w")
        let folder = URL(filePath: "/w/src")
        let child = URL(filePath: "/w/src/a.swift")
        let other = URL(filePath: "/w/README.md")
        let items = WorkspaceFileService.topLevelWorkspaceItems(
            [child, folder, other, folder], roots: [root])
        #expect(items.map(\.path) == ["/w/src", "/w/README.md"])
    }

    @Test("Undo moves the item back when its place is free")
    func undoRestores() async throws {
        try await withTemporaryDirectory { base in
            let root = WorkspaceRoot(path: base.path)
            let file = base.appending(path: "keep.txt")
            try Data("keep".utf8).write(to: file)
            let service = WorkspaceFileService()

            let trashed = await service.trash([file], roots: [root])
            let restored = await service.restoreFromTrash(trashed.items)

            #expect(restored.failureMessage == nil)
            #expect(restored.items == trashed.items)
            #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        }
    }

    @Test("Undo leaves the item in the Trash when its place is taken")
    func undoRefusesOverwrite() async throws {
        try await withTemporaryDirectory { base in
            let root = WorkspaceRoot(path: base.path)
            let file = base.appending(path: "taken.txt")
            try Data("old".utf8).write(to: file)
            let service = WorkspaceFileService()
            let trashed = await service.trash([file], roots: [root])
            defer {
                for item in trashed.items { try? FileManager.default.removeItem(at: item.trashed) }
            }
            try Data("new".utf8).write(to: file)

            let restored = await service.restoreFromTrash(trashed.items)

            #expect(restored.items.isEmpty)
            #expect(restored.failureMessage != nil)
            #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        }
    }
}

@MainActor
@Suite("Move to Trash with open documents")
struct WorkspaceTrashOpenDocumentsTests {
    @Test("A clean document closes; a dirty one stays open as an unsaved document")
    func openDocuments() async throws {
        let fixture = try TrashSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let clean = try fixture.file("clean.txt")
        let dirty = try fixture.file("dirty.txt")
        session.open(fixture.node(clean))
        session.open(fixture.node(dirty))
        let dirtyDocument = try #require(session.openDocuments.first { $0.url == dirty })
        dirtyDocument.isDirty = true

        session.requestTrash(paths: [clean.path, dirty.path])
        let request = try #require(session.pendingTrashRequest)
        #expect(request.urls.count == 2)
        #expect(request.unsavedNames == ["dirty.txt"])
        let undoManager = UndoManager()
        let outcome = await session.performPendingTrash(undoManager: undoManager)
        defer { fixture.emptyTrash(outcome) }

        #expect(session.pendingTrashRequest == nil)
        #expect(!session.openDocuments.contains { $0.url == clean })
        #expect(session.openDocuments.contains { $0 === dirtyDocument })
        #expect(dirtyDocument.isUntitled)
        #expect(dirtyDocument.isDirty)
        #expect(dirtyDocument.displayName == "dirty.txt")
        #expect(dirtyDocument.url != dirty)
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        #expect(undoManager.canUndo)
    }

    @Test("Trashed rows leave the selection, and a notice confirms the move")
    func selectionAndNotice() async throws {
        let fixture = try TrashSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let first = try fixture.file("one.txt")
        let second = try fixture.file("two.txt")
        session.treeSelection.click(first.path, modifier: .none, visibleOrder: [])
        session.treeSelection.click(second.path, modifier: .toggle, visibleOrder: [])

        session.requestTrash(paths: session.orderedSelectedTreePaths)
        let outcome = await session.performPendingTrash(undoManager: nil)
        defer { fixture.emptyTrash(outcome) }

        #expect(session.selectedTreePaths.isEmpty)
        #expect(session.transientStatusNotice?.text == "Moved 2 items to the Trash")
    }

    @Test("Move to Trash needs the focused Files navigator and a selection")
    func commandAvailability() throws {
        let fixture = try TrashSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        session.selectedTreePath = fixture.base.appending(path: "x.txt").path
        #expect(!session.canMoveTreeSelectionToTrash)
        session.isFilesTreeFocused = true
        #expect(session.canMoveTreeSelectionToTrash)
        session.navigatorMode = .search
        #expect(!session.canMoveTreeSelectionToTrash)
        session.navigatorMode = .files
        session.selectedTreePath = nil
        #expect(!session.canMoveTreeSelectionToTrash)
    }

    @Test("Copy Path targets the document, and the tree while it has focus")
    func copyPathTarget() throws {
        let fixture = try TrashSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        #expect(session.pathCopyTarget == nil)
        let file = try fixture.file("a.txt")
        session.open(fixture.node(file))
        #expect(session.pathCopyTarget == file)
        let folder = fixture.base.appending(path: "folder").path
        session.treeSelection.click(folder, modifier: .toggle, visibleOrder: [])
        session.isFilesTreeFocused = true
        #expect(session.pathCopyTarget?.path == folder)
    }
}

@MainActor
private struct TrashSessionFixture {
    let session: WorkspaceSession
    let base: URL
    private let suite: String

    init() throws {
        suite = TestDefaultsSuite.name("dev.rafu.trash")
        base = FileManager.default.temporaryDirectory.appending(
            path: "rafu-trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(defaultsSuiteName: suite))
        session.descriptor = WorkspaceDescriptor(
            displayName: "trash", location: .local(LocalWorkspaceReference(path: base.path)))
    }

    func file(_ name: String) throws -> URL {
        let url = base.appending(path: name)
        try Data(name.utf8).write(to: url)
        return url
    }

    func node(_ url: URL) -> WorkspaceFileNode {
        WorkspaceFileNode(url: url, relativePath: url.lastPathComponent, isDirectory: false)
    }

    /// Removes this test's items from the user's Trash.
    func emptyTrash(_ outcome: WorkspaceTrashOutcome) {
        for item in outcome.items { try? FileManager.default.removeItem(at: item.trashed) }
    }

    func remove() {
        session.descriptor = nil
        TestDefaultsSuite.remove(suite)
        try? FileManager.default.removeItem(at: base)
    }
}
