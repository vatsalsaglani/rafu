import CoreGraphics
import Foundation

/// A drop target's "what happens if you let go here" preview: a tinted
/// highlight and a one-line label. Pure and `Sendable` so it can be computed
/// identically by the SwiftUI delegate and the AppKit bridge.
nonisolated struct CanvasDropPreview: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case accept, warn }

    /// Where and how to draw the highlight.
    enum Shape: Equatable, Sendable {
        /// A precise ghost card, in board-space units (origin/size in board
        /// points). The view projects it through the viewport.
        case card(CGRect)
        /// A directional split band, forwarded to the editor group under
        /// the board.
        case edge(EditorSplitEdge)
        /// One ghost per card of a batch drop, in board-space units, in
        /// the grid the drop uses (`CanvasBoardDropGeometry.batchRects`).
        case cards([CGRect])
        /// A whole-board highlight: a refusal (warn tone, drawn as a bar on
        /// the board's top edge and a pill), or a tab moving into the
        /// editor group under the board (accept tone).
        case board
    }

    let label: String
    let tone: Tone
    let shape: Shape
    /// An SF Symbol for the ghost (`doc`, `photo`, `terminal`,
    /// `doc.on.doc`). Nil for a refusal.
    var glyph: String?
    /// What lands: a file's last path component or a short noun. Never
    /// file content. Nil when the drag does not name its file yet.
    var name: String?

    /// Whether writing `next` over `current` is a real change.
    /// `CanvasBoardState.updateDropPreview` checks this before it writes, so
    /// a drag hovering the same spot twice never triggers an extra view
    /// update. Clearing goes through `CanvasBoardState.clearDropPreview()`.
    static func changed(from current: CanvasDropPreview?, to next: CanvasDropPreview?) -> Bool {
        current != next
    }
}

