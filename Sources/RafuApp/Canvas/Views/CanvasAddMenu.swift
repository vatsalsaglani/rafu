import SwiftUI

/// What the Add menu and the Add popover can make (review C19, 7.4).
enum CanvasAddKind: CaseIterable, Identifiable {
    case note, terminal, file, image, webApp, macApp

    var id: Self { self }

    /// The kinds whose title contains `query` (case-insensitive), in menu
    /// order. An empty query matches every kind.
    static func matches(_ query: String) -> [CanvasAddKind] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return allCases }
        return allCases.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var title: String {
        switch self {
        case .note: "Note"
        case .terminal: "Terminal"
        case .file: "File…"
        case .image: "Image…"
        case .webApp: "Web App…"
        case .macApp: "Mac App…"
        }
    }

    var symbol: String {
        switch self {
        case .note: "note.text"
        case .terminal: "apple.terminal"
        case .file: "doc"
        case .image: "photo"
        case .webApp: "globe"
        case .macApp: "macwindow"
        }
    }

    /// Adds the card. With `center` (board units) it appears there; otherwise
    /// at the middle of the visible board. Nothing starts: a terminal is made
    /// stopped, a web app unloaded, a Mac app unopened.
    @MainActor
    func perform(on board: CanvasBoardState, session: WorkspaceSession, center: CGPoint? = nil) {
        board.creationCenter = center
        switch self {
        case .note: session.addCanvasNote(board.id)
        case .terminal: session.addCanvasStoppedTerminal(board.id)
        case .file: session.chooseCanvasFile(board.id, imageOnly: false)
        case .image: session.chooseCanvasFile(board.id, imageOnly: true)
        case .webApp: session.canvasDialog = .web(board.id)
        case .macApp: session.chooseCanvasApplication(board.id)
        }
    }
}

/// One row the Add menu or the Add popover can create: a fixed card kind, or
/// (on a machine with more than one shell) a specific shell's terminal
/// (terminal-manager.md T-C; review C19, 7.4).
enum CanvasAddItem: Equatable, Identifiable {
    case kind(CanvasAddKind)
    case terminalShell(TerminalShell)

    var id: String {
        switch self {
        case .kind(let kind): "kind.\(kind.rawID)"
        case .terminalShell(let shell): "shell:\(shell.path)"
        }
    }

    var symbol: String {
        switch self {
        case .kind(let kind): kind.symbol
        case .terminalShell: "apple.terminal"
        }
    }

    /// `shells` is the full catalog, needed only to de-duplicate a shell
    /// row's name against another shell of the same name
    /// (`TerminalNaming.shellMenuTitle`); a kind row ignores it.
    func title(amongShells shells: [TerminalShell]) -> String {
        switch self {
        case .kind(let kind): kind.title
        case .terminalShell(let shell):
            "Terminal — " + TerminalNaming.shellMenuTitle(for: shell, among: shells)
        }
    }

    /// Every row the Add popover offers: the fixed kinds, then one row per
    /// shell — but only when the machine has more than one shell. A single
    /// shell has nothing to choose between, so the plain "Terminal" kind
    /// stays the only terminal row.
    static func all(shells: [TerminalShell]) -> [CanvasAddItem] {
        CanvasAddKind.allCases.map(CanvasAddItem.kind)
            + (shells.count >= 2 ? shells.map(CanvasAddItem.terminalShell) : [])
    }

    /// The rows whose title contains `query` (case-insensitive), in
    /// `all(shells:)` order. An empty query matches every row.
    static func matches(_ query: String, shells: [TerminalShell]) -> [CanvasAddItem] {
        let items = all(shells: shells)
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return items }
        return items.filter { $0.title(amongShells: shells).localizedCaseInsensitiveContains(text) }
    }

    /// Adds the card, same placement rule as `CanvasAddKind.perform`.
    @MainActor
    func perform(on board: CanvasBoardState, session: WorkspaceSession, center: CGPoint? = nil) {
        switch self {
        case .kind(let kind): kind.perform(on: board, session: session, center: center)
        case .terminalShell(let shell):
            board.creationCenter = center
            session.addCanvasStoppedTerminal(board.id, shell: shell)
        }
    }
}

