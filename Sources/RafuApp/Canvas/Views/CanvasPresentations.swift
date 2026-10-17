import SwiftUI

struct CanvasPresentations: ViewModifier {
    @Bindable var session: WorkspaceSession
    func body(content: Content) -> some View {
        content
            .sheet(item: $session.canvasDialog) { dialog in
                CanvasDialogView(dialog: dialog, session: session)
            }
            .confirmationDialog(
                "Remove selected cards?",
                isPresented: Binding(
                    get: { session.pendingCanvasRemoval != nil },
                    set: { if !$0 { session.pendingCanvasRemoval = nil } }),
                titleVisibility: .visible
            ) {
                if let id = session.pendingCanvasRemoval, let board = session.canvas.boards[id] {
                    Button(hasTerminal(board) ? "Remove Cards and Park Groups" : "Remove Cards") {
                        session.removeCanvasCards(id)
                    }
                    if board.selection.count == 1, hasTerminal(board) {
                        Button("Close Terminal Group and Remove Card…", role: .destructive) {
                            session.closeCanvasTerminalCard(id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { session.pendingCanvasRemoval = nil }
            } message: {
                Text(
                    "Source files and external apps stay open. Parked terminal processes continue in the Terminal manager. Close a terminal group separately to stop it."
                )
            }
            .confirmationDialog(
                "Delete saved Canvas?",
                isPresented: Binding(
                    get: { session.pendingCanvasDelete != nil },
                    set: { if !$0 { session.pendingCanvasDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Canvas", role: .destructive) {
                    guard let item = session.pendingCanvasDelete else { return }
                    session.pendingCanvasDelete = nil
                    Task { _ = await session.canvas.deleteSaved(item) }
                }
                Button("Cancel", role: .cancel) { session.pendingCanvasDelete = nil }
            } message: {
                Text(
                    "This deletes its saved layout and notes. Source files and external apps are not deleted."
                )
            }
    }
    private func hasTerminal(_ board: CanvasBoardState) -> Bool {
        board.cards.contains { card in
            guard board.selection.contains(card.id) else { return false }
            if case .terminal = card.content { return true }
            return false
        }
    }
}
