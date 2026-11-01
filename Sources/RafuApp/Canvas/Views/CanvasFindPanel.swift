import SwiftUI

/// Find in Ensemble: a palette over the board (⌘F, the bar's search button,
/// or the command palette row), presented by `CanvasFindOverlay`. Type to match
/// card titles, kinds, agent names, paths, hosts and link names; chips narrow
/// by kind, by agent, or to linked cards; Return (or a click) reveals the
/// card and selects it. The board never moves while the palette is open.
/// Results come from `CanvasBoardSearchIndex`, rebuilt off `body` whenever
/// the board, the query or a filter changes. Highlight changes are immediate.
/// Shows Find in Ensemble as a palette near the top of the board, over a
/// light scrim. A click on the scrim or Esc closes it. It appears without
/// animation: opening find is a frequent keyboard action.
struct CanvasFindOverlay: View {
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        if board.isFindPresented {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .contentShape(.rect)
                    .onTapGesture { board.isFindPresented = false }
                    .accessibilityHidden(true)
                CanvasFindPanel(
                    board: board, session: session,
                    dismiss: { board.isFindPresented = false }
                )
                .padding(.top, 56)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct CanvasFindPanel: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    let dismiss: () -> Void

    @State private var query = ""
    @State private var filter = CanvasSearchFilter()
    @State private var index: CanvasBoardSearchIndex?
    @State private var results: [CanvasSearchItem] = []
    @State private var highlightedID: CanvasCardID?
    @State private var hoveredID: CanvasCardID?
    @FocusState private var queryFocused: Bool

    static let width: CGFloat = 580
    static let resultsHeight: CGFloat = 300

    /// Everything the results depend on. `changeStamp` covers card, title and
    /// link edits; a provider change does not bump it, so reopening refreshes.
    private struct SearchKey: Hashable {
        let stamp: UInt64
        let query: String
        let filter: CanvasSearchFilter
    }

    private var searchKey: SearchKey {
        SearchKey(stamp: board.changeStamp, query: query, filter: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            filterChips
            resultsList
            footer
        }
        .padding(12)
        .frame(maxWidth: Self.width, alignment: .topLeading)
        // The command palette's chrome: one floating panel over the board.
        .background(theme.palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderStrong.opacity(0.5))
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in Ensemble")
        .onAppear { queryFocused = true }
        .task(id: searchKey) { refresh() }
        .onExitCommand { dismiss() }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Find in Ensemble", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($queryFocused)
                .onSubmit { chooseHighlighted() }
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
                .accessibilityLabel("Find in Ensemble")
                .accessibilityHint(
                    "Type a name, kind, agent or link. Up and Down choose, Return goes to the card."
                )
            Text("⌘F")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(theme.palette.chipBackground))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                .fill(theme.palette.fieldBackground)
        )
    }

    // MARK: Filters

    @ViewBuilder private var filterChips: some View {
        if let index, !index.items.isEmpty {
            GitRefPillFlow(spacing: 5, lineSpacing: 5) {
                ForEach(index.categories, id: \.self) { category in
                    chip(
                        category.title,
                        isOn: filter.categories.contains(category),
                        help: "Show only \(category.title) cards"
                    ) { toggle(category) }
                }
                ForEach(index.providers, id: \.self) { provider in
                    chip(
                        provider, isOn: filter.providers.contains(provider),
                        help: "Show only \(provider) terminals"
                    ) { toggle(provider) }
                }
                if index.hasLinks {
                    chip(
                        "Linked", isOn: filter.linkedOnly,
                        help: "Show only cards that have a link"
                    ) { filter.linkedOnly.toggle() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(
        _ title: String, isOn: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? theme.palette.textPrimary : theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? theme.palette.selection : theme.palette.chipBackground)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? theme.palette.borderStrong : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Filter: \(title)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggle(_ category: CanvasSearchCategory) {
        if !filter.categories.insert(category).inserted { filter.categories.remove(category) }
    }

    private func toggle(_ provider: String) {
        if !filter.providers.insert(provider).inserted { filter.providers.remove(provider) }
    }

    // MARK: Results

    @ViewBuilder private var resultsList: some View {
        Group {
            if index == nil {
                Color.clear
            } else if results.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results, id: \.id) { item in
                                row(item)
                            }
                        }
                    }
                    .onChange(of: highlightedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(height: Self.resultsHeight, alignment: .top)
    }

    private var emptyMessage: String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index, index.items.isEmpty { return "This Ensemble has no cards." }
        if !text.isEmpty { return "No cards match “\(text)”." }
        return "No cards match these filters."
    }

    private func row(_ item: CanvasSearchItem) -> some View {
        let isHighlighted = item.id == highlightedID
        return Button {
            go(to: item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(
                        isHighlighted ? theme.palette.textPrimary : theme.palette.textSecondary
                    )
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? item.kindName : item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isHighlighted
                            ? theme.palette.selection
                            : (hoveredID == item.id ? theme.palette.hover : Color.clear))
            )
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredID = item.id
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .accessibilityLabel("\(item.title.isEmpty ? item.kindName : item.title), \(item.subtitle)")
        .accessibilityHint("Goes to this card in the Ensemble")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(countText)
            Spacer(minLength: 0)
            Text("↩ Go to card   ⎋ Close")
                .accessibilityHidden(true)
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.palette.textMuted)
    }

    private var countText: String {
        guard index != nil else { return "" }
        return results.count == 1 ? "1 card" : "\(results.count) cards"
    }

    // MARK: Actions

    private func refresh() {
        let built = CanvasBoardSearchIndex(
            cards: board.cards, connections: board.connections, terminal: terminalInfo)
        index = built
        // A filter whose chip is no longer on the board (the card was
        // removed) would hide every card with no chip to turn it off.
        let kinds = filter.categories.intersection(built.categories)
        let providers = filter.providers.intersection(built.providers)
        let linked = filter.linkedOnly && built.hasLinks
        if kinds != filter.categories || providers != filter.providers
            || linked != filter.linkedOnly
        {
            filter.categories = kinds
            filter.providers = providers
            filter.linkedOnly = linked
            return  // The filter change re-runs this task with the clean filter.
        }
        results = built.matches(query, filter: filter)
        if let highlightedID, results.contains(where: { $0.id == highlightedID }) { return }
        highlightedID = results.first?.id
    }

    /// The live pane behind a terminal card: the agent CLI it runs (the same
    /// rule as the card header) and the name its header shows.
    private func terminalInfo(_ card: CanvasCard) -> CanvasSearchTerminalInfo? {
        guard case .terminal(let groupID) = card.content,
            let pane = session.terminal.terminalGroup(groupID)?.panes.first
        else { return nil }
        var provider: ConductorCLIID?
        if case .directAgentTerminal(let direct) = pane.runtimeKind {
            provider = direct
        } else if pane.status == .live {
            provider = session.terminal.terminalController(for: pane.id)?.resolvedAgentProvider
        }
        let shown =
            TerminalNaming.isAutomaticGroupName(card.title)
            ? pane.explicitUserName?.rawValue : nil
        return CanvasSearchTerminalInfo(providerName: provider?.displayName, shownTitle: shown)
    }

    /// Reads `results` when the key arrives, so a key pressed right after a
    /// refresh never moves over a stale list.
    private func move(by step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let current = results.firstIndex { $0.id == highlightedID } ?? 0
        let next = min(max(current + step, 0), results.count - 1)
        highlightedID = results[next].id
        return .handled
    }

    private func chooseHighlighted() {
        guard let item = results.first(where: { $0.id == highlightedID }) else { return }
        go(to: item)
    }

    private func go(to item: CanvasSearchItem) {
        dismiss()
        session.focusCanvasCard(item.id, in: board)
    }
}
