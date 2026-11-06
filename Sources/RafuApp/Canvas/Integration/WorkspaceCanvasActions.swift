import AppKit
import RafuCore
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum CanvasDialog: Identifiable {
    case newBoard
    case library
    case renameBoard(CanvasID)
    case renameCard(CanvasID, CanvasCardID)
    case web(CanvasID)
    case connection(CanvasID, CanvasCardID, CanvasCardID?)
    case connectionLabel(CanvasID, UUID)
    case reload(CanvasID)
    case shortcuts

    var id: String {
        switch self {
        case .newBoard: "new"
        case .library: "library"
        case .renameBoard(let id): "rename-\(id.rawValue)"
        case .renameCard(let board, let card): "rename-\(board.rawValue)-\(card.rawValue)"
        case .web(let id): "web-\(id.rawValue)"
        case .connection(let id, let a, let b):
            "connect-\(id.rawValue)-\(a.rawValue)-\(b?.rawValue.uuidString ?? "choose")"
        case .connectionLabel(let id, let edge): "label-\(id.rawValue)-\(edge)"
        case .reload(let id): "reload-\(id.rawValue)"
        case .shortcuts: "shortcuts"
        }
    }
}

extension WorkspaceSession {
    var selectedCanvasID: CanvasID? {
        guard selectedAuxiliaryTab == nil,
            let group = editorLayout.group(id: editorLayout.focusedGroupID),
            let tabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == tabID }),
            case .canvas(let id) = tab.resource
        else { return nil }
        return id
    }

    var selectedCanvas: CanvasBoardState? {
        selectedCanvasID.flatMap { canvas.boards[$0] }
    }

    func requestNewCanvas() {
        guard rootURL != nil, !isTerminalGroupModalInputBlocked else { return }
        canvasDialog = .newBoard
    }

    func requestCanvasLibrary() {
        guard rootURL != nil, !isTerminalGroupModalInputBlocked else { return }
        canvasDialog = .library
    }

    func prepareCanvasLibrary() async {
        guard let rootURL else { return }
        if await canvas.configure(root: rootURL) { await canvas.refreshLibrary() }
    }

    func createCanvas(named title: String) async -> Bool {
        guard let rootURL, CanvasDocument.validTitle(title),
            await canvas.configure(root: rootURL),
            let board = await canvas.create(title: title),
            self.rootURL == rootURL
        else { return false }
        presentCanvasBoard(board)
        return true
    }

    func openCanvas(_ id: CanvasID) async {
        guard let rootURL, await canvas.configure(root: rootURL),
            let board = await canvas.open(id), self.rootURL == rootURL
        else { return }
        restoreCanvasTerminalReferences(board)
        presentCanvasBoard(board)
    }

    func presentCanvasBoard(_ board: CanvasBoardState) {
        installCanvasResources(for: board)
        suspendAuxiliarySelection()
        for groupID in editorLayout.groupIDs {
            if let tab = editorLayout.group(id: groupID)?.tabs.first(where: {
                $0.resource == .canvas(board.id)
            }) {
                selectEditorTab(tab.id, in: groupID)
                return
            }
        }
        let tab = EditorTabState(resource: .canvas(board.id))
        let groupID = editorLayout.focusedGroupID
        editorLayout.insert(tab, in: groupID)
        selectEditorTab(tab.id, in: groupID)
    }

    func saveCanvas(_ id: CanvasID) {
        Task(name: "Save requested Ensemble") { [weak self] in
            guard let self else { return }
            _ = await canvas.save(id)
            scheduleCanvasWorkspaceSave()
        }
    }

    func revealCanvasSaveFailure() {
        guard
            let board = canvas.boards.values.first(where: {
                $0.isDirty && $0.saveFailureMessage != nil
            })
        else { return }
        presentCanvasBoard(board)
        _ = WorkspaceWindowRegistry.shared.focus(session: self)
    }

    func saveCanvasCopy(_ id: CanvasID) {
        Task(name: "Save Ensemble copy") { [weak self] in
            guard let self else { return }
            guard let board = await canvas.saveCopy(id) else {
                canvas.boards[id]?.saveFailureMessage =
                    canvas.libraryNotice ?? "The Ensemble copy could not be saved."
                return
            }
            presentCanvasBoard(board)
        }
    }

    func requestCanvasReload(_ id: CanvasID) { canvasDialog = .reload(id) }

    func reloadCanvas(_ id: CanvasID) async -> Bool {
        guard await canvas.reload(id), let board = canvas.boards[id] else { return false }
        canvasResources[id]?.stopAll()
        canvasResources[id] = nil
        restoreCanvasTerminalReferences(board)
        presentCanvasBoard(board)
        return true
    }

    @discardableResult
    func closeCanvas(_ id: CanvasID, discarding: Bool = false) -> Task<Void, Never> {
        Task(name: "Close Ensemble") { [weak self] in
            guard let self, let closing = canvas.boards[id] else { return }
            if !discarding {
                guard await canvas.save(id) else {
                    revealCanvasSaveFailure()
                    return
                }
            }
            guard canvas.boards[id] === closing else { return }
            let wasSelected = selectedCanvasID == id
            canvasResources[id]?.stopAll()
            canvasResources[id] = nil
            canvas.forgetClosed(id)
            let tabs = editorLayout.groupIDs.flatMap { editorLayout.group(id: $0)?.tabs ?? [] }
                .filter { $0.resource == .canvas(id) }
            for tab in tabs { _ = editorLayout.closeTab(tab.id) }
            if wasSelected { selectCanvasNeighbour() }
            scheduleCanvasWorkspaceSave()
        }
    }

    private func selectCanvasNeighbour() {
        guard let group = editorLayout.group(id: editorLayout.focusedGroupID),
            let tab = group.selectedTabID
        else {
            selectedDocumentID = nil
            return
        }
        selectEditorTab(tab, in: group.id)
    }

    /// Writes a board's focus time to the attention sidecar (hidden, app in the
    /// background). Coarse boundaries only; see `CanvasBoardState.attentionScores`.
    func flushCanvasAttention(_ board: CanvasBoardState) {
        Task(name: "Save Ensemble attention") { [canvas] in await canvas.flushAttention(board) }
    }

    func performCanvasEdit(_ board: CanvasBoardState, _ operation: () throws -> Void) {
        do { try operation() } catch { board.showNotice(error.localizedDescription) }
    }

    func addCanvasNote(_ id: CanvasID) {
        guard let board = canvas.boards[id] else { return }
        performCanvasEdit(board) {
            try board.add(title: "Note \(board.cards.count + 1)", content: .note(snapshot: ""))
        }
    }

    func requestCanvasConnection(_ id: CanvasID) {
        guard let board = canvas.boards[id] else { return }
        let selected = board.cards.filter { board.selection.contains($0.id) }
        guard selected.count == 2 else { return }
        // The keyboard and VoiceOver path: the Connect sheet, prefilled.
        canvasDialog = .connection(id, selected[0].id, selected[1].id)
    }

    /// Duplicate puts a copy 24 pt down and right of the original. A terminal
    /// copy is a new stopped terminal; nothing starts. A note copy carries the
    /// note's current text.
    func duplicateCanvasCard(_ boardID: CanvasID, _ cardID: CanvasCardID) {
        guard let board = canvas.boards[boardID], board.cards.count < CanvasLimits.cards,
            let original = board.cards.first(where: { $0.id == cardID })
        else { return }
        var rect = original.rect
        rect.x = min(50_000, rect.x + 24)
        rect.y = min(50_000, rect.y + 24)
        let title = String("\(original.title) Copy".prefix(120))
        if case .terminal = original.content {
            let before = board.cards.count
            addCanvasStoppedTerminal(boardID)
            guard board.cards.count == before + 1, let created = board.cards.last else { return }
            performCanvasEdit(board) {
                try board.edit { value in
                    guard let index = value.cards.firstIndex(where: { $0.id == created.id })
                    else { return }
                    value.cards[index].rect = rect
                    value.cards[index].title = title
                }
            }
            return
        }
        var content = original.content
        if case .note = original.content,
            let current = (try? board.snapshot())?.cards.first(where: { $0.id == cardID })
        {
            content = current.content
        }
        let copy = CanvasCard(title: title, rect: rect, content: content)
        performCanvasEdit(board) {
            try CanvasMotion.animateThrowing(RafuMotion.nodeCreate) {
                try board.edit { $0.cards.append(copy) }
            }
            board.select([copy.id])
        }
    }

    func connectCanvasCards(boardID: CanvasID, from: CanvasCardID, to: CanvasCardID) {
        guard let board = canvas.boards[boardID], from != to,
            let source = board.cards.first(where: { $0.id == from }),
            let target = board.cards.first(where: { $0.id == to })
        else { return }
        let behavior: CanvasConnectionBehavior
        if case .terminal = source.content, case .terminal = target.content {
            behavior = .session
        } else {
            behavior = .related
        }
        // An identical link is not created twice (review 7.5, invalid targets).
        guard !board.hasConnection(from: from, to: to) else { return }
        // A new message link starts Paused: no message passes until the user
        // chooses Resume (review 7.5, step 5a).
        performCanvasEdit(board) {
            try board.addConnection(
                from: from, to: to,
                label: CanvasConnection.placeholderLabel(for: behavior), behavior: behavior)
        }
    }

    func requestCanvasCardRemoval(_ id: CanvasID) {
        guard let board = canvas.boards[id], !board.selection.isEmpty else { return }
        pendingCanvasRemoval = id
    }

    func removeCanvasCards(_ id: CanvasID) {
        guard let board = canvas.boards[id] else { return }
        let selected = board.selection
        let groups = board.cards.compactMap { card -> TerminalGroupID? in
            guard selected.contains(card.id), case .terminal(let id) = card.content else {
                return nil
            }
            return id
        }
        do {
            // Remove the node before parking its group so a late native focus
            // callback cannot find a card that is already being removed.
            try board.removeSelection()
        } catch {
            board.showNotice(error.localizedDescription)
            return
        }
        canvasResources[id]?.stop(cards: selected)
        for groupID in groups
        where canvasTerminalOwners[groupID] == nil || canvasTerminalOwners[groupID] == id {
            canvasTerminalOwners[groupID] = nil
            // Close-and-remove finalizes the group before it removes the card.
            // The remaining node reference is valid cleanup, not a park request.
            guard terminal.terminalGroup(groupID) != nil else { continue }
            hideTerminalGroup(groupID)
        }
        pendingCanvasRemoval = nil
    }

    var canCloseSelectedCanvasNodes: Bool {
        selectedCanvas?.selection.isEmpty == false && !isTerminalGroupModalInputBlocked
    }

    func closeSelectedCanvasNodes() {
        guard canCloseSelectedCanvasNodes, let board = selectedCanvas else { return }
        guard let snapshot = try? board.snapshot() else {
            requestCanvasCardRemoval(board.id)
            return
        }
        let needsConfirmation = snapshot.cards.contains { card in
            guard board.selection.contains(card.id) else { return false }
            switch card.content {
            case .terminal: return true
            case .note(let text): return !text.isEmpty
            default: return false
            }
        }
        if needsConfirmation {
            requestCanvasCardRemoval(board.id)
        } else {
            removeCanvasCards(board.id)
        }
    }

    /// A drop adds references to workspace files. Images from outside the
    /// workspace are copied in first, after the user's consent (or at once
    /// when this workspace says "always copy"); any other outside file
    /// refuses the batch with a notice. Validation is off-main and the edit
    /// is one transaction, so a rejected batch never leaves a partly added
    /// board. Every exit clears the board's drop preview.
    func addCanvasDroppedFiles(
        _ urls: [URL], to id: CanvasID, at location: CGPoint,
        preferences: CanvasAssetImportPreferences = CanvasAssetImportPreferences()
    ) async {
        canvas.boards[id]?.clearDropPreview()
        guard let root = rootURL, let board = canvas.boards[id], !urls.isEmpty else { return }
        guard urls.count <= CanvasLimits.cards - board.cards.count else {
            board.showNotice(CanvasError.capacity.localizedDescription)
            return
        }
        do {
            let plan = try await Self.canvasDropPlan(urls, root: root)
            guard !Task.isCancelled, rootURL == root, canvas.boards[id] === board else { return }
            guard plan.refused.isEmpty else {
                board.showNotice(CanvasAssetImportPlan.refusalMessage(for: plan.refused))
                return
            }
            guard plan.externalImages.isEmpty else {
                let entry = preferences.entry(forRootPath: root.path)
                let request = CanvasAssetImportRequest(
                    boardID: id, plan: plan, location: location,
                    folder: CanvasAssetImporter.folder(
                        parent: entry.ensembleAssetFolder, boardTitle: board.title))
                if entry.alwaysCopy {
                    await importCanvasAssets(request)
                } else {
                    board.pendingAssetImport = request
                }
                return
            }
            try placeCanvasDroppedFiles(plan.insidePaths, on: board, at: location)
        } catch is CancellationError {
            return
        } catch {
            guard rootURL == root, canvas.boards[id] === board else { return }
            board.showNotice(error.localizedDescription)
        }
    }

    /// "Copy" in the consent sheet. `alwaysCopy` remembers the choice for
    /// this workspace only.
    func confirmCanvasAssetImport(
        _ request: CanvasAssetImportRequest, alwaysCopy: Bool,
        preferences: CanvasAssetImportPreferences = CanvasAssetImportPreferences()
    ) async {
        guard let board = canvas.boards[request.boardID],
            board.pendingAssetImport?.id == request.id
        else { return }
        board.pendingAssetImport = nil
        if alwaysCopy, let root = rootURL {
            preferences.setAlwaysCopy(true, forRootPath: root.path)
        }
        await importCanvasAssets(request)
    }

    /// "Cancel" in the consent sheet: nothing is copied or added.
    func cancelCanvasAssetImport(_ request: CanvasAssetImportRequest) {
        guard let board = canvas.boards[request.boardID],
            board.pendingAssetImport?.id == request.id
        else { return }
        board.pendingAssetImport = nil
    }

    /// Copies the request's external images into the workspace, then adds
    /// the whole batch in drop order as one undoable edit.
    private func importCanvasAssets(_ request: CanvasAssetImportRequest) async {
        guard let root = rootURL, let board = canvas.boards[request.boardID] else { return }
        let id = request.boardID
        guard request.plan.items.count <= CanvasLimits.cards - board.cards.count else {
            board.showNotice(CanvasError.capacity.localizedDescription)
            return
        }
        do {
            let copied = try await CanvasAssetImporter.copy(
                request.plan.externalImages, into: request.folder, root: root)
            guard rootURL == root, canvas.boards[id] === board else { return }
            var next = copied.makeIterator()
            let paths = request.plan.items.compactMap { item -> String? in
                switch item {
                case .inside(let path): path
                case .externalImage: next.next()
                }
            }
            do {
                try placeCanvasDroppedFiles(paths, on: board, at: request.location)
            } catch {
                // The board refused the cards after the copy: remove the
                // copies so no file stays behind without a card.
                await CanvasAssetImporter.removeCopies(copied, root: root)
                throw error
            }
            let folderURL = root.appending(path: request.folder)
            let copiedURLs = copied.map { root.appending(path: $0) }
            let noun = copied.count == 1 ? "1 image" : "\(copied.count) images"
            board.showNotice(
                "Copied \(noun) into \(request.folder).", tone: .info,
                action: CanvasBoardNotice.Action(title: "Show in Finder") {
                    let existing = copiedURLs.filter {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    if existing.isEmpty {
                        NSWorkspace.shared.open(folderURL)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting(existing)
                    }
                })
        } catch is CancellationError {
            return
        } catch {
            guard rootURL == root, canvas.boards[id] === board else { return }
            board.showNotice(error.localizedDescription)
        }
    }

    /// Adds one card per workspace-relative path as one edit, then selects
    /// them. One file is centred on the drop point, or on the nearest free
    /// spot when that would cover a card, exactly where its hover ghost was
    /// (`CanvasBoardDropGeometry.freeRect`). A batch cascades
    /// down and right from the drop point.
    private func placeCanvasDroppedFiles(
        _ paths: [String], on board: CanvasBoardState, at location: CGPoint
    ) throws {
        guard !paths.isEmpty else { return }
        let point = CanvasBoardDropGeometry.boardPoint(location, viewport: board.viewport)
        let obstacles = CanvasBoardDropGeometry.obstacles(in: board.cards)
        let cards = paths.enumerated().map { index, path in
            let content = CanvasDroppedFileKind.content(forRelativePath: path)
            let rect: CanvasRect
            if paths.count == 1 {
                rect = CanvasBoardDropGeometry.freeRect(
                    for: content, centeredAt: point, avoiding: obstacles)
            } else {
                rect = CanvasRect(
                    x: min(50_000, max(-50_000, point.x + Double(index) * 24)),
                    y: min(50_000, max(-50_000, point.y + Double(index) * 24)))
            }
            return CanvasCard(
                title: String(URL(fileURLWithPath: path).lastPathComponent.prefix(120)),
                rect: rect, content: content)
        }
        try board.edit { document in
            guard document.cards.count + cards.count <= CanvasLimits.cards else {
                throw CanvasError.capacity
            }
            document.cards.append(contentsOf: cards)
        }
        board.backToBoard()
        board.selection = Set(cards.map(\.id))
    }

    @concurrent
    private static func canvasDropPlan(_ urls: [URL], root: URL) async throws
        -> CanvasAssetImportPlan
    {
        try Task.checkCancellation()
        return try CanvasAssetImportPlan.resolve(urls: urls, root: root)
    }

    func chooseCanvasFile(_ id: CanvasID, imageOnly: Bool) {
        guard let rootURL, let board = canvas.boards[id] else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        panel.prompt = "Add Card"
        if imageOnly { panel.allowedContentTypes = [.image] }
        panel.begin { [weak self, weak board] response in
            guard response == .OK, let self, let board, let url = panel.url,
                self.rootURL == rootURL
            else { return }
            Task {
                do {
                    let path = try await CanvasPreviewLoader.relativePath(for: url, root: rootURL)
                    guard self.rootURL == rootURL, self.canvas.boards[id] === board else { return }
                    try board.add(
                        title: url.lastPathComponent,
                        content: imageOnly ? .image(path: path) : .file(path: path))
                } catch { board.showNotice(error.localizedDescription) }
            }
        }
    }

    /// Quick Open's ⌘↩: puts the chosen file on the Ensemble in the focused
    /// tab as a file or image card, at the middle of the visible board, as one
    /// undo step. A file the board already shows is selected and revealed, not
    /// added twice. Board paths are relative to the primary folder, so a match
    /// from another folder of a multi-folder workspace is refused with a
    /// visible message rather than stored against the wrong base.
    func addFileToSelectedCanvas(_ match: WorkspaceFileMatch) {
        guard let board = selectedCanvas, !isTerminalGroupModalInputBlocked else { return }
        guard match.rootID == descriptor?.id else {
            board.showNotice(Self.canvasFileOutsideFolderMessage)
            return
        }
        if let existing = CanvasFileCardLookup.existingCard(
            forRelativePath: match.relativePath, in: board.cards)
        {
            focusCanvasCard(existing, in: board)
            return
        }
        board.backToBoard()
        board.creationCenter = nil
        do {
            let name = (match.relativePath as NSString).lastPathComponent
            let id = try board.add(
                title: String(name.prefix(120)),
                content: CanvasDroppedFileKind.content(forRelativePath: match.relativePath))
            focusCanvasCard(id, in: board)
        } catch {
            board.showNotice(error.localizedDescription)
        }
    }

    nonisolated static let canvasFileOutsideFolderMessage =
        "This file is outside the Ensemble\u{2019}s folder."

    func openCanvasFile(_ path: String) {
        guard let rootURL else { return }
        Task { [weak self] in
            do {
                _ = try await CanvasPreviewLoader.relativePath(
                    for: rootURL.appending(path: path), root: rootURL)
                guard let self, self.rootURL == rootURL else { return }
                openFile(atRelativePath: path)
            } catch { self?.selectedCanvas?.showNotice(error.localizedDescription) }
        }
    }
}

/// Finds the card that already shows a workspace file, so adding the same file
/// from Quick Open selects it instead of making a duplicate.
nonisolated enum CanvasFileCardLookup {
    /// The first file or image card whose path is `path`, in board order.
    static func existingCard(forRelativePath path: String, in cards: [CanvasCard])
        -> CanvasCardID?
    {
        cards.first { card in
            switch card.content {
            case .file(let cardPath), .image(let cardPath): cardPath == path
            default: false
            }
        }?.id
    }
}
