import AppKit
import RafuCore
import SwiftUI
import UniformTypeIdentifiers

/// The SwiftUI half of the board's drop target. Over a visible board, the
/// board owns EVERY drag: files, Agent History rows, Terminals-panel
/// Terminal Group rows, and editor tabs. Type
/// priority is `rafuEnsembleDrag` > `rafuEditorDrag` > `fileURL`, and the
/// proposal is an explicit `.copy`. AppKit can route the same drag to
/// `CanvasScrollBridge` instead (see `CanvasBoardDropTarget`); both halves
/// share `CanvasFileDrop`, so a drop is handled once either way.
struct CanvasFileDropDelegate: DropDelegate {
    let boardID: CanvasID
    let session: WorkspaceSession
    /// The board surface, in the same space as `DropInfo.location`. The edge
    /// bands of a dropped tab are measured against it.
    var surfaceSize: CGSize = .zero
    /// The board's hover preview: a tinted highlight and a one-line label
    /// for what a drop here would do, or `nil` to show nothing.
    var dropPreview: Binding<CanvasDropPreview?> = .constant(nil)

    func dropEntered(info: DropInfo) {
        updatePreview(info: info)
    }

    func dropExited(info: DropInfo) {
        dropPreview.wrappedValue = nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        if !info.itemProviders(for: [.rafuEnsembleDrag]).isEmpty {
            return CanvasFileDrop.acceptsAgentSession(boardID: boardID, session: session)
        }
        if !info.itemProviders(for: [.rafuEditorDrag]).isEmpty {
            // The session cache only hints at the kind. An editor tab is
            // handled by the board even when no file would fit on it.
            if case .tab? = session.activeEditorDrag {
                return CanvasFileDrop.acceptsTab(boardID: boardID, session: session)
            }
            return CanvasFileDrop.accepts(count: 1, boardID: boardID, session: session)
        }
        let count = info.itemProviders(for: [.fileURL]).count
        return CanvasFileDrop.accepts(count: count, boardID: boardID, session: session)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let valid = updatePreview(info: info)
        return DropProposal(operation: valid ? .copy : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropPreview.wrappedValue = nil
        guard validateDrop(info: info) else { return false }
        let location = info.location
        let surface = surfaceSize
        if let provider = info.itemProviders(for: [.rafuEnsembleDrag]).first {
            // `action` closes over only a `@MainActor` class and the board id,
            // so it is safe to hand to the off-actor load handler.
            let action: @MainActor @Sendable (CanvasBoardDragPayload?) -> Void = {
                [session, boardID] payload in
                guard let payload else {
                    session.canvas.boards[boardID]?.errorMessage =
                        "Rafu could not read what was dropped."
                    return
                }
                switch payload {
                case .agentSession:
                    guard let sessionKey = payload.sessionKey else { return }
                    CanvasFileDrop.perform(
                        .agentSession(sessionKey), at: location, surface: surface,
                        boardID: boardID, session: session)
                case .terminalGroup(let id):
                    CanvasFileDrop.perform(
                        .terminalGroup(id), at: location, surface: surface,
                        boardID: boardID, session: session)
                }
            }
            _ = provider.loadDataRepresentation(for: .rafuEnsembleDrag) { data, _ in
                let payload = data.flatMap(CanvasBoardDragPayload.decode)
                Task { @MainActor in action(payload) }
            }
            return true
        }
        if let provider = info.itemProviders(for: [.rafuEditorDrag]).first {
            // A cancelled or cross-window drag can leave a stale session cache.
            // Only the incoming provider identifies this drop, so it is
            // always decoded: a file path or a tab id.
            let collector = CanvasFileDropCollector(
                count: 1, boardID: boardID, location: location, session: session,
                clearsEditorDrag: true)
            let action: @MainActor @Sendable (CanvasBoardDropContent?) -> Void = {
                [session, boardID] content in
                switch content {
                case .tab(let id)?:
                    CanvasFileDrop.perform(
                        .tab(id), at: location, surface: surface, boardID: boardID,
                        session: session)
                case .files(let urls, _)?:
                    collector.receive(urls.first, at: 0)
                default:
                    collector.receive(nil, at: 0)
                }
            }
            _ = provider.loadDataRepresentation(for: .rafuEditorDrag) { data, _ in
                let content = data.flatMap(CanvasFileDropDecoder.editorContent)
                Task { @MainActor in action(content) }
            }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        let collector = CanvasFileDropCollector(
            count: providers.count, boardID: boardID, location: location, session: session)
        for (index, provider) in providers.enumerated() {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                let url = data.flatMap(CanvasFileDropDecoder.externalURL)
                Task { @MainActor in collector.receive(url, at: index) }
            }
        }
        return true
    }

    /// Updates `dropPreview` from the best hint available WITHOUT decoding
    /// the provider (type presence, and the same-window `activeEditorDrag`/
    /// `activeEnsembleDragHint` caches `validateDrop` already uses) and
    /// returns whether the drag validates. The real drop always decodes at
    /// `performDrop`; this never drives acceptance, only the label.
    @discardableResult
    private func updatePreview(info: DropInfo) -> Bool {
        let valid = validateDrop(info: info)
        let preview: CanvasDropPreview? =
            valid
            ? hintedContent(for: info).flatMap {
                CanvasFileDrop.preview(
                    for: $0, at: info.location, surface: surfaceSize, boardID: boardID,
                    session: session)
            } : nil
        if CanvasDropPreview.changed(from: dropPreview.wrappedValue, to: preview) {
            dropPreview.wrappedValue = preview
        }
        return valid
    }

    /// What this drag probably carries, from type presence and same-window
    /// hints only — never a provider decode. A cross-window drag with no
    /// cached hint still gets a generic, never-incorrect preview.
    private func hintedContent(for info: DropInfo) -> CanvasBoardDropContent? {
        if !info.itemProviders(for: [.rafuEnsembleDrag]).isEmpty {
            if case .terminalGroup = session.activeEnsembleDragHint {
                return .terminalGroup(TerminalGroupID())
            }
            return .agentSession(AgentHistorySessionKey(provider: .claudeCode, sessionID: ""))
        }
        if !info.itemProviders(for: [.rafuEditorDrag]).isEmpty {
            if case .tab(let id)? = session.activeEditorDrag { return .tab(id) }
            if case .file(let path)? = session.activeEditorDrag,
                let url = CanvasFileDropDecoder.url(for: .file(path: path))
            {
                return .files([url], fromFilesTree: true)
            }
            return .files([URL(fileURLWithPath: "/")], fromFilesTree: true)
        }
        let fileProviders = info.itemProviders(for: [.fileURL])
        guard !fileProviders.isEmpty else { return nil }
        if fileProviders.count == 1,
            fileProviders[0].hasItemConformingToTypeIdentifier(UTType.image.identifier)
        {
            return .files([URL(fileURLWithPath: "/placeholder.png")], fromFilesTree: false)
        }
        return .files(
            Array(repeating: URL(fileURLWithPath: "/placeholder"), count: fileProviders.count),
            fromFilesTree: false)
    }
}

/// The one drop policy for the board, shared by the SwiftUI delegate and the
/// AppKit bridge.
@MainActor
enum CanvasFileDrop {
    /// A workspace is open, the board exists, and the files fit on it.
    static func accepts(count: Int, boardID: CanvasID, session: WorkspaceSession) -> Bool {
        guard session.rootURL != nil, let board = session.canvas.boards[boardID] else {
            return false
        }
        return CanvasDroppedFileKind.fits(count: count, existing: board.cards.count)
    }

