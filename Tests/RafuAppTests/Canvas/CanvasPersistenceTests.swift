import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Canvas atomic persistence")
struct CanvasPersistenceTests {
    @Test("Canvas records use the selected app variant state root")
    func appVariantRoot() {
        for identity in [RafuAppIdentity.release, .lightning] {
            #expect(
                CanvasPersistenceStore.defaultDirectory(identity: identity)
                    == identity.applicationSupportRoot().appending(
                        path: "Canvases", directoryHint: .isDirectory))
        }
        #expect(
            CanvasPersistenceStore.defaultDirectory(identity: .release)
                != CanvasPersistenceStore.defaultDirectory(identity: .lightning))
    }

    @Test("Windows and store instances detect stale writes and keep the winning note")
    func expectedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let a = CanvasPersistenceStore(directory: root)
        let b = CanvasPersistenceStore(directory: root)
        var document = CanvasDocument(title: "Checkout")
        document.cards = [.init(title: "Note", content: .note(snapshot: "original"))]
        let saved = try await a.save(document, expectedRevision: 0, workspace: key)
        #expect(saved.revision == 1)
        var edit = saved
        edit.cards[0].content = .note(snapshot: "winning edit")
        let winner = try await b.save(edit, expectedRevision: 1, workspace: key)
        #expect(winner.revision == 2)
        await #expect(throws: CanvasError.conflict) {
            try await a.save(saved, expectedRevision: 1, workspace: key)
        }
        let restored = try await a.load(document.id, workspace: key)
        #expect(restored == winner)
        let library = try await b.list(workspace: key)
        #expect(library.boards.map(\.id) == [document.id])
        await #expect(throws: CanvasError.conflict) {
            try await a.delete(document.id, expectedRevision: 1, workspace: key)
        }
        try await a.delete(document.id, expectedRevision: 2, workspace: key)
        #expect(try await a.load(document.id, workspace: key) == nil)
    }

    @Test("Corrupt records do not discard valid boards and each workspace is isolated")
    func corruptionAndWorkspaceIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root.appending(path: "one"))
        let other = TerminalGroupWorkspaceKey(standardizedRoot: root.appending(path: "two"))
        let store = CanvasPersistenceStore(directory: root)
        let document = try await store.save(
            CanvasDocument(title: "Good"), expectedRevision: 0, workspace: key)
        let folder = root.appending(path: String(key.rawValue.dropFirst(7)))
        try Data("not JSON".utf8).write(to: folder.appending(path: UUID().uuidString + ".json"))
        let library = try await store.list(workspace: key)
        #expect(library.boards.map(\.id) == [document.id])
        #expect(library.unavailableCount == 1)
        #expect(try await store.list(workspace: other).boards.isEmpty)
    }

    @Test("Board capacity and payload size are enforced before writing")
    func capacity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let store = CanvasPersistenceStore(directory: root)
        for index in 0..<CanvasLimits.boards {
            _ = try await store.save(
                CanvasDocument(title: "Board \(index)"), expectedRevision: 0, workspace: key)
        }
        await #expect(throws: CanvasError.capacity) {
            try await store.save(
                CanvasDocument(title: "Overflow"), expectedRevision: 0, workspace: key)
        }
        var large = CanvasDocument(title: "Large")
        large.cards = (0..<40).map { index in
            CanvasCard(
                title: "Note \(index)",
                content: .note(snapshot: String(repeating: "x", count: CanvasLimits.noteBytes)))
        }
        let other = TerminalGroupWorkspaceKey(standardizedRoot: root.appending(path: "other"))
        await #expect(throws: CanvasError.invalidDocument) {
            try await store.save(large, expectedRevision: 0, workspace: other)
        }
        #expect(try await store.list(workspace: other).boards.isEmpty)
    }
}
