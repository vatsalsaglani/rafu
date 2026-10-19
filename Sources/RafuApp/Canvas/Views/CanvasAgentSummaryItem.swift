import SwiftUI

/// One Ensemble's terminal-card agent counts, folded once from the board's
/// cards and each card's resolved `AgentCardStatus`. Pure so the counts and
/// the jump-menu ordering stay testable without a live board or store.
nonisolated struct CanvasAgentSummaryItem: Equatable {
    /// One card listed under "needs you" or "failed", in board order.
    struct Entry: Equatable, Identifiable {
        let id: CanvasCardID
        let title: String
    }

    let agents: Int
    let working: Int
    let needsYou: [Entry]
    let failed: [Entry]

    /// `status` resolves one card's agent status (or `nil` for every
    /// non-agent card); the caller supplies it so this stays independent of
    /// `WorkspaceSession`/`AgentActivityStore`.
    init(cards: [CanvasCard], status: (CanvasCard) -> AgentCardStatus?) {
        var agents = 0
        var working = 0
        var needsYou: [Entry] = []
        var failed: [Entry] = []
        for card in cards {
            guard let cardStatus = status(card) else { continue }
            agents += 1
            switch cardStatus {
            case .working: working += 1
            case .needsYou: needsYou.append(Entry(id: card.id, title: card.title))
            case .failed: failed.append(Entry(id: card.id, title: card.title))
            case .doneUnread, .done, .inactive, .stopped: break
            }
        }
        self.agents = agents
        self.working = working
        self.needsYou = needsYou
        self.failed = failed
    }
}

/// The Canvas bar's agent-count summary (user request: "8 agents · 4
/// running · [1 needs you ⌄] · [1 failed ⌄]"): plain counts first, which
/// collapse first on a narrow bar, then an amber "needs you" pill and a red
/// "failed" pill — each a jump menu to the matching cards, shown only while
/// non-zero.
struct CanvasAgentSummaryBar: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession

    private var summary: CanvasAgentSummaryItem {
        CanvasAgentSummaryItem(cards: board.cards) { card in
            guard case .terminal(let groupID) = card.content,
                let pane = session.terminal.terminalGroup(groupID)?.panes.first
            else { return nil }
            return CanvasCardCommands.agentCardStatus(pane: pane, in: session)
        }
    }

    var body: some View {
        let summary = summary
        if summary.agents > 0 || !summary.needsYou.isEmpty || !summary.failed.isEmpty {
            HStack(spacing: 6) {
                if summary.agents > 0 {
                    Text(
                        "\(summary.agents) agent\(summary.agents == 1 ? "" : "s") · \(summary.working) working"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                }
                if !summary.needsYou.isEmpty {
                    jumpMenu(
                        title: "\(summary.needsYou.count) needs you", entries: summary.needsYou,
                        tint: theme.palette.warning)
                }
                if !summary.failed.isEmpty {
                    jumpMenu(
                        title: "\(summary.failed.count) failed", entries: summary.failed,
                        tint: theme.palette.error)
                }
            }
        }
    }

    private func jumpMenu(title: String, entries: [CanvasAgentSummaryItem.Entry], tint: Color)
        -> some View
    {
        Menu {
            ForEach(entries) { entry in
                Button(entry.title) { session.focusCanvasCard(entry.id, in: board) }
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.18)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}
