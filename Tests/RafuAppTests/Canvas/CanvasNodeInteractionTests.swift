import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Canvas node interactions")
@MainActor
struct CanvasNodeInteractionTests {
    @Test("A cancelled file drop leaves the board and its error unchanged")
    func cancelledDrop() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: file)
        let (session, board) = try await fixture(root)
        let task = Task { await session.addCanvasDroppedFiles([file], to: board.id, at: .zero) }
        task.cancel()
        await task.value
        #expect(board.cards.isEmpty)
        #expect(board.errorMessage == nil)
        #expect(await session.canvas.flushAll())
    }

    @Test("A file drop creates references at board coordinates and can be undone as one edit")
    func fileDrop() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "one.swift")
        let second = root.appending(path: "two.md")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let (session, board) = try await fixture(root)
        board.setViewport(.init(scale: 2, x: 100, y: 50))
        await session.addCanvasDroppedFiles(
            [first, second], to: board.id, at: CGPoint(x: 300, y: 250))
        #expect(board.cards.map(\.content) == [.file(path: "one.swift"), .file(path: "two.md")])
        #expect(board.cards[0].rect.x == 100 && board.cards[0].rect.y == 100)
        #expect(board.cards[1].rect.x == 124 && board.cards[1].rect.y == 124)
        #expect(board.selection == Set(board.cards.map(\.id)))
        #expect(session.terminal.sessions.isEmpty)
        board.performUndo()
        #expect(board.cards.isEmpty)
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
        #expect(await session.canvas.flushAll())
    }

    @Test("A rejected outside file or directory leaves the whole dropped batch unchanged")
    func rejectedDrop() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let root = folder.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inside = root.appending(path: "inside.txt")
        let outside = folder.appending(path: "outside.txt")
        try Data("inside".utf8).write(to: inside)
        try Data("outside".utf8).write(to: outside)
        let directory = root.appending(path: "directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, board) = try await fixture(root)
        await session.addCanvasDroppedFiles([inside, outside], to: board.id, at: .zero)
        #expect(board.cards.isEmpty && board.errorMessage != nil)
        await session.addCanvasDroppedFiles([directory], to: board.id, at: .zero)
        #expect(board.cards.isEmpty)
        #expect(await session.canvas.flushAll())
    }

    @Test("Close selected file node is immediate and never deletes its source file")
    func closeNode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: file)
        let (session, board) = try await fixture(root)
        await session.addCanvasDroppedFiles([file], to: board.id, at: .zero)
        session.presentCanvasBoard(board)
        #expect(session.canCloseSelectedCanvasNodes)
        session.closeSelectedCanvasNodes()
        #expect(session.pendingCanvasRemoval == nil)
        #expect(board.cards.isEmpty)
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
        board.performUndo()
        #expect(board.cards.count == 1)
        board.selection = []
        #expect(!session.canCloseSelectedCanvasNodes)
        #expect(await session.canvas.flushAll())
    }

    @Test("Empty notes close immediately; nonempty notes and terminals require confirmation")
    func protectedNodeClose() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        try board.add(title: "Empty", content: .note(snapshot: ""))
        session.closeSelectedCanvasNodes()
        #expect(board.cards.isEmpty && session.pendingCanvasRemoval == nil)
        try board.add(title: "Note", content: .note(snapshot: "Keep this text"))
        session.closeSelectedCanvasNodes()
        #expect(board.cards.count == 1 && session.pendingCanvasRemoval == board.id)
        session.pendingCanvasRemoval = nil
        session.addCanvasStoppedTerminal(board.id)
        session.closeSelectedCanvasNodes()
        #expect(board.cards.count == 2 && session.pendingCanvasRemoval == board.id)
        #expect(session.terminal.sessions.isEmpty)
        #expect(await session.canvas.flushAll())
    }

    @Test("Close-and-remove accepts a terminal group already finalized by confirmation")
    func closeTerminalNodeDoesNotParkDeletedGroup() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        session.addCanvasStoppedTerminal(board.id)
        let card = try #require(board.cards.first)
        guard case .terminal(let groupID) = card.content else {
            Issue.record("Expected terminal card")
            return
        }
        session.canvasTerminalOwners[groupID] = board.id
        board.focus(card.id)
        session.closeCanvasTerminalCard(board.id)
        #expect(session.terminal.terminalGroup(groupID) == nil)
        #expect(board.cards.isEmpty)
        #expect(session.canvasTerminalOwners[groupID] == nil)
        #expect(session.pendingCanvasTerminalRemoval == nil)
        #expect(!session.isOpenFolderErrorPresented)
        session.canvasResources[board.id]?.stopAll()
        #expect(!session.isOpenFolderErrorPresented)
        #expect(await session.canvas.flushAll())
    }

    @Test("Removing a terminal node parks its group and clears only its presentation lease")
    func removingTerminalNodeKeepsGroupAndOtherNode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        session.addCanvasStoppedTerminal(board.id)
        session.addCanvasStoppedTerminal(board.id)
        let first = board.cards[0]
        let second = board.cards[1]
        guard case .terminal(let firstGroup) = first.content,
            case .terminal(let secondGroup) = second.content
        else {
            Issue.record("Expected terminal cards")
            return
        }
        session.canvasTerminalOwners[firstGroup] = board.id
        session.canvasTerminalOwners[secondGroup] = board.id
        board.selection = [first.id]
        session.removeCanvasCards(board.id)
        #expect(board.cards.map(\.id) == [second.id])
        #expect(session.terminal.terminalGroup(firstGroup) != nil)
        #expect(session.canvasTerminalOwners[firstGroup] == nil)
        #expect(session.canvasTerminalOwners[secondGroup] == board.id)
        #expect(!session.isOpenFolderErrorPresented)
        #expect(session.terminal.sessions.isEmpty)
        #expect(await session.canvas.flushAll())
    }

    @Test("Late Canvas resource cleanup ignores a terminal group that no longer exists")
    func lateCleanupDropsStaleTerminalOwner() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        let missingGroup = TerminalGroupID()
        session.canvasTerminalOwners[missingGroup] = board.id
        session.canvasResources[board.id]?.stopAll()
        #expect(session.canvasTerminalOwners[missingGroup] == nil)
        #expect(!session.isOpenFolderErrorPresented)
        #expect(await session.canvas.flushAll())
    }

    @Test("Canvas drop decoding accepts file payloads and rejects tabs and web URLs")
    func dropPayloads() throws {
        let file = URL(fileURLWithPath: "/tmp/canvas-file.swift")
        let data = try EditorDragPayload.file(path: file.path).encodedData()
        #expect(CanvasFileDropDecoder.privateURL(data) == file)
        #expect(CanvasFileDropDecoder.externalURL(file.dataRepresentation) == file)
        #expect(
            CanvasFileDropDecoder.privateURL(try EditorDragPayload.tab(id: "tab").encodedData())
                == nil)
        #expect(CanvasFileDropDecoder.url(for: .file(path: "relative.swift")) == nil)
        #expect(
            CanvasFileDropDecoder.externalURL(
                URL(string: "https://example.com/file")!.dataRepresentation) == nil)
        #expect(CanvasFileDropDecoder.privateURL(Data(repeating: 0, count: 16 * 1_024 + 1)) == nil)
    }

    private func fixture(_ root: URL) async throws -> (WorkspaceSession, CanvasBoardState) {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: "dev.rafu.canvas-node-tests.\(UUID())",
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: "saved-boards"))
            ))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: root.path)))
        #expect(await session.canvas.configure(root: root))
        return (session, try #require(await session.canvas.create(title: "Nodes")))
    }
}
