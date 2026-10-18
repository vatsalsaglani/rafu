import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Match the editor's private-file precedence and explicit copy proposal.
/// URL Transferable negotiation alone does not cover every sidebar provider.
///
/// This is the SwiftUI half of the board's drop target. AppKit can route the
/// same drag to `CanvasScrollBridge` instead (see `CanvasBoardDropTarget`);
/// both halves share `CanvasFileDrop`, so a drop is handled once either way.
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
        if !info.itemProviders(for: [.rafuEditorDrag]).isEmpty {
            return CanvasFileDrop.accepts(count: 1, boardID: boardID, session: session)
        }
        let count = info.itemProviders(for: [.fileURL]).count
        return CanvasFileDrop.accepts(count: count, boardID: boardID, session: session)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let valid = validateDrop(info: info)
        if isTargeted.wrappedValue != valid { isTargeted.wrappedValue = valid }
        return DropProposal(operation: valid ? .copy : .cancel)
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

    /// The AppKit half of the drop target for one board.
    static func target(
        boardID: CanvasID, session: WorkspaceSession, isTargeted: Binding<Bool>
    ) -> CanvasBoardDropTarget {
        CanvasBoardDropTarget(
            accepts: { [weak session] count in
                guard let session else { return false }
                return accepts(count: count, boardID: boardID, session: session)
            },
            targeted: { value in
                if isTargeted.wrappedValue != value { isTargeted.wrappedValue = value }
            },
            perform: { [weak session] urls, fromFilesTree, point in
                guard let session else { return false }
                return perform(
                    urls, fromFilesTree: fromFilesTree, boardID: boardID, at: point,
                    session: session)
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
