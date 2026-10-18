import AppKit
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
        Task(name: "Save requested Canvas") { [weak self] in
            guard let self else { return }
            _ = await canvas.save(id)
            scheduleCanvasWorkspaceSave()
        }
    }

    func revealCanvasSaveFailure() {
        guard
            let board = canvas.boards.values.first(where: { $0.isDirty && $0.errorMessage != nil })
        else { return }
        presentCanvasBoard(board)
        _ = WorkspaceWindowRegistry.shared.focus(session: self)
    }

    func saveCanvasCopy(_ id: CanvasID) {
        Task(name: "Save Canvas copy") { [weak self] in
            guard let self else { return }
            guard let board = await canvas.saveCopy(id) else {
                canvas.boards[id]?.errorMessage =
                    canvas.libraryNotice ?? "The Canvas copy could not be saved."
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
        Task(name: "Close Canvas") { [weak self] in
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

    func performCanvasEdit(_ board: CanvasBoardState, _ operation: () throws -> Void) {
        do { try operation() } catch { board.errorMessage = error.localizedDescription }
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
            board.errorMessage = error.localizedDescription
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

    /// A drop adds references only. Validation is off-main and the edit is one
    /// transaction, so a rejected batch cannot leave a partially added board.
    func addCanvasDroppedFiles(_ urls: [URL], to id: CanvasID, at location: CGPoint) async {
        guard let root = rootURL, let board = canvas.boards[id], !urls.isEmpty else { return }
        guard urls.count <= CanvasLimits.cards - board.cards.count else {
            board.errorMessage = CanvasError.capacity.localizedDescription
            return
        }
        let viewport = board.viewport
        do {
            let paths = try await Self.canvasDroppedPaths(urls, root: root)
            guard !Task.isCancelled, rootURL == root, canvas.boards[id] === board,
                !paths.isEmpty
            else { return }
            let x = (location.x - viewport.x) / viewport.scale
            let y = (location.y - viewport.y) / viewport.scale
            let cards = paths.enumerated().map { index, path in
                CanvasCard(
                    title: String(URL(fileURLWithPath: path).lastPathComponent.prefix(120)),
                    rect: CanvasRect(
                        x: min(50_000, max(-50_000, x + Double(index) * 24)),
                        y: min(50_000, max(-50_000, y + Double(index) * 24))),
                    content: CanvasDroppedFileKind.content(forRelativePath: path))
            }
            try board.edit { document in
                guard document.cards.count + cards.count <= CanvasLimits.cards else {
                    throw CanvasError.capacity
                }
                document.cards.append(contentsOf: cards)
            }
            board.backToBoard()
            board.selection = Set(cards.map(\.id))
        } catch is CancellationError {
            return
        } catch {
            guard rootURL == root, canvas.boards[id] === board else { return }
            board.errorMessage = error.localizedDescription
        }
    }

    @concurrent
    private static func canvasDroppedPaths(_ urls: [URL], root: URL) async throws -> [String] {
        var paths: [String] = []
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL else { throw CanvasError.invalidPath }
            // A dropped folder is ignored, not an error: the rest of the batch
            // still lands, and a folder-only drop adds nothing.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            let path = try await CanvasPreviewLoader.relativePath(for: url, root: root)
            let checked = root.appending(path: path)
            let metadata = try checked.resourceValues(forKeys: [.isRegularFileKey])
            guard metadata.isRegularFile == true else { throw CanvasError.invalidPath }
            paths.append(path)
        }
        return paths
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
                } catch { board.errorMessage = error.localizedDescription }
            }
        }
    }

    func chooseCanvasApplication(_ id: CanvasID) {
        guard let board = canvas.boards[id] else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add App"
        panel.begin { [weak self, weak board] response in
            guard response == .OK, let self, let board, let url = panel.url else { return }
            Task(name: "Read selected app identity") {
                do {
                    let app = try await CanvasPreviewLoader.appIdentity(url)
                    guard self.canvas.boards[id] === board else { return }
                    try board.add(title: app.name, content: .nativeApp(bundleID: app.bundleID))
                } catch { board.errorMessage = error.localizedDescription }
            }
        }
    }

    func openCanvasFile(_ path: String) {
        guard let rootURL else { return }
        Task { [weak self] in
            do {
                _ = try await CanvasPreviewLoader.relativePath(
                    for: rootURL.appending(path: path), root: rootURL)
                guard let self, self.rootURL == rootURL else { return }
                openFile(atRelativePath: path)
            } catch { self?.selectedCanvas?.errorMessage = error.localizedDescription }
        }
    }
}
