import SwiftUI

struct CanvasCommands: Commands {
    @FocusedValue(\.workspaceSession) private var session
    private var board: CanvasBoardState? { session?.selectedCanvas }
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Canvas…") { session?.requestNewCanvas() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(session?.rootURL == nil)
            Button("Open Canvas…") { session?.requestCanvasLibrary() }.disabled(
                session?.rootURL == nil)
        }
        CommandMenu("Canvas") {
            if let board, let session {
                CanvasAddCardMenu(board: board, session: session)
            }
            Button("Fit All") { board?.fitAll() }.disabled(board == nil)
            Button("Actual Size") { if let board { board.zoom(1 / board.viewport.scale) } }
                .disabled(board == nil)
            Button("Zoom In") { board?.zoom(1.2) }.disabled(board == nil)
            Button("Zoom Out") { board?.zoom(1 / 1.2) }.disabled(board == nil)
            Button("Arrange") {
                if let board { session?.performCanvasEdit(board) { try board.arrange() } }
            }.disabled(board == nil)
            Button("Connect Selected Cards…") {
                if let board { session?.requestCanvasConnection(board.id) }
            }.disabled(board?.selection.count != 2)
            Divider()
            Button("Focus Selected Card") {
                if let id = board?.selection.first { board?.focus(id) }
            }.disabled(board?.selection.count != 1)
            Button("Enter Content") { board?.contentIsActive = true }.disabled(
                board?.focusedCard == nil)
            Button("Leave Content") { board?.leaveContent() }.disabled(board == nil)
            Button("Show Canvas List") {
                board?.backToBoard()
                board?.showsList = true
            }.disabled(board == nil)
            Divider()
            Button("Undo Canvas Layout") { board?.performUndo() }.disabled(board?.canUndo != true)
            Button("Redo Canvas Layout") { board?.performRedo() }.disabled(board?.canRedo != true)
            Button("Remove Selected Cards…") {
                if let board { session?.requestCanvasCardRemoval(board.id) }
            }.disabled(board?.selection.isEmpty != false)
        }
    }
}