/// Resolves what a drop on an Ensemble board WOULD do, from the exact same
/// rules the real drop uses (`CanvasBoardTabDrop.decide`,
/// `CanvasBoardDropGeometry`, `CanvasDroppedFileKind.fits`), so a hover label
/// and the drop it describes cannot disagree. A warn-tone result REFUSES
/// the drop (UX Round A): the cursor shows "not allowed" and the drop does
/// not run (`CanvasDropAcceptance`). Refusals the hover cannot see (an
/// unnamed file, a symlink) still end in the drop's notice.
nonisolated enum CanvasDropAction {
    /// A snapshot of board/session state the resolver needs but cannot read
    /// itself (this type is `nonisolated`; the board and session are
    /// `@MainActor`). Built fresh by the `@MainActor` call site on every
    /// hover and every drop, so it is never stale.
    struct Context: Equatable, Sendable {
        var hasWorkspace: Bool
        var cardCount: Int
        var isTerminalGroupTab: Bool
        var paneCount: Int
        var alreadyOnABoard: Bool
        var boardFull: Bool
        /// The standardized primary workspace root path, so a file preview
        /// can tell a file inside the workspace from one outside it. `nil`
        /// skips that check. The check is lexical (no symlink resolution on
        /// the main actor); the drop itself resolves symlinks.
        var rootPath: String?
        /// `rootPath` with symlinks resolved, or nil when it is the same.
        /// A file inside either path is inside the workspace.
        var resolvedRootPath: String?
        /// The rects of the cards a dropped card must not cover
        /// (`CanvasBoardDropGeometry.obstacles`). The ghost lands where the
        /// card lands: on the nearest free position.
        var occupied: [CanvasRect]

        init(
            hasWorkspace: Bool, cardCount: Int = 0, isTerminalGroupTab: Bool = false,
            paneCount: Int = 1, alreadyOnABoard: Bool = false, boardFull: Bool = false,
            rootPath: String? = nil, occupied: [CanvasRect] = []
        ) {
            self.hasWorkspace = hasWorkspace
            self.cardCount = cardCount
            self.isTerminalGroupTab = isTerminalGroupTab
            self.paneCount = paneCount
            self.alreadyOnABoard = alreadyOnABoard
            self.boardFull = boardFull
            self.rootPath = rootPath
            self.occupied = occupied
        }
    }

    /// Stands for a hovering file the drag does not name yet (a promise, or
    /// a SwiftUI drag with no same-window hint). Never classified as inside
    /// or outside the workspace.
    static let unknownFileURL = URL(fileURLWithPath: "/.rafu-unknown-dropped-file")

    static func resolve(
        content: CanvasBoardDropContent, at location: CGPoint, surface: CGSize,
        viewport: CanvasViewport, context: Context
    ) -> CanvasDropPreview? {
        guard context.hasWorkspace else { return nil }
        let boardPoint = CanvasBoardDropGeometry.boardPoint(location, viewport: viewport)
        switch content {
        case .files(let urls, let fromFilesTree):
            return filesPreview(
                urls, fromFilesTree: fromFilesTree, at: boardPoint, context: context)
        case .agentSession:
            return cardOrFullPreview(
                label: "Resume chat in a new terminal", name: "Chat", at: boardPoint,
                context: context)
        case .terminalGroup:
            return terminalMovePreview(at: boardPoint, context: context)
        case .tab:
            return tabPreview(
                at: location, surface: surface, boardPoint: boardPoint, context: context)
        }
    }

    /// A terminal/web-sized ghost card at `boardPoint`, or the full-board
    /// warning when the board has no room.
    private static func cardOrFullPreview(
        label: String, name: String, at boardPoint: CGPoint, context: Context
    ) -> CanvasDropPreview {
        guard !context.boardFull else {
            return CanvasDropPreview(label: "This Ensemble is full", tone: .warn, shape: .board)
        }
        let rect = CanvasBoardDropGeometry.freeRect(
            for: .terminal(groupID: TerminalGroupID()), centeredAt: boardPoint,
            avoiding: context.occupied)
        return CanvasDropPreview(
            label: label, tone: .accept, shape: .card(rect.cgRect), glyph: "terminal", name: name)
    }

    /// Shared by a Terminals-panel row (`.terminalGroup`) and a one-pane
    /// Terminal Group tab dropped centrally (`.tab` →
    /// `.moveTerminalToBoard`): both end in `moveTerminalGroupToEnsemble`,
    /// so both preview its exact refusal order (already on a board, more
    /// than one pane, board full).
    private static func terminalMovePreview(at boardPoint: CGPoint, context: Context)
        -> CanvasDropPreview
    {
        if context.alreadyOnABoard {
            return CanvasDropPreview(label: "Already on an Ensemble", tone: .warn, shape: .board)
        }
        if context.paneCount != 1 {
            return CanvasDropPreview(
                label: "Needs a single-pane terminal", tone: .warn, shape: .board)
        }
        return cardOrFullPreview(
            label: "Move terminal here — keeps running", name: "Terminal", at: boardPoint,
            context: context)
    }

    /// Mirrors `WorkspaceSession.addCanvasDroppedFiles`: a full board
    /// refuses; a file from outside the workspace that is not an image
    /// refuses the batch with a notice; images from outside are copied in
    /// (after consent); files inside are referenced in place.
    private static func filesPreview(
        _ urls: [URL], fromFilesTree: Bool, at boardPoint: CGPoint, context: Context
    ) -> CanvasDropPreview {
        let count = max(urls.count, 1)
        guard CanvasDroppedFileKind.fits(count: count, existing: context.cardCount) else {
            return CanvasDropPreview(label: "This Ensemble is full", tone: .warn, shape: .board)
        }
        let outside =
            fromFilesTree
            ? []
            : outsideFiles(
                urls, rootPath: context.rootPath, resolvedRootPath: context.resolvedRootPath)
        if outside.contains(where: { !CanvasDroppedFileKind.isImage($0) }) {
            return CanvasDropPreview(
                label: "Needs a file inside this workspace", tone: .warn, shape: .board)
        }
        let copies = !outside.isEmpty
        if urls.count > 1 {
            let contents = urls.map { url in
                url == unknownFileURL
                    ? CanvasCardContent.file(path: "")
                    : CanvasDroppedFileKind.content(forRelativePath: url.lastPathComponent)
            }
            let rects = CanvasBoardDropGeometry.batchRects(
                for: contents, centeredAt: boardPoint, avoiding: context.occupied
            ).map(\.cgRect)
            let firstName = urls[0] == unknownFileURL ? nil : urls[0].lastPathComponent
            guard copies else {
                return CanvasDropPreview(
                    label: "Add \(urls.count) cards", tone: .accept, shape: .cards(rects),
                    glyph: "doc.on.doc", name: firstName)
            }
            let allImages = urls.allSatisfy(CanvasDroppedFileKind.isImage)
            return CanvasDropPreview(
                label: "Copy and add \(urls.count) \(allImages ? "image cards" : "cards")",
                tone: .accept, shape: .cards(rects), glyph: "doc.on.doc", name: firstName)
        }
        guard let url = urls.first else {
            return CanvasDropPreview(label: "Add cards", tone: .accept, shape: .board)
        }
        let content = CanvasDroppedFileKind.content(forRelativePath: url.lastPathComponent)
        let isImage: Bool = {
            if case .image = content { true } else { false }
        }()
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: boardPoint, avoiding: context.occupied)
        let label =
            copies ? "Copy and add image card" : isImage ? "Add image card" : "Open as file card"
        return CanvasDropPreview(
            label: label, tone: .accept, shape: .card(rect.cgRect),
            glyph: isImage ? "photo" : "doc",
            name: url == unknownFileURL ? nil : url.lastPathComponent)
    }

    /// The named files that are not lexically inside `rootPath` nor inside
    /// `resolvedRootPath` (the root with symlinks resolved, so a workspace
    /// opened through a symlink does not refuse the real paths Finder
    /// sends). Unknown placeholders and a missing root give none.
    static func outsideFiles(
        _ urls: [URL], rootPath: String?, resolvedRootPath: String? = nil
    ) -> [URL] {
        guard let rootPath else { return [] }
        let prefixes = [rootPath, resolvedRootPath].compactMap { $0 }.map {
            $0.hasSuffix("/") ? $0 : $0 + "/"
        }
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return url != unknownFileURL && !prefixes.contains { path.hasPrefix($0) }
        }
    }

    private static func tabPreview(
        at location: CGPoint, surface: CGSize, boardPoint: CGPoint, context: Context
    ) -> CanvasDropPreview {
        let edge = EditorDropGeometry.target(at: location, in: surface)
        switch CanvasBoardTabDrop.decide(edge: edge, isTerminalGroupTab: context.isTerminalGroupTab)
        {
        case .moveTerminalToBoard:
            return terminalMovePreview(at: boardPoint, context: context)
        case .forwardToGroup(nil):
            return CanvasDropPreview(
                label: "Move tab to this editor group", tone: .accept, shape: .board)
        case .forwardToGroup(let edge?):
            return CanvasDropPreview(
                label: "Split editor \(edgeWord(edge))", tone: .accept, shape: .edge(edge))
        }
    }

    private static func edgeWord(_ edge: EditorSplitEdge) -> String {
        switch edge {
        case .leading: "left"
        case .trailing: "right"
        case .top: "up"
        case .bottom: "down"
        }
    }
}

/// What a hovering drag is told (UX Round A, B5). Both drop halves map this
/// to their own type: SwiftUI's `DropOperation` and AppKit's
/// `NSDragOperation` (`[]` for both refusals). A warn-tone preview refuses
/// the drop, so the cursor shows "not allowed" and the drop never runs.
nonisolated enum CanvasDropAcceptance: Equatable, Sendable {
    case copy
    /// The board does not take this kind of drag at all.
    case cancel
    /// The board takes this kind of drag, but not this one (full, outside
    /// the workspace, already on a board, more than one pane).
    case forbidden

    static func resolve(valid: Bool, preview: CanvasDropPreview?) -> Self {
        guard valid else { return .cancel }
        return preview?.tone == .warn ? .forbidden : .copy
    }
}
