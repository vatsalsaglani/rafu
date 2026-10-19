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
        /// A generic whole-board highlight, for a multi-file batch or a
        /// refusal with no single precise rect.
        case board
    }

    let label: String
    let tone: Tone
    let shape: Shape

    /// Whether writing `next` over `current` is a real change. Every call
    /// site that drives a drop-preview `@State`/`Binding` — `dropEntered`,
    /// `dropUpdated`, `dropExited`, `performDrop`, and the AppKit bridge's
    /// `draggingUpdated`/`draggingExited`/`concludeDragOperation` — checks
    /// this before writing, so a drag hovering the same spot twice (or an
    /// exit/perform/conclude after the preview is already `nil`) never
    /// triggers an extra view update. `dropExited`/`performDrop`/
    /// `concludeDragOperation` always pass `next: nil`, so this is also
    /// exactly the "does this clear the preview" check for those three.
    static func changed(from current: CanvasDropPreview?, to next: CanvasDropPreview?) -> Bool {
        current != next
    }
}

/// Resolves what a drop on an Ensemble board WOULD do, from the exact same
/// rules the real drop uses (`CanvasBoardTabDrop.decide`,
/// `CanvasBoardDropGeometry`, `CanvasDroppedFileKind.fits`), so a hover label
/// and the drop it describes cannot disagree. A warn-tone result never
/// changes whether the drop is ACCEPTED — the drop still runs and shows its
/// existing error; this only previews which message that would be.
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

        init(
            hasWorkspace: Bool, cardCount: Int = 0, isTerminalGroupTab: Bool = false,
            paneCount: Int = 1, alreadyOnABoard: Bool = false, boardFull: Bool = false
        ) {
            self.hasWorkspace = hasWorkspace
            self.cardCount = cardCount
            self.isTerminalGroupTab = isTerminalGroupTab
            self.paneCount = paneCount
            self.alreadyOnABoard = alreadyOnABoard
            self.boardFull = boardFull
        }
    }

    static func resolve(
        content: CanvasBoardDropContent, at location: CGPoint, surface: CGSize,
        viewport: CanvasViewport, context: Context
    ) -> CanvasDropPreview? {
        guard context.hasWorkspace else { return nil }
        let boardPoint = CanvasBoardDropGeometry.boardPoint(location, viewport: viewport)
        switch content {
        case .files(let urls, _):
            return filesPreview(urls, at: boardPoint, context: context)
        case .agentSession:
            return cardOrFullPreview(
                label: "Resume chat in a new terminal", at: boardPoint, context: context)
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
        label: String, at boardPoint: CGPoint, context: Context
    ) -> CanvasDropPreview {
        guard !context.boardFull else {
            return CanvasDropPreview(label: "This Ensemble is full", tone: .warn, shape: .board)
        }
        let rect = CanvasBoardDropGeometry.defaultRect(
            for: .terminal(groupID: TerminalGroupID()), centeredAt: boardPoint)
        return CanvasDropPreview(label: label, tone: .accept, shape: .card(rect.cgRect))
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
            label: "Move terminal here — keeps running", at: boardPoint, context: context)
    }

    private static func filesPreview(
        _ urls: [URL], at boardPoint: CGPoint, context: Context
    ) -> CanvasDropPreview {
        let count = max(urls.count, 1)
        guard CanvasDroppedFileKind.fits(count: count, existing: context.cardCount) else {
            return CanvasDropPreview(label: "This Ensemble is full", tone: .warn, shape: .board)
        }
        if urls.count > 1 {
            return CanvasDropPreview(label: "Add \(urls.count) cards", tone: .accept, shape: .board)
        }
        guard let url = urls.first else {
            return CanvasDropPreview(label: "Add cards", tone: .accept, shape: .board)
        }
        let content = CanvasDroppedFileKind.content(forRelativePath: url.lastPathComponent)
        let isImage: Bool = {
            if case .image = content { true } else { false }
        }()
        let rect = CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: boardPoint)
        return CanvasDropPreview(
            label: isImage ? "Add image card" : "Open as file card", tone: .accept,
            shape: .card(rect.cgRect))
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