    /// A workspace is open and the board exists — the shared precondition
    /// for every drag carrying the private `rafuEnsembleDrag` type (an Agent
    /// History row or a Terminals-panel Terminal Group row). Each carries
    /// ids only; a full board, "already on an Ensemble", or "more than one
    /// pane" is refused at drop time with a message, as for any resume.
    static func acceptsEnsembleDragPayload(boardID: CanvasID, session: WorkspaceSession) -> Bool {
        session.rootURL != nil && session.canvas.boards[boardID] != nil
    }

    static func acceptsAgentSession(boardID: CanvasID, session: WorkspaceSession) -> Bool {
        acceptsEnsembleDragPayload(boardID: boardID, session: session)
    }

    static func acceptsTerminalGroupDrag(boardID: CanvasID, session: WorkspaceSession) -> Bool {
        acceptsEnsembleDragPayload(boardID: boardID, session: session)
    }

    /// The board exists. Whether the tab moves onto it or splits the editor
    /// group is decided at drop time (`CanvasBoardTabDrop`).
    static func acceptsTab(boardID: CanvasID, session: WorkspaceSession) -> Bool {
        session.canvas.boards[boardID] != nil
    }

    static func accepts(
        _ content: CanvasBoardDropContent, boardID: CanvasID, session: WorkspaceSession
    ) -> Bool {
        switch content {
        case .files(let urls, _):
            accepts(count: urls.count, boardID: boardID, session: session)
        case .agentSession:
            acceptsAgentSession(boardID: boardID, session: session)
        case .tab:
            acceptsTab(boardID: boardID, session: session)
        case .terminalGroup:
            acceptsTerminalGroupDrag(boardID: boardID, session: session)
        }
    }

