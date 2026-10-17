import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas window store")
@MainActor
struct WorkspaceCanvasStoreTests {
    @Test("Two windows detect a conflict and save a separate copy without losing the first edit")
    func conflictAndCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = CanvasPersistenceStore(directory: folder)
        let a = WorkspaceCanvasStore(persistence: disk)
        let b = WorkspaceCanvasStore(persistence: disk)
        #expect(await a.configure(root: folder))
        #expect(await b.configure(root: folder))
        let original = try #require(await a.create(title: "Task"))
        let other = try #require(await b.open(original.id))
        try original.add(title: "One", content: .note(snapshot: "first window"))
        #expect(await a.save(original.id))
        try other.add(title: "Two", content: .note(snapshot: "second window"))
        #expect(!(await b.save(other.id)))
        #expect(other.isDirty && other.errorMessage != nil)
        let copy = try #require(await b.saveCopy(other.id))
        #expect(copy.id != original.id)
        #expect(copy.cards[0].content == .note(snapshot: "second window"))
        #expect(await b.reload(original.id))
        #expect(b.boards[original.id]?.cards[0].content == .note(snapshot: "first window"))
    }

    @Test("Concurrent save requests coalesce and a workspace switch flushes the old board")
    func saveCoalescingAndWorkspaceChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = CanvasPersistenceStore(directory: folder)
        let store = WorkspaceCanvasStore(persistence: disk)
        #expect(await store.configure(root: folder))
        let board = try #require(await store.create(title: "Task"))
        try board.add(title: "One", content: .note(snapshot: "one"))
        try board.add(title: "Two", content: .file(path: "README.md"))
        async let first = store.save(board.id)
        async let second = store.save(board.id)
        #expect(await first)
        #expect(await second)
        #expect(!board.isDirty && board.revision == 2)
        try board.edit { $0.title = "Saved before switching" }
        #expect(await store.configure(root: folder.appending(path: "other")))
        #expect(store.boards.isEmpty)
        let restored = try await disk.load(
            board.id, workspace: TerminalGroupWorkspaceKey(standardizedRoot: folder))
        #expect(restored?.title == "Saved before switching")
    }
}
