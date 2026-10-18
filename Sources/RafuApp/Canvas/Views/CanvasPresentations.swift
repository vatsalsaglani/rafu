import SwiftUI

struct CanvasPresentations: ViewModifier {
    @Bindable var session: WorkspaceSession
    func body(content: Content) -> some View {
        content
            .sheet(item: $session.canvasDialog) { dialog in
                CanvasDialogView(dialog: dialog, session: session)
            }
            .confirmationDialog(
                "Remove from Ensemble?",
                isPresented: Binding(
                    get: { session.pendingCanvasRemoval != nil },
                    set: { if !$0 { session.pendingCanvasRemoval = nil } }),
                titleVisibility: .visible
            ) {
                if let id = session.pendingCanvasRemoval, let board = session.canvas.boards[id] {
                    Button("Remove from Ensemble") {
                        session.removeCanvasCards(id)
                    }
                    if board.selection.count == 1, hasTerminal(board) {
                        Button("Close Terminal and Remove Card", role: .destructive) {
                            session.closeCanvasTerminalCard(id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { session.pendingCanvasRemoval = nil }
            } message: {
                Text(
                    "Source files and external apps stay open. Hidden terminals keep running in the Terminals panel. Close a terminal separately to stop it."
                )
            }
            .confirmationDialog(
                "Delete saved Ensemble?",
                isPresented: Binding(
                    get: { session.pendingCanvasDelete != nil },
                    set: { if !$0 { session.pendingCanvasDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Ensemble", role: .destructive) {
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