extension CanvasAddKind {
    /// A stable string for `CanvasAddItem.id`. `CanvasAddKind.id` is `Self`
    /// itself (no raw value), so this gives it one.
    fileprivate var rawID: String {
        switch self {
        case .note: "note"
        case .terminal: "terminal"
        case .file: "file"
        case .image: "image"
        case .webApp: "webApp"
        case .macApp: "macApp"
        }
    }
}

/// Grouped items: [Note, Terminal (with Shell)] [File…, Image…] [Web App…, Mac App…].
struct CanvasAddMenuItems: View {
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        item(.note)
        item(.terminal)
        let shells = session.availableTerminalShells
        if shells.count >= 2 {
            Menu("Terminal with Shell") {
                ForEach(shells) { shell in
                    Button(TerminalNaming.shellMenuTitle(for: shell, among: shells)) {
                        session.addCanvasStoppedTerminal(board.id, shell: shell)
                    }
                }
            }
        }
        Divider()
        item(.file)
        item(.image)
        Divider()
        item(.webApp)
        item(.macApp)
        CanvasDiagramAddMenuItem(board: board, session: session)  // X9 diagrams
    }

    private func item(_ kind: CanvasAddKind) -> some View {
        Button(kind.title, systemImage: kind.symbol) {
            kind.perform(on: board, session: session)
        }
    }
}

/// The "+" pull-down in the Canvas bar.
struct CanvasAddCardMenu: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        Menu {
            CanvasAddMenuItems(board: board, session: session)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .tint(theme.palette.textSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(board.cards.count >= CanvasLimits.cards)
        .help("Add to Ensemble")
        .accessibilityLabel("Add to Ensemble")
    }
}

/// Double-click on the empty board: pick a card type with type-ahead. Return
/// makes the first match; the card is centred on the clicked point.
struct CanvasAddPopover: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    let boardPoint: CGPoint
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var hovered: CanvasAddItem?
    @FocusState private var queryFocused: Bool

    private var shells: [TerminalShell] { session.availableTerminalShells }

    var body: some View {
        let items = CanvasAddItem.matches(query, shells: shells)
        let current = items.indices.contains(highlighted) ? items[highlighted] : nil
        VStack(alignment: .leading, spacing: 4) {
            searchField(items)
            Divider().padding(.vertical, 2)
            ForEach(items) { item in
                row(item, isHighlighted: item == current)
            }
            if items.isEmpty {
                Text("No matching card type")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .padding(8)
        .frame(width: 220)
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand { dismiss() }
    }

    private func searchField(_ matches: [CanvasAddItem]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Add a card", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($queryFocused)
                .onSubmit {
                    if matches.indices.contains(highlighted) { choose(matches[highlighted]) }
                }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(0, matches.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .accessibilityLabel("Add a card")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                .fill(theme.palette.fieldBackground)
        )
    }

    /// One row. The highlighted row (Return target) uses the selection
    /// fill; hover uses the lighter hover fill. No gold.
    private func row(_ item: CanvasAddItem, isHighlighted: Bool) -> some View {
        let title = item.title(amongShells: shells)
        return Button {
            choose(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: 4)
                if isHighlighted {
                    Text("↩")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textMuted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseSelection)
                    .fill(rowFill(item, isHighlighted: isHighlighted))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = item
            } else if hovered == item {
                hovered = nil
            }
        }
        .accessibilityLabel(title)
        .modifier(CanvasAddItemShellHint(item: item))
    }

    private func rowFill(_ item: CanvasAddItem, isHighlighted: Bool) -> Color {
        if isHighlighted { return theme.palette.selection }
        return hovered == item ? theme.palette.hover : Color.clear
    }

    private func choose(_ item: CanvasAddItem) {
        dismiss()
        item.perform(on: board, session: session, center: boardPoint)
    }
}

/// A shell row gets an accessibility hint explaining what makes it different
/// from the plain "Terminal" row; every other row is unchanged.
private struct CanvasAddItemShellHint: ViewModifier {
    let item: CanvasAddItem

    func body(content: Content) -> some View {
        if case .terminalShell = item {
            content.accessibilityHint("Add a terminal that runs this shell")
        } else {
            content
        }
    }
}
