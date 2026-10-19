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
    @State private var isHovering = false

    /// Window redesign phase 4b: this board-level tab shows one activity
    /// dot for the whole Ensemble, not per card — warning, and only when
    /// some card's agent is waiting on an approval. Resolved through the
    /// same `CanvasCardCommands.agentCardStatus` every card header already
    /// uses, so the tab and the card it summarizes can never disagree.
    private var hasCardNeedingApproval: Bool {
        board.cards.contains { card in
            guard
                case .needsYou = CanvasCardCommands(card: card, board: board, session: session)
                    .agentCardStatus
            else { return false }
            return true
        }
    }

    var body: some View {
        let activityKind: EditorTabActivityKind? = hasCardNeedingApproval ? .needsYou : nil
        let selectTab = { session.selectEditorTab(tab.id, in: groupID) }
        AttachedWorkbenchTab(
            isSelected: isSelected, usesDocumentWidth: true, select: selectTab
        ) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: CanvasBoardState.ensembleSymbol).accessibilityHidden(true)
                    Text(board.title).lineLimit(1)
                }
                .workbenchTabLabel(
                    board.title,
                    value: [
                        isSelected ? "Selected" : nil,
                        board.isDirty ? "Modified" : nil,
                        hasCardNeedingApproval ? "Needs approval" : nil,
                    ]
                    .compactMap(\.self).joined(separator: ", "),
                    isSelected: isSelected, select: selectTab)
                if board.isDirty {
                    // Redundant with the label's "Modified" value.
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .accessibilityHidden(true)
                }
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close Ensemble", help: "Close Ensemble",
                    presentation: EditorTabAccessory.resolve(
                        isSelected: isSelected, isHovering: isHovering, isDirty: false,
                        activity: activityKind
                    )
                ) { session.closeCanvas(board.id) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovering = $0 }
        .tabHoverPreview(
            isHovering: isHovering,
            content: TabHoverPreviewContentBuilder.ensemble(
                title: board.title, hasCardNeedingApproval: hasCardNeedingApproval)
        )
        .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        .onDrag(
            {
                session.beginDragSourceTracking(dragToken)
                return session.beginEditorDrag(.tab(id: tab.id.rawValue.uuidString))
            },
            preview: {
                RafuDragPreviewLabel(
                    icon: Image(systemName: CanvasBoardState.ensembleSymbol), title: board.title)
            }
        )
        .contextMenu {
            Button("Rename Ensemble…") { session.canvasDialog = .renameBoard(board.id) }
            Button("Split Left") { session.splitEditorTab(tab.id, at: .leading) }
            Button("Split Right") { session.splitEditorTab(tab.id, at: .trailing) }
            Button("Close Ensemble") { session.closeCanvas(board.id) }
        }
        .accessibilityElement(children: .contain)
    }
}
