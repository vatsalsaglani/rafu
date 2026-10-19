import SwiftUI

/// The Canvas List: two native tables (review C13). Row selection follows the
/// board, double-click shows the card on the board, and Delete removes.
struct CanvasListView: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var linkSelection: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Cards")
            cardsTable
            Divider()
            sectionTitle("Links")
            if board.connections.isEmpty {
                Text("No links. Drag from the edge of a card to another card.")
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                linksTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Cards

    private var cardSelection: Binding<Set<CanvasCardID>> {
        Binding(get: { board.selection }, set: { board.select($0) })
    }

    private var cardsTable: some View {
        Table(board.cards, selection: cardSelection) {
            TableColumn("Name") { card in
                Label(
                    CanvasCardPresentation.displayTitle(title: card.title, content: card.content),
                    systemImage: card.content.symbol
                )
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            }
            TableColumn("Type") { card in
                Text(card.content.kindName).foregroundStyle(theme.palette.textSecondary)
            }
            .width(min: 80, ideal: 110, max: 160)
            TableColumn("Links") { card in
                Text("\(linkCount(card))").monospacedDigit()
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .width(min: 40, ideal: 50, max: 80)
            TableColumn("State") { card in
                stateCell(card)
            }
            .width(min: 80, ideal: 110, max: 180)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: CanvasCardID.self) { ids in
            if !ids.isEmpty {
                Button("Show on Board") { showOnBoard(ids) }
                if ids.count == 1, let id = ids.first {
                    Button("Rename…") {
                        showOnBoard(ids)
                        board.renamingCardID = id
                    }
                    Button("Duplicate") { session.duplicateCanvasCard(board.id, id) }
                }
                Divider()
                Button("Remove from Ensemble…", role: .destructive) {
                    board.select(ids)
                    session.closeSelectedCanvasNodes()
                }
            }
        } primaryAction: { ids in
            showOnBoard(ids)
        }
        .onDeleteCommand {
            guard !board.selection.isEmpty else { return }
            session.closeSelectedCanvasNodes()
        }
        .frame(minHeight: 120)
    }

    private func showOnBoard(_ ids: Set<CanvasCardID>) {
        board.select(ids)
        board.showsList = false
        if let id = ids.first { board.revealCard(id) }
    }

    /// The State column's content: for an agent card, the glyph (never
    /// animated in this dense list), its word, and its relative time; every
    /// other card keeps the plain state word.
    @ViewBuilder
    private func stateCell(_ card: CanvasCard) -> some View {
        let commands = CanvasCardCommands(card: card, board: board, session: session)
        if let status = commands.agentCardStatus {
            HStack(spacing: 4) {
                AgentActivityGlyph(status: status, animates: false)
                Text(agentStateText(status: status, date: commands.agentCardStatusDate))
            }
            .foregroundStyle(theme.palette.textSecondary)
        } else {
            Text(commands.stateWord ?? "").foregroundStyle(theme.palette.textSecondary)
        }
    }

    private func agentStateText(status: AgentCardStatus, date: Date?) -> String {
        guard let date else { return status.word }
        return
            "\(status.word) · \(AgentCardElapsed.label(since: date, now: AgentActivityStore.shared.now))"
    }

    private func linkCount(_ card: CanvasCard) -> Int {
        board.connections.filter { $0.from == card.id || $0.to == card.id }.count
    }

    // MARK: Links

    private var linksTable: some View {
        Table(board.connections, selection: $linkSelection) {
            TableColumn("From → To") { connection in
                Text("\(name(connection.from)) → \(name(connection.to))").lineLimit(1)
                    .foregroundStyle(theme.palette.textPrimary)
            }
            TableColumn("Label") { connection in
                Text(connection.label).lineLimit(1)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            TableColumn("Kind") { connection in
                Text(connection.behavior == .session ? "Message link" : "Relationship")
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .width(min: 90, ideal: 120, max: 160)
            TableColumn("State") { connection in
                Text(state(connection)).foregroundStyle(theme.palette.textSecondary)
            }
            .width(min: 70, ideal: 90, max: 140)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Edit Link…") { session.canvasDialog = .connectionLabel(board.id, id) }
            }
            if !ids.isEmpty {
                Button("Remove Link", role: .destructive) { removeLinks(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first { session.canvasDialog = .connectionLabel(board.id, id) }
        }
        .onDeleteCommand { removeLinks(linkSelection) }
        .frame(minHeight: 100)
    }

    private func name(_ id: CanvasCardID) -> String {
        board.cards.first { $0.id == id }?.title ?? "Missing card"
    }

    private func state(_ connection: CanvasConnection) -> String {
        guard connection.behavior == .session else { return "" }
        return CanvasLiveBridge.shared.isEnabled(connection.id, in: board) ? "Live" : "Paused"
    }

    private func removeLinks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.performCanvasEdit(board) {
            try board.edit { $0.connections.removeAll { ids.contains($0.id) } }
            for id in ids { CanvasLiveBridge.shared.disable(id, in: board) }
        }
        linkSelection = []
    }
}
