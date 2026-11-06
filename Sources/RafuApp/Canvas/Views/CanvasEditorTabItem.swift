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
    /// True for `RafuMotion.successHold` after each save (UX Round C, W2).
    /// An autosaving board shows no dirty dot.
    @State private var showsSavedTick = false
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// Round B (E1): the "needs you"/"failed" fold the bar uses, so the tab
    /// pill, the bar's jump menus and the Dock badge read one count.
    private var agentSummary: CanvasAgentSummaryItem {
        CanvasAgentSummaryItem(board: board, session: session)
    }

    var body: some View {
        let activityKind: EditorTabActivityKind? = hasCardNeedingApproval ? .needsYou : nil
        let selectTab = { session.selectEditorTab(tab.id, in: groupID) }
        // One click handler for the whole tab: select at once, and rename on
        // the second click of a double-click. A second, count-2 tap gesture
        // would delay every single click.
        let selectOrRename = {
            selectTab()
            if TabClickIntent.current() == .selectAndRename { rename() }
        }
        let summary = agentSummary
        let pill = EnsembleTabPill.resolve(summary)
        let dockCounts = [summary.needsYou.count, summary.failed.count]
        AttachedWorkbenchTab(
            isSelected: isSelected, usesDocumentWidth: true, select: selectOrRename
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
                        board.isDirty || board.isSaving
                            ? "Saving" : showsSavedTick ? "Saved" : nil,
                        // The pill's words say it with the count when present.
                        pill == nil && hasCardNeedingApproval ? "Needs approval" : nil,
                        pill?.accessibilityValue,
                    ]
                    .compactMap(\.self).joined(separator: ", "),
                    isSelected: isSelected, select: selectTab)
                if let pill {
                    EnsembleTabPillButton(pill: pill) {
                        showFirstCard(of: pill, in: summary, selectTab: selectTab)
                    }
                }
                if showsSavedTick {
                    // Redundant with the label's "Saved" value.
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.textSecondary)
                        .transition(.opacity)
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
                title: board.title, hasCardNeedingApproval: hasCardNeedingApproval,
                needsYou: summary.needsYou.count, failed: summary.failed.count)
        )
        .task(id: board.lastSavedAt) { await showSavedTick() }
        .onChange(of: dockCounts, initial: true) { DockAttentionBadge.refresh() }
        .onDisappear { DockAttentionBadge.refreshSoon() }
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
            // The board's name lives on this tab only (UX Round C, W1), so
            // the actions the bar's name menu held are here and in the
            // menu bar's Ensemble menu.
            Button("Rename Ensemble…") { rename() }
            Button("Duplicate Ensemble") { session.saveCanvasCopy(board.id) }
            Divider()
            Button("Split Left") { session.splitEditorTab(tab.id, at: .leading) }
            Button("Split Right") { session.splitEditorTab(tab.id, at: .trailing) }
            Divider()
            if !recentCanvases.isEmpty {
                Section("Recent") {
                    ForEach(recentCanvases) { item in
                        Button(item.title) { Task { await session.openCanvas(item.id) } }
                    }
                }
            }
            Button("Open Ensemble…") { session.requestCanvasLibrary() }
            Divider()
            Button("Close Ensemble") { session.closeCanvas(board.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Rename") { rename() }
    }

    private func rename() {
        session.canvasDialog = .renameBoard(board.id)
    }

    private var recentCanvases: [CanvasSummary] {
        CanvasRecentBoards.recents(session.canvas.library, excluding: board.id)
    }

    /// Shows the tick for `RafuMotion.successHold` after a save that left the
    /// board clean. Reduce Motion: it appears and goes with no fade.
    private func showSavedTick() async {
        // A tab that reappears later must not replay an old tick.
        guard let saved = board.lastSavedAt,
            Date().timeIntervalSince(saved) < RafuMotion.successHold
        else { return }
        setSavedTick(true)
        do {
            try await Task.sleep(for: .seconds(RafuMotion.successHold))
        } catch {
            return
        }
        setSavedTick(false)
    }

    private func setSavedTick(_ shows: Bool) {
        if let animation = RafuMotion.resolve(RafuMotion.stateCrossFade, reduceMotion: reduceMotion)
        {
            withAnimation(animation) { showsSavedTick = shows }
        } else {
            showsSavedTick = shows
        }
    }

    /// Selects this tab when another is selected, then reveals the first card
    /// the pill counts — the same call the bar's jump menu makes.
    private func showFirstCard(
        of pill: EnsembleTabPill, in summary: CanvasAgentSummaryItem, selectTab: () -> Void
    ) {
        let entries = pill.kind == .failed ? summary.failed : summary.needsYou
        if !isSelected { selectTab() }
        guard let first = entries.first else { return }
        session.focusCanvasCard(first.id, in: board)
    }
}
