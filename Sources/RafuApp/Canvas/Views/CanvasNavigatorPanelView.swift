import SwiftUI

struct CanvasNavigatorPanelView: View {
    let session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme
    @State private var rows = Rows()
    @State private var selection: String?
    @State private var refreshCount = 0

    private struct Rows {
        var root: URL?
        var activeBoard: CanvasID?
        var boards: [CanvasNavigatorBoardRow] = []
        var nodes: [CanvasNavigatorNodeRow] = []
    }

    private struct RowInputs: Equatable {
        let root: URL?
        let library: [CanvasSummary]
        let open: [CanvasID: CanvasNavigatorOpenBoard]
        let openElsewhere: Set<CanvasID>
        let activeBoard: CanvasID?
        let activeInstance: ObjectIdentifier?
        let changeStamp: UInt64?
        let refreshCount: Int
    }

    var body: some View {
        let board = session.selectedCanvas
        let inputs = rowInputs(for: board)
        let boards = rows.root == inputs.root ? rows.boards : []
        let nodes = rows.root == inputs.root && rows.activeBoard == board?.id ? rows.nodes : []
        VStack(spacing: 0) {
            header(count: boards.count)
            if let notice = session.canvas.libraryNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .help(notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RafuMetrics.sidebarTextInset)
                    .padding(.bottom, 8)
            }
            if !boards.isEmpty {
                ensembleList(boards, nodes: nodes, activeBoard: board)
            } else if session.canvas.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: session.selectedCanvasID, initial: true) { _, id in
            selection = id.map(CanvasNavigatorModel.selectionID(board:))
        }
        .task(id: session.rootURL) {
            await session.prepareCanvasLibrary()
        }
        .task(id: inputs) {
            guard !Task.isCancelled else { return }
            rebuildRows(inputs, board: board)
        }
    }

    private func header(count: Int) -> some View {
        RafuUtilityPanelHeader(
            title: "Ensembles",
            context: {
                RafuPanelHeaderCount(
                    count: count,
                    accessibilityLabel: count == 1 ? "1 Ensemble" : "\(count) Ensembles")
            },
            actions: {
                Button(action: session.requestNewCanvas) {
                    Label("New Ensemble", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .help("New Ensemble")
                RafuPanelHeaderOverflowMenu(accessibilityLabel: "Ensemble Actions") {
                    Button("Open Ensemble…", action: session.requestCanvasLibrary)
                    Button("Refresh") {
                        Task {
                            await session.prepareCanvasLibrary()
                            refreshCount += 1
                        }
                    }
                }
            }
        )
    }

    private var emptyState: some View {
        RafuPanelEmptyState(
            icon: CanvasBoardState.ensembleSymbol, title: "No Ensembles",
            message: "Create an Ensemble to arrange terminals, notes and diagrams on one board.",
            compact: true
        ) {
            Button("New Ensemble…", action: session.requestNewCanvas)
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
    }

    private func ensembleList(
        _ boards: [CanvasNavigatorBoardRow], nodes: [CanvasNavigatorNodeRow],
        activeBoard: CanvasBoardState?
    ) -> some View {
        List(selection: $selection) {
            Section {
                ForEach(boards) { row in
                    boardRow(row)
                        .tag(CanvasNavigatorModel.selectionID(board: row.id))
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                }
            } header: {
                RafuSidebarSectionHeader(title: "Ensembles")
                    .padding(.horizontal, RafuMetrics.sidebarTextInset)
            }

            if let activeBoard {
                Section {
                    ForEach(nodes) { row in
                        let id = CanvasNavigatorModel.selectionID(node: row.id)
                        CanvasNavigatorNodeRowView(
                            row: row, session: session, isSelected: selection == id
                        ) {
                            reveal(row.id, in: activeBoard)
                        }
                        .tag(id)
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    RafuSidebarSectionHeader(title: "Nodes", count: nodes.count)
                        .padding(.horizontal, RafuMetrics.sidebarTextInset)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OverlayScrollerConfigurator(knobStyle: theme.isDark ? .light : .dark))
        .tint(theme.palette.selection)
        .onKeyPress(keys: [.return, .space]) { _ in
            guard let selection else { return .ignored }
            if let row = boards.first(where: {
                CanvasNavigatorModel.selectionID(board: $0.id) == selection
            }) {
                open(row.id)
            } else if let activeBoard,
                let row = nodes.first(where: {
                    CanvasNavigatorModel.selectionID(node: $0.id) == selection
                })
            {
                reveal(row.id, in: activeBoard)
            } else {
                return .ignored
            }
            return .handled
        }
        .accessibilityLabel("Ensembles")
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4)
    }

    private func boardRow(_ row: CanvasNavigatorBoardRow) -> some View {
        CanvasNavigatorRowLabel(
            symbol: CanvasBoardState.ensembleSymbol, title: row.title, caption: row.caption,
            isSelected: selection == CanvasNavigatorModel.selectionID(board: row.id),
            isCurrent: row.isCurrent,
            spokenValue: CanvasNavigatorModel.boardAccessibilityValue(row),
            activate: { open(row.id) }
        ) {
            if let trailing = row.trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Open") { open(row.id) }
            if row.isOpen {
                Button("Rename…") { session.canvasDialog = .renameBoard(row.id) }
                Button("Duplicate") { session.saveCanvasCopy(row.id) }
                Button("Close") { session.closeCanvas(row.id) }
            } else if let summary = row.summary, !row.isFileBound {
                Button("Delete Saved Ensemble…", role: .destructive) {
                    session.canvasDialog = .deleteSaved(summary)
                }
            }
        }
    }

    private func open(_ id: CanvasID) {
        let root = rows.root
        guard root != nil, root == session.rootURL else { return }
        selection = CanvasNavigatorModel.selectionID(board: id)
        Task {
            guard session.rootURL == root else { return }
            await session.openCanvas(id)
        }
    }

    private func reveal(_ id: CanvasCardID, in board: CanvasBoardState) {
        guard session.selectedCanvas === board else { return }
        selection = CanvasNavigatorModel.selectionID(node: id)
        session.focusCanvasCard(id, in: board)
    }

    private func rowInputs(for board: CanvasBoardState?) -> RowInputs {
        let open = session.canvas.boards.mapValues { board in
            CanvasNavigatorOpenBoard(
                id: board.id, title: board.title, cardCount: board.cards.count,
                filePath: session.canvas.fileBindings[board.id]?.relativePath)
        }
        return RowInputs(
            root: session.rootURL, library: session.canvas.library, open: open,
            openElsewhere: session.canvasIDsOpenInOtherWindows(),
            activeBoard: board?.id, activeInstance: board.map(ObjectIdentifier.init),
            changeStamp: board?.changeStamp, refreshCount: refreshCount)
    }

    private func rebuildRows(_ inputs: RowInputs, board: CanvasBoardState?) {
        let boards = CanvasNavigatorModel.boardRows(
            library: inputs.library, open: inputs.open, current: inputs.activeBoard,
            openElsewhere: inputs.openElsewhere)
        var nodes: [CanvasNavigatorNodeRow] = []
        if let board {
            let cards = board.cards
            let index = CanvasBoardSearchIndex(
                cards: cards, connections: board.connections,
                terminal: session.canvasSearchTerminalInfo(for:))
            var terminalGroups: [CanvasCardID: TerminalGroupID] = [:]
            for card in cards {
                if case .terminal(let groupID) = card.content { terminalGroups[card.id] = groupID }
            }
            nodes = CanvasNavigatorModel.nodeRows(
                items: index.items, terminalGroups: terminalGroups)
        }
        rows = Rows(
            root: inputs.root, activeBoard: inputs.activeBoard, boards: boards, nodes: nodes)
        if let selection,
            !boards.contains(where: { CanvasNavigatorModel.selectionID(board: $0.id) == selection }
            ),
            !nodes.contains(where: { CanvasNavigatorModel.selectionID(node: $0.id) == selection })
        {
            self.selection = inputs.activeBoard.map(CanvasNavigatorModel.selectionID(board:))
        }
    }
}

private struct CanvasNavigatorNodeRowView: View {
    let row: CanvasNavigatorNodeRow
    let session: WorkspaceSession
    let isSelected: Bool
    let activate: () -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let status = agentStatus
        CanvasNavigatorRowLabel(
            symbol: row.symbol, title: row.title, caption: row.caption,
            isSelected: isSelected, isCurrent: false,
            spokenValue: CanvasNavigatorModel.nodeAccessibilityValue(row, status: status),
            activate: activate
        ) {
            if let status {
                AgentActivityGlyph(status: status, animates: false)
                if let word = CanvasNavigatorModel.statusWord(status) {
                    Text(word)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    // Agent hooks update the observed activity store without editing the board.
    // Read their live status here so those events invalidate only terminal rows.
    private var agentStatus: AgentCardStatus? {
        guard let groupID = row.terminalGroupID,
            let pane = session.terminal.terminalGroup(groupID)?.panes.first
        else { return nil }
        return CanvasCardCommands.agentCardStatus(pane: pane, in: session)
    }
}

private struct CanvasNavigatorRowLabel<Trailing: View>: View {
    let symbol: String
    let title: String
    let caption: String
    let isSelected: Bool
    let isCurrent: Bool
    let spokenValue: String
    let activate: () -> Void
    @ViewBuilder let trailing: Trailing

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, RafuMetrics.sidebarTextInset - 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(.rect)
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: 5).fill(theme.palette.hover)
            }
        }
        .overlay {
            if isSelected && contrast == .increased {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture(perform: activate)
        .help("\(title)\n\(caption)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
    }
}
