import Foundation

/// Decides which drop target owns a private `rafuEditorDrag` drag when an
/// Ensemble board (Canvas) fills an editor group.
///
/// Why this exists: the board registers its own `.onDrop` for the same
/// private type, because a file dragged from the Files tree adds a node. SwiftUI
/// hands a drag to the deepest matching target, so before this split the board
/// swallowed a dragged TAB too, decoded it as "not a file", and did nothing.
/// The user could not split an editor group while a board was showing. Files
/// stay with the board; tabs go to the group's edge-split target.
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

    /// Whether the board's file-drop target takes the drag. A tab never
    /// becomes a node.
    static func canvasAccepts(_ payload: EditorDragPayload?) -> Bool {
        if case .tab? = payload { return false }
        return true
    }
}