    /// Handles one decoded drop at `location` (board view space, top-left
    /// origin) on a surface of size `surface`.
    @discardableResult
    static func perform(
        _ content: CanvasBoardDropContent, at location: CGPoint, surface: CGSize,
        boardID: CanvasID, session: WorkspaceSession
    ) -> Bool {
        guard accepts(content, boardID: boardID, session: session) else { return false }
        switch content {
        case .files(let urls, let fromFilesTree):
            return perform(
                urls, fromFilesTree: fromFilesTree, boardID: boardID, at: location,
                session: session)
        case .agentSession(let key):
            return session.dropAgentSessionOnCanvas(key, boardID: boardID, at: location)
        case .tab(let id):
            return session.dropEditorTabOnCanvas(
                id, boardID: boardID, at: location, surface: surface)
        case .terminalGroup(let id):
            return session.dropTerminalGroupOnCanvas(id, boardID: boardID, at: location)
        }
    }

    /// Adds the dropped files as cards at `location` (board view space).
    /// Folders are ignored; files outside the workspace reject the batch.
    @discardableResult
    static func perform(
        _ urls: [URL], fromFilesTree: Bool, boardID: CanvasID, at location: CGPoint,
        session: WorkspaceSession
    ) -> Bool {
        guard accepts(count: urls.count, boardID: boardID, session: session) else { return false }
        if fromFilesTree { session.clearEditorDrag() }
        Task { [weak session] in
            await session?.addCanvasDroppedFiles(urls, to: boardID, at: location)
        }
        return true
    }

    /// The `CanvasDropAction.Context` for `content` on `boardID`, built once
    /// and shared by both drop halves so a hover label and the drop it
    /// describes cannot disagree. Mirrors the refusal order checked at drop
    /// time in `WorkspaceSession.moveTerminalGroupToEnsemble` and
    /// `CanvasDroppedFileKind.fits`.
    static func previewContext(
        for content: CanvasBoardDropContent, boardID: CanvasID, session: WorkspaceSession
    ) -> CanvasDropAction.Context {
        guard let board = session.canvas.boards[boardID] else {
            return CanvasDropAction.Context(hasWorkspace: session.rootURL != nil)
        }
        var context = CanvasDropAction.Context(
            hasWorkspace: session.rootURL != nil, cardCount: board.cards.count,
            boardFull: board.cards.count >= CanvasLimits.cards)
        var groupID: TerminalGroupID?
        if case .terminalGroup(let id) = content {
            groupID = id
            context.isTerminalGroupTab = true
        } else if case .tab(let value) = content, let uuid = UUID(uuidString: value) {
            let tabID = EditorTabID(rawValue: uuid)
            if let tab = session.editorLayout.group(containing: tabID)?.tabs.first(where: {
                $0.id == tabID
            }), case .terminalGroup(let id) = tab.resource {
                groupID = id
                context.isTerminalGroupTab = true
            }
        }
        if let groupID {
            context.paneCount = session.terminal.terminalGroup(groupID)?.panes.count ?? 0
            let terminalContent = CanvasCardContent.terminal(groupID: groupID)
            context.alreadyOnABoard = session.canvas.boards.values.contains {
                $0.cards.contains { $0.content == terminalContent }
            }
        }
        return context
    }

    /// The preview `content` would produce at `location`/`surface` on
    /// `boardID`, or `nil` when there is no board or no workspace.
    static func preview(
        for content: CanvasBoardDropContent, at location: CGPoint, surface: CGSize,
        boardID: CanvasID, session: WorkspaceSession
    ) -> CanvasDropPreview? {
        guard let board = session.canvas.boards[boardID] else { return nil }
        let context = previewContext(for: content, boardID: boardID, session: session)
        return CanvasDropAction.resolve(
            content: content, at: location, surface: surface, viewport: board.viewport,
            context: context)
    }

