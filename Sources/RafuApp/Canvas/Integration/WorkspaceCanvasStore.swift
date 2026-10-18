import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceCanvasStore {
    private(set) var boards: [CanvasID: CanvasBoardState] = [:]
    private(set) var library: [CanvasSummary] = []
    var libraryNotice: String?
    var isLoading = false
    /// Boards bound to a workspace `.rafuensemble` file (X5). They save to that
    /// file instead of the Application Support store. Small metadata only.
    private(set) var fileBindings: [CanvasID: CanvasEnsembleFileBinding] = [:]
    @ObservationIgnored private let persistence: CanvasPersistenceStore
    @ObservationIgnored private let files: CanvasEnsembleFileStore
    @ObservationIgnored private(set) var root: URL?
    @ObservationIgnored private(set) var workspace: TerminalGroupWorkspaceKey?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var prepareResourceSnapshot: ((inout CanvasDocument) -> Void)?
    @ObservationIgnored var onBoardHidden: ((CanvasID) -> Void)?

    init(
        persistence: CanvasPersistenceStore = .shared, files: CanvasEnsembleFileStore = .shared
    ) {
        self.persistence = persistence
        self.files = files
    }

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
        fileBindings = [:]
        library = []
        workspace = key
        root = root.standardizedFileURL
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
        fileBindings = [:]
        library = []
        workspace = nil
        root = nil
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
                result.unavailableCount == 0 ? nil : "One or more saved Ensembles are unavailable."
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
                // A restored tab may belong to a workspace `.rafuensemble` file.
                if let path = try await persistence.fileBoardPath(id, workspace: workspace) {
                    guard ticket == generation else { return nil }
                    return await openFile(atRelativePath: path, preferredID: id)?.board
                }
                throw CanvasError.unavailable
            }
            guard ticket == generation else { return nil }
            return install(document)
        } catch {
            if generation == ticket { libraryNotice = error.localizedDescription }
            return nil
        }
    }

    /// Opens the workspace `.rafuensemble` file at `relativePath` as a board
    /// bound to that file, or returns the board already bound to it. A file
    /// whose board ID is already open under another source gets a fresh ID
    /// (written back on its next save). Returns embedded images that are not
    /// in the workspace, so the caller can offer to restore them.
    func openFile(atRelativePath relativePath: String, preferredID: CanvasID? = nil) async
        -> (board: CanvasBoardState, missingEmbeddedImages: [String: Data])?
    {
        if let id = fileBindings.first(where: { $0.value.relativePath == relativePath })?.key,
            let board = boards[id]
        {
            return (board, [:])
        }
        guard let workspace, let root else { return nil }
        guard boards.count < CanvasLimits.boards else {
            libraryNotice = CanvasError.capacity.localizedDescription
            return nil
        }
        let ticket = generation
        do {
            let snapshot = try await files.read(relativePath: relativePath, root: root)
            guard ticket == generation else { return nil }
            var document = snapshot.document
            if let preferredID, boards[preferredID] == nil {
                document.id = preferredID
            } else if boards[document.id] != nil {
                document.id = CanvasID()
            }
            let board = install(document)
            fileBindings[document.id] = snapshot.binding
            try? await persistence.rememberFileBoard(
                document.id, relativePath: relativePath, workspace: workspace)
            return (board, snapshot.missingEmbeddedImages)
        } catch {
            if generation == ticket { libraryNotice = error.localizedDescription }
            return nil
        }
    }

    /// Save As: writes a snapshot of board `id` to a new workspace file and
    /// opens that file as its own bound board. The original board is kept
    /// unchanged, like "Save Copy".
    func saveAsFile(_ id: CanvasID, to url: URL) async -> CanvasBoardState? {
        guard let board = boards[id], let root, let workspace else { return nil }
        let ticket = generation
        do {
            var snapshot = try board.snapshot()
            prepareResourceSnapshot?(&snapshot)
            snapshot.id = CanvasID()
            snapshot.revision = 1
            snapshot.terminalGroups = nil
            guard
                let binding = try await files.write(
                    snapshot, to: url, root: root, embedImagesFrom: nil)
            else { throw CanvasError.invalidPath }
            guard ticket == generation else { return nil }
            fileBindings[snapshot.id] = binding
            let saved = install(snapshot)
            try? await persistence.rememberFileBoard(
                snapshot.id, relativePath: binding.relativePath, workspace: workspace)
            return saved
        } catch {
            board.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Export: writes a portable snapshot of board `id` anywhere the user
    /// chose, embedding small workspace images. Nothing is bound or opened.
    func exportFile(_ id: CanvasID, to url: URL) async -> Bool {
        guard let board = boards[id], let root else { return false }
        do {
            var snapshot = try board.snapshot()
            prepareResourceSnapshot?(&snapshot)
            snapshot.terminalGroups = nil
            _ = try await files.write(snapshot, to: url, root: nil, embedImagesFrom: root)
            return true
        } catch {
            board.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Writes embedded images that a file carried to their workspace paths.
    func restoreEmbeddedImages(_ images: [String: Data]) async throws -> Int {
        guard let root else { return 0 }
        return try await files.restore(images: images, root: root)
    }

    func reload(_ id: CanvasID) async -> Bool {
        guard let workspace else { return false }
        if let pending = boards[id]?.saveTask {
            pending.cancel()
            _ = await pending.value
        }
        let ticket = generation
        do {
            var document: CanvasDocument
            if let binding = fileBindings[id], let root {
                let snapshot = try await files.read(relativePath: binding.relativePath, root: root)
                document = snapshot.document
                document.id = id
                guard ticket == generation else { return false }
                fileBindings[id] = snapshot.binding
            } else {
                guard let saved = try await persistence.load(id, workspace: workspace) else {
                    throw CanvasError.unavailable
                }
                document = saved
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
        fileBindings[id] = nil
    }

    func save(_ id: CanvasID) async -> Bool {
        guard let board = boards[id] else { return true }
        if let pending = board.saveTask { return await pending.value }
        board.refreshResources(prepareResourceSnapshot)
        guard board.isDirty else { return true }
        let task = Task(name: "Flush Ensemble changes") { [weak self, weak board] in
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
        board.revokeSessionLinks = { [weak board] ids in
            guard let board else { return }
            for id in ids { CanvasLiveBridge.shared.disable(id, in: board) }
        }
        board.requestSave = { [weak self, weak board] in
            guard let self, let board, self.boards[board.id] === board, board.saveTask == nil else {
                return
            }
            board.saveTask = Task(name: "Save Ensemble changes") { [weak self, weak board] in
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
                let saved: CanvasDocument
                if let binding = fileBindings[board.id], let root {
                    // The file format never writes terminal layouts; the board
                    // keeps them in memory so its resources stay stable.
                    let result = try await files.save(
                        snapshot, expectedRevision: board.revision, binding: binding, root: root)
                    guard boards[board.id] === board else { return false }
                    fileBindings[board.id] = result.binding
                    saved = result.document
                } else {
                    saved = try await persistence.save(
                        snapshot, expectedRevision: board.revision, workspace: workspace)
                }
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
                ? CanvasSummary(
                    id: board.id, title: board.title, revision: board.revision,
                    cardCount: board.cards.count, modified: Date()) : item
        }
        return true
    }
}
