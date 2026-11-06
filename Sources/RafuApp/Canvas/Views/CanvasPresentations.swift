import SwiftUI

/// The Ensemble dialogs and confirmations of one workspace window, in the
/// Rafu popup language (ADR 0033). Delete Saved Ensemble asks inside Open
/// Ensemble (`CanvasLibrarySheet`), so it is not here.
struct CanvasPresentations: ViewModifier {
    @Bindable var session: WorkspaceSession
    func body(content: Content) -> some View {
        content
            .sheet(item: $session.canvasDialog) { dialog in
                CanvasDialogView(dialog: dialog, session: session)
            }
            .sheet(
                isPresented: Binding(
                    get: { session.agentEnsembleResumeAwaitingConfirmation != nil },
                    set: { if !$0 { session.agentEnsembleResumeAwaitingConfirmation = nil } })
            ) {
                if let plan = session.agentEnsembleResumeAwaitingConfirmation {
                    RafuConfirmPopup(
                        symbol: "square.on.square.dashed", title: "No Ensemble is open",
                        message:
                            "Rafu creates a new Ensemble named “\(plan.title)” and resumes the session in a terminal node.",
                        actions: [
                            .init("New Ensemble") { session.createEnsembleForAgentResume(plan) }
                        ],
                        defaultActionID: "New Ensemble"
                    ) {
                        session.agentEnsembleResumeAwaitingConfirmation = nil
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { session.pendingCanvasRemoval != nil },
                    set: { if !$0 { session.pendingCanvasRemoval = nil } })
            ) {
                if let id = session.pendingCanvasRemoval {
                    RafuConfirmPopup(
                        symbol: "rectangle.badge.minus", title: "Remove from Ensemble?",
                        message:
                            "Source files and external apps stay open. Hidden terminals keep running in the Terminals panel. Close a terminal separately to stop it.",
                        actions: removalActions(id)
                    ) {
                        session.pendingCanvasRemoval = nil
                    }
                }
            }
    }

    /// Remove from Ensemble, and for one selected terminal also Close
    /// Terminal and Remove Card. Neither is the Return default.
    private func removalActions(_ id: CanvasID) -> [RafuConfirmPopup.Action] {
        guard let board = session.canvas.boards[id] else { return [] }
        var actions: [RafuConfirmPopup.Action] = [
            .init("Remove from Ensemble") {
                session.pendingCanvasRemoval = nil
                session.removeCanvasCards(id)
            }
        ]
        if board.selection.count == 1, hasTerminal(board) {
            actions.append(
                .init("Close Terminal and Remove Card", isDestructive: true) {
                    session.pendingCanvasRemoval = nil
                    session.closeCanvasTerminalCard(id)
                })
        }
        return actions
    }

    private func hasTerminal(_ board: CanvasBoardState) -> Bool {
        board.cards.contains { card in
            guard board.selection.contains(card.id) else { return false }
            if case .terminal = card.content { return true }
            return false
        }
    }
}