    /// The AppKit half of the drop target for one board.
    static func target(
        boardID: CanvasID, session: WorkspaceSession, dropPreview: Binding<CanvasDropPreview?>
    ) -> CanvasBoardDropTarget {
        CanvasBoardDropTarget(
            accepts: { [weak session] content in
                guard let session else { return false }
                return accepts(content, boardID: boardID, session: session)
            },
            preview: { [weak session] content, point, surface in
                guard let session else { return nil }
                return preview(
                    for: content, at: point, surface: surface, boardID: boardID, session: session)
            },
            update: { value in
                if CanvasDropPreview.changed(from: dropPreview.wrappedValue, to: value) {
                    dropPreview.wrappedValue = value
                }
            },
            perform: { [weak session] content, point, surface in
                guard let session else { return false }
                return perform(
                    content, at: point, surface: surface, boardID: boardID, session: session)
            })
    }
}

/// Pure rules for what a dropped file becomes. Kept free of AppKit so the
/// tests can check them directly.
nonisolated enum CanvasDroppedFileKind {
    /// Raster formats the image card decodes (ImageIO). SVG and PDF stay
    /// file cards.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp",
    ]

    static func content(forRelativePath path: String) -> CanvasCardContent {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return .file(path: path)
        }
        let ext = name[name.index(after: dot)...].lowercased()
        return imageExtensions.contains(ext) ? .image(path: path) : .file(path: path)
    }

    /// At least one file, and no more than the board has room for.
    static func fits(count: Int, existing: Int) -> Bool {
        count > 0 && existing < CanvasLimits.cards && count <= CanvasLimits.cards - existing
    }
}

nonisolated enum CanvasFileDropDecoder {
    static func url(for payload: EditorDragPayload) -> URL? {
        guard case .file(let path) = payload, path.hasPrefix("/"),
            path.utf8.count <= 4_096, !path.contains("\0")
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func privateURL(_ data: Data) -> URL? {
        guard data.count <= 16 * 1_024, let payload = try? EditorDragPayload(data: data) else {
            return nil
        }
        return url(for: payload)
    }

    /// What an editor-drag payload carries for the board: a file from the
    /// Files tree, or an editor tab (by a valid UUID string).
    static func editorContent(_ data: Data) -> CanvasBoardDropContent? {
        guard data.count <= 16 * 1_024, let payload = try? EditorDragPayload(data: data) else {
            return nil
        }
        switch payload {
        case .file:
            return url(for: payload).map { .files([$0], fromFilesTree: true) }
        case .tab(let id):
            return UUID(uuidString: id) == nil ? nil : .tab(id)
        }
    }

    static func externalURL(_ data: Data) -> URL? {
        guard data.count <= 16 * 1_024,
            let url = URL(dataRepresentation: data, relativeTo: nil), isAcceptable(url)
        else { return nil }
        return url
    }

    /// A local file URL with a bounded path and no NUL byte.
    static func isAcceptable(_ url: URL) -> Bool {
        url.isFileURL && url.path.utf8.count <= 4_096 && !url.path.contains("\0")
    }
}

/// Keep source order and reject an incomplete batch rather than adding only
/// the files whose asynchronous provider loads happened to succeed.
@MainActor
private final class CanvasFileDropCollector {
    private var received: Set<Int> = []
    private var urls: [URL?]
    private let boardID: CanvasID
    private let location: CGPoint
    private weak var session: WorkspaceSession?
    private weak var board: CanvasBoardState?
    private let root: URL?
    private let clearsEditorDrag: Bool

    init(
        count: Int, boardID: CanvasID, location: CGPoint, session: WorkspaceSession,
        clearsEditorDrag: Bool = false
    ) {
        urls = Array(repeating: nil, count: count)
        self.boardID = boardID
        self.location = location
        self.session = session
        board = session.canvas.boards[boardID]
        root = session.rootURL
        self.clearsEditorDrag = clearsEditorDrag
    }

    func receive(_ url: URL?, at index: Int) {
        guard urls.indices.contains(index), received.insert(index).inserted else { return }
        urls[index] = url
        guard received.count == urls.count, let session, let board,
            session.canvas.boards[boardID] === board, session.rootURL == root
        else { return }
        if clearsEditorDrag { session.clearEditorDrag() }
        let files = urls.compactMap { $0 }
        guard files.count == urls.count else {
            board.errorMessage = CanvasError.invalidPath.localizedDescription
            return
        }
        Task { [weak session] in
            await session?.addCanvasDroppedFiles(files, to: boardID, at: location)
        }
    }
}
