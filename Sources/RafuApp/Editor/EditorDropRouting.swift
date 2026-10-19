import Foundation

/// Decides which drop target owns a private `rafuEditorDrag` drag when an
/// Ensemble board (Canvas) fills an editor group.
///
/// Why this exists: the board registers its own `.onDrop` for the same
/// private type, because a file dragged from the Files tree adds a node. SwiftUI
/// hands a drag to the deepest matching target, so the board used to swallow a
/// dragged TAB too, decode it as "not a file", and do nothing.
///
/// Current behaviour: over a visible board, the board owns EVERY drag
/// (`CanvasFileDrop`, `CanvasBoardTabDrop`). It forwards a tab to the editor
/// group's own drop (`handleEditorTabDrop`) for an edge split, and moves a
/// one-pane Terminal Group tab dropped in the centre onto the board. The two
/// predicates below remain the group's "which payloads can I take" and the
/// board's "which payloads become a file node" rules.
///
/// The decision reads the payload the drag source cached on the session when
/// the drag began (`WorkspaceSession.activeEditorDrag`). `nil` means the drag
/// started in another window, which neither side can classify, so the board
/// (the deeper target) keeps it.
nonisolated enum EditorDropRouting {
    /// Whether the editor group's split/move target takes the drag while a
    /// board is visible. Without a board the group always takes it.
    static func groupAccepts(_ payload: EditorDragPayload?, canvasIsVisible: Bool) -> Bool {
        guard canvasIsVisible else { return true }
        if case .tab? = payload { return true }
        return false
    }

    /// Whether the payload can become a file node on the board. A tab never
    /// becomes a file node; the board routes it separately.
    static func canvasAccepts(_ payload: EditorDragPayload?) -> Bool {
        if case .tab? = payload { return false }
        return true
    }
}
