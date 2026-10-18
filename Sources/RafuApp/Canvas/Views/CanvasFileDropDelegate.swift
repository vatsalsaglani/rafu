import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Match the editor's private-file precedence and explicit copy proposal.
/// URL Transferable negotiation alone does not cover every sidebar provider.
struct CanvasFileDropDelegate: DropDelegate {
    let boardID: CanvasID
    let session: WorkspaceSession
    /// Drives the dashed drop outline on the board (review 7.4).
    var isTargeted: Binding<Bool> = .constant(false)

    func dropEntered(info: DropInfo) {
        isTargeted.wrappedValue = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard session.rootURL != nil, let board = session.canvas.boards[boardID],
            board.cards.count < CanvasLimits.cards
        else { return false }
        if !info.itemProviders(for: [.rafuEditorDrag]).isEmpty {
            // A dragged editor TAB belongs to the editor group's edge-split
            // target, not to the board (`EditorDropRouting`).
            return EditorDropRouting.canvasAccepts(session.activeEditorDrag)
        }
        let count = info.itemProviders(for: [.fileURL]).count
        return count > 0 && count <= CanvasLimits.cards - board.cards.count
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        guard validateDrop(info: info) else { return false }
        let location = info.location
        if let provider = info.itemProviders(for: [.rafuEditorDrag]).first {
            // A cancelled or cross-window drag can leave a stale session cache.
            // Only the incoming provider identifies this drop.
            let collector = CanvasFileDropCollector(
                count: 1, boardID: boardID, location: location, session: session,
                clearsEditorDrag: true)
            _ = provider.loadDataRepresentation(for: .rafuEditorDrag) { data, _ in
                let url = data.flatMap(CanvasFileDropDecoder.privateURL)
                Task { @MainActor in collector.receive(url, at: 0) }
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

    static func externalURL(_ data: Data) -> URL? {
        guard data.count <= 16 * 1_024,
            let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
            url.path.utf8.count <= 4_096, !url.path.contains("\0")
        else { return nil }
        return url
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
