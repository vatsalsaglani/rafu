import SwiftUI

struct CanvasEditorTabItem: View {
    let tab: EditorTabState
    let groupID: EditorGroupID
    let board: CanvasBoardState
    let isSelected: Bool
    let session: WorkspaceSession

    var body: some View {
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group").accessibilityHidden(true)
                Button(board.title) { session.selectEditorTab(tab.id, in: groupID) }
                    .buttonStyle(.plain).lineLimit(1)
                if board.isDirty {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .accessibilityLabel("Modified")
                }
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close Canvas", help: "Close Canvas"
                ) { session.closeCanvas(board.id) }
            }
        }
        .onDrag { session.beginEditorDrag(.tab(id: tab.id.rawValue.uuidString)) }
        .contextMenu {
            Button("Rename Canvas…") { session.canvasDialog = .renameBoard(board.id) }
            Button("Split Left") { session.splitEditorTab(tab.id, at: .leading) }
            Button("Split Right") { session.splitEditorTab(tab.id, at: .trailing) }
            Button("Close Canvas") { session.closeCanvas(board.id) }
        }
    }
}
