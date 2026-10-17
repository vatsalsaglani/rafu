import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceCanvasStore {
    private(set) var boards: [CanvasID: CanvasBoardState] = [:]
    private(set) var library: [CanvasSummary] = []
    var libraryNotice: String?
    var isLoading = false
    @ObservationIgnored private let persistence: CanvasPersistenceStore
    @ObservationIgnored private(set) var workspace: TerminalGroupWorkspaceKey?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var prepareResourceSnapshot: ((inout CanvasDocument) -> Void)?
    @ObservationIgnored var onBoardHidden: ((CanvasID) -> Void)?

    init(persistence: CanvasPersistenceStore = .shared) { self.persistence = persistence }

    var hasPendingWrites: Bool {
        boards.values.contains { $0.isDirty || $0.isSaving || $0.saveTask != nil }
    }
    var savedIDs: [CanvasID] { boards.values.filter { $0.revision > 0 }.map(\.id) }

    func configure(root: URL) async -> Bool {
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        if workspace == key { return true }
        guard await flushAll() else { return false }
        for id in boards.keys { onBoardHidden?(id) }
        boards = [:]
        library = []
        workspace = key
        generation = UUID()
        await refreshLibrary()
        return true
    }

    func refreshResourceSnapshots() {
        for board in boards.values {
            board.refreshResources(prepareResourceSnapshot)
            if board.isDirty { board.requestSave?() }
        }
    }

    func clearAfterWorkspaceFlush() {
        guard !hasPendingWrites else { return }
        for board in boards.values {
            board.requestSave = nil
            onBoardHidden?(board.id)
        }
        boards = [:]
        library = []
        workspace = nil
        generation = UUID()
    }

    func refreshLibrary() async {
        guard let workspace else { return }
        let ticket = generation
        isLoading = true
        defer { if generation == ticket { isLoading = false } }
        do {
            let result = try await persistence.list(workspace: workspace)
            guard generation == ticket else { return }
            library = result.boards
            libraryNotice =
                result.unavailableCount == 0 ? nil : "One or more saved Canvases are unavailable."
        } catch { if generation == ticket { libraryNotice = error.localizedDescription } }
    }

    func create(title: String, copying original: CanvasDocument? = nil) async -> CanvasBoardState? {
        guard let workspace else { return nil }
        guard boards.count < CanvasLimits.boards else {
            libraryNotice = CanvasError.capacity.localizedDescription
            return nil
        }
        let ticket = generation
        do {
            var document = original ?? CanvasDocument(title: title)
            document.id = CanvasID()
            document.title = title
            document.revision = 0
            let saved = try await persistence.save(
                document, expectedRevision: 0, workspace: workspace)
            guard ticket == generation else { return nil }
            let board = install(saved)
            await refreshLibrary()
            return board
        } catch {
            libraryNotice = error.localizedDescription
            return nil
        }
    }

    func open(_ id: CanvasID) async -> CanvasBoardState? {
        if let board = boards[id] { return board }
        guard let workspace else { return nil }
        guard boards.count < CanvasLimits.boards else {
            libraryNotice = CanvasError.capacity.localizedDescription
            return nil
        }
        let ticket = generation
        do {
            guard let document = try await persistence.load(id, workspace: workspace) else {
                throw CanvasError.unavailable
            }
            guard ticket == generation else { return nil }
            return install(document)
        } catch {
            if generation == ticket { libraryNotice = error.localizedDescription }
            return nil
        }
    }

    func reload(_ id: CanvasID) async -> Bool {
        guard let workspace else { return false }
        if let pending = boards[id]?.saveTask {
            pending.cancel()
            _ = await pending.value
        }
        let ticket = generation
        do {
            guard let document = try await persistence.load(id, workspace: workspace) else {
                throw CanvasError.unavailable
            }
            guard ticket == generation else { return false }
            onBoardHidden?(id)
            _ = install(document)
            return true
        } catch {
            boards[id]?.errorMessage = error.localizedDescription
            return false
        }
    }

    func saveCopy(_ id: CanvasID) async -> CanvasBoardState? {
        guard let board = boards[id] else { return nil }
        do {
            var snapshot = try board.snapshot()
            prepareResourceSnapshot?(&snapshot)
            return await create(
                title: String(board.title.prefix(100)) + " Copy", copying: snapshot)
        } catch {
            board.errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteSaved(_ summary: CanvasSummary) async -> Bool {
        guard let workspace, boards[summary.id] == nil else { return false }
        do {
            try await persistence.delete(
                summary.id, expectedRevision: summary.revision, workspace: workspace)
            await refreshLibrary()
            return true
        } catch {
            libraryNotice = error.localizedDescription
            return false
        }
    }

    func forgetClosed(_ id: CanvasID) {
        onBoardHidden?(id)
        boards[id] = nil
    }

    func save(_ id: CanvasID) async -> Bool {
        guard let board = boards[id] else { return true }
        if let pending = board.saveTask { return await pending.value }
        board.refreshResources(prepareResourceSnapshot)
        guard board.isDirty else { return true }
        let task = Task(name: "Flush Canvas changes") { [weak self, weak board] in
            guard let self, let board else { return false }
            let result = await self.writeUntilClean(board)
            board.saveTask = nil
            return result
        }
        board.saveTask = task
        return await task.value
    }

    func flushAll() async -> Bool {
        for id in Array(boards.keys) {
            guard await save(id) else { return false }
        }
        return true
    }

    private func install(_ document: CanvasDocument) -> CanvasBoardState {
        boards[document.id]?.requestSave = nil
        let board = CanvasBoardState(document: document)
        board.requestSave = { [weak self, weak board] in
            guard let self, let board, self.boards[board.id] === board, board.saveTask == nil else {
                return
            }
            board.saveTask = Task(name: "Save Canvas changes") { [weak self, weak board] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let board else { return false }
                let result = await self.writeUntilClean(board)
                board.saveTask = nil
                return result
            }
        }
        boards[document.id] = board
        return board
    }

    private func writeUntilClean(_ board: CanvasBoardState) async -> Bool {
        guard let workspace else { return !board.isDirty }
        // Each repeat consumes edits that arrived during a real save. There is
        // no polling timer and no detached process or unbounded snapshot queue.
        while board.isDirty {
            guard boards[board.id] === board, !Task.isCancelled else { return false }
            let stamp = board.changeStamp
            do {
                var snapshot = try board.snapshot()
                prepareResourceSnapshot?(&snapshot)
                board.isSaving = true
                let saved = try await persistence.save(
                    snapshot, expectedRevision: board.revision, workspace: workspace)
                board.acceptSaved(saved, stamp: stamp)
                board.errorMessage = nil
            } catch {
                board.isSaving = false
                board.errorMessage = error.localizedDescription
                return false
            }
        }
        library = library.map { item in
            item.id == board.id
                ? CanvasSummary(id: board.id, title: board.title, revision: board.revision) : item
        }
        return true
    }
}
