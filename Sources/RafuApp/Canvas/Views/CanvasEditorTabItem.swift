import SwiftUI

struct CanvasEditorTabItem: View {
    let tab: EditorTabState
    let groupID: EditorGroupID
    let board: CanvasBoardState
    let isSelected: Bool
    let session: WorkspaceSession
    /// This tab's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the tab's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    var body: some View {
        AttachedWorkbenchTab(
            isSelected: isSelected, usesDocumentWidth: true,
            select: { session.selectEditorTab(tab.id, in: groupID) }
        ) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group").accessibilityHidden(true)
                Button(board.title) { session.selectEditorTab(tab.id, in: groupID) }
                    .buttonStyle(.plain).lineLimit(1)
                if board.isDirty {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .accessibilityLabel("Modified")
                }
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close Ensemble", help: "Close Ensemble"
                ) { session.closeCanvas(board.id) }
            }
        }
        .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        .onDrag(
            {
                session.beginDragSourceTracking(dragToken)
                return session.beginEditorDrag(.tab(id: tab.id.rawValue.uuidString))
            },
            preview: {
                RafuDragPreviewLabel(
                    icon: Image(systemName: "rectangle.3.group"), title: board.title)
            }
        )
        .contextMenu {
            Button("Rename Ensemble…") { session.canvasDialog = .renameBoard(board.id) }
            Button("Split Left") { session.splitEditorTab(tab.id, at: .leading) }
            Button("Split Right") { session.splitEditorTab(tab.id, at: .trailing) }
            Button("Close Ensemble") { session.closeCanvas(board.id) }
        }
    }
}
