import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble file-bound boards")
@MainActor
struct CanvasEnsembleFileStoreTests {
    private static func workspace() throws -> (root: URL, support: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = base.appending(path: "repo")
        let support = base.appending(path: "support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, support)
    }

    @Test("Save As writes a workspace file that reopens, saves back, and detects outside edits")
    func saveAsReopenAndConflict() async throws {
        let (root, support) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = WorkspaceCanvasStore(persistence: CanvasPersistenceStore(directory: support))
        #expect(await store.configure(root: root))
        let original = try #require(await store.create(title: "Plan"))
        try original.add(
            title: "Box", content: .shape(CanvasShape(kind: .rectangle, label: "Start")))
        let url = root.appending(path: "Plan.rafuensemble")
        let bound = try #require(await store.saveAsFile(original.id, to: url))
        #expect(bound.id != original.id)
        #expect(store.fileBindings[bound.id]?.relativePath == "Plan.rafuensemble")
        let file = try CanvasEnsembleFile.decode(Data(contentsOf: url))
        #expect(file.board.revision == 1)
        #expect(file.cards.count == 1)

        try bound.add(title: "Words", content: .text(CanvasText(text: "Hello")))
        #expect(await store.save(bound.id))
        #expect(bound.revision == 2)
        #expect(try CanvasEnsembleFile.decode(Data(contentsOf: url)).cards.count == 2)

        // An outside edit that keeps the revision is still a conflict.
        var outside = try CanvasEnsembleFile.decode(Data(contentsOf: url))
        outside.cards.removeLast()
        try outside.encoded().write(to: url)
        try bound.add(title: "More", content: .text(CanvasText(text: "Again")))
        #expect(!(await store.save(bound.id)))
        #expect(bound.errorMessage != nil)
        #expect(await store.reload(bound.id))
        #expect(store.boards[bound.id]?.cards.count == 1)
    }

    @Test("Opening the same file twice returns one board, and a restored tab finds its file")
    func openByPathAndRestore() async throws {
        let (root, support) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var document = CanvasDocument(title: "Shared")
        document.revision = 5
        document.cards = [CanvasCard(title: "Flow", content: .mermaid(source: "graph TD\nA-->B"))]
        try FileManager.default.createDirectory(
            at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try CanvasEnsembleFile(document: document).encoded()
            .write(to: root.appending(path: "docs/shared.rafuensemble"))

        let disk = CanvasPersistenceStore(directory: support)
        let store = WorkspaceCanvasStore(persistence: disk)
        #expect(await store.configure(root: root))
        let first = try #require(await store.openFile(atRelativePath: "docs/shared.rafuensemble"))
        let again = try #require(await store.openFile(atRelativePath: "docs/shared.rafuensemble"))
        #expect(first.board === again.board)
        #expect(first.board.id == document.id)
        #expect(first.board.revision == 5)

        let restored = WorkspaceCanvasStore(persistence: disk)
        #expect(await restored.configure(root: root))
        let board = try #require(await restored.open(document.id))
        #expect(board.cards.first?.content == .mermaid(source: "graph TD\nA-->B"))
        #expect(restored.fileBindings[board.id]?.relativePath == "docs/shared.rafuensemble")
    }

    @Test("Files outside the workspace or with another extension are refused")
    func pathBounds() async throws {
        let (root, support) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = WorkspaceCanvasStore(persistence: CanvasPersistenceStore(directory: support))
        #expect(await store.configure(root: root))
        #expect(await store.openFile(atRelativePath: "../outside.rafuensemble") == nil)
        try Data("{}".utf8).write(to: root.appending(path: "notes.json"))
        #expect(await store.openFile(atRelativePath: "notes.json") == nil)
        #expect(throws: CanvasError.invalidPath) {
            try CanvasEnsembleFileStore.relativePath(
                forNewFile: URL(fileURLWithPath: "/tmp/elsewhere.rafuensemble"), root: root)
        }
    }

    @Test("Embedded images restore only to missing workspace paths")
    func restoreImages() async throws {
        let (root, support) = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = WorkspaceCanvasStore(persistence: CanvasPersistenceStore(directory: support))
        #expect(await store.configure(root: root))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7])
        try Data("keep".utf8).write(to: root.appending(path: "kept.png"))
        let written = try await store.restoreEmbeddedImages([
            "img/new.png": png, "kept.png": png, "bad.png": Data("text".utf8),
        ])
        #expect(written == 1)
        #expect(try Data(contentsOf: root.appending(path: "img/new.png")) == png)
        #expect(try Data(contentsOf: root.appending(path: "kept.png")) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bad.png").path))
    }

    @Test("A file name comes from the board title without path separators")
    func fileName() {
        #expect(WorkspaceSession.ensembleFileName(for: "Plan / v2") == "Plan - v2.rafuensemble")
        #expect(WorkspaceSession.ensembleFileName(for: "   ") == "Ensemble.rafuensemble")
    }
}
