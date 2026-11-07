import SwiftUI

/// The view card's own menu items: in the header menu and the context menu
/// (both use `CanvasCardMenuContent`). Nothing for other card kinds.
struct GeneratedViewCardMenuItems: View {
    let card: CanvasCard
    let board: CanvasBoardState

    var body: some View {
        if case .generatedView = card.content {
            Button("Reset View", systemImage: "arrow.counterclockwise") {
                GeneratedViewActions.reset(card.id, on: board)
            }
            Button("Show Spec…", systemImage: "curlybraces") {
                GeneratedViewModels.shared.model(for: card.id, board: board, session: nil)
                    .isShowingSpec = true
            }
        }
    }
}
