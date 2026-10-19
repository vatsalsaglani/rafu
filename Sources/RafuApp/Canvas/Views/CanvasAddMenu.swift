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

/// The "+" in the Ensemble bar. It opens the same Add palette as a
/// double-click on the board; the card lands at the middle of the visible
/// board. The menu bar keeps the classic list (`CanvasAddMenuItems`).
struct CanvasAddCardMenu: View {
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Add to Ensemble", systemImage: "plus")
        }
        .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 13))
        .disabled(board.cards.count >= CanvasLimits.cards)
        .help("Add to Ensemble")
        .accessibilityLabel("Add to Ensemble")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CanvasAddPopover(
                board: board, session: session, boardPoint: nil,
                dismiss: { isPresented = false })
        }
    }
}

/// One cell of the Add palette: a card-type tile, the icon-library tile, or
/// a shell chip. Tiles come first, then chips; that is also the keyboard
/// order.
enum CanvasAddPaletteEntry: Equatable, Identifiable {
    case item(CanvasAddItem)
    case serviceIcon

    static let serviceIconTitle = "Service Icon…"

    var id: String {
        switch self {
        case .item(let item): item.id
        case .serviceIcon: "serviceIcon"
        }
    }

    var isChip: Bool {
        if case .item(.terminalShell) = self { return true }
        return false
    }

    /// Tiles (every matching card kind, then the icon library) followed by
    /// chips (the matching shells, only on a machine with two or more).
    /// Same type-ahead as `CanvasAddItem.matches`.
    static func entries(matching query: String, shells: [TerminalShell]) -> [Self] {
        let items = CanvasAddItem.matches(query, shells: shells)
        let text = query.trimmingCharacters(in: .whitespaces)
        let tiles = items.filter { if case .kind = $0 { true } else { false } }.map(Self.item)
        let library: [Self] =
            text.isEmpty || serviceIconTitle.localizedCaseInsensitiveContains(text)
            ? [.serviceIcon] : []
        let chips = items.filter { if case .terminalShell = $0 { true } else { false } }
            .map(Self.item)
        return tiles + library + chips
    }
}

/// Arrow-key movement over the Add palette: a 3-column tile grid followed by
/// a 2-column chip grid, row-major. Pure, so it is unit-tested.
nonisolated enum CanvasAddPaletteNavigation {
    static let tileColumns = 3
    static let chipColumns = 2

    enum Direction { case left, right, up, down }

    static func move(
        _ index: Int, _ direction: Direction, tileCount: Int, chipCount: Int
    ) -> Int {
        let total = tileCount + chipCount
        guard total > 0 else { return 0 }
        let index = min(max(index, 0), total - 1)
        let inChips = index >= tileCount
        switch direction {
        case .left:
            return max(index - 1, 0)
        case .right:
            return min(index + 1, total - 1)
        case .down:
            if inChips {
                let next = index + chipColumns
                return next < total ? next : index
            }
            if index + tileColumns < tileCount { return index + tileColumns }
            // A short last row with no tile in this column: its last tile.
            let lastRow = (tileCount - 1) / tileColumns
            if index / tileColumns < lastRow { return tileCount - 1 }
            guard chipCount > 0 else { return index }
            return tileCount + min(index % tileColumns, chipColumns - 1, chipCount - 1)
        case .up:
            if !inChips {
                return index - tileColumns >= 0 ? index - tileColumns : index
            }
            let chip = index - tileCount
            if chip - chipColumns >= 0 { return index - chipColumns }
            guard tileCount > 0 else { return index }
            let lastRowStart = ((tileCount - 1) / tileColumns) * tileColumns
            return min(lastRowStart + chip % chipColumns, tileCount - 1)
        }
    }
}

/// The Add palette: search on top, a grid of card-type tiles, then (with two
/// or more shells) one chip per shell. Opened by the bar's "+" (card at the
/// visible centre, `boardPoint == nil`) and by a double-click on the board
/// (card at the clicked point). Type to filter, arrows to move, Return to
/// add, Escape to close. Highlight changes are immediate, never animated.
struct CanvasAddPopover: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    /// Board-space centre for the new card, or `nil` for the middle of the
    /// visible board.
    let boardPoint: CGPoint?
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var hovered: String?
    @FocusState private var queryFocused: Bool

    private var shells: [TerminalShell] { session.availableTerminalShells }

    var body: some View {
        let entries = CanvasAddPaletteEntry.entries(matching: query, shells: shells)
        let tiles = entries.filter { !$0.isChip }
        let chips = entries.filter(\.isChip)
        let current = entries.indices.contains(highlighted) ? entries[highlighted] : nil
        VStack(alignment: .leading, spacing: 10) {
            searchField(entries, tileCount: tiles.count, chipCount: chips.count)
            if !tiles.isEmpty {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(Self.tileSize.width), spacing: 8),
                        count: CanvasAddPaletteNavigation.tileColumns),
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(tiles) { entry in
                        tile(entry, isHighlighted: entry == current)
                    }
                }
            }
            if !chips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shells")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 6),
                            count: CanvasAddPaletteNavigation.chipColumns),
                        alignment: .leading, spacing: 6
                    ) {
                        ForEach(chips) { entry in
                            chip(entry, isHighlighted: entry == current)
                        }
                    }
                }
            }
            if entries.isEmpty {
                Text("No matching card type")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
        }
        .padding(10)
        .frame(width: 300, alignment: .topLeading)
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand { dismiss() }
    }

    static let tileSize = CGSize(width: 88, height: 64)

    private func searchField(
        _ entries: [CanvasAddPaletteEntry], tileCount: Int, chipCount: Int
    ) -> some View {
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
                    if entries.indices.contains(highlighted) { choose(entries[highlighted]) }
                }
                .onKeyPress(.downArrow) {
                    move(.down, tileCount: tileCount, chipCount: chipCount)
                }
                .onKeyPress(.upArrow) {
                    move(.up, tileCount: tileCount, chipCount: chipCount)
                }
                // Left and Right move the highlight only while the field is
                // empty; once there is text they edit it as usual.
                .onKeyPress(.leftArrow) {
                    guard query.isEmpty else { return .ignored }
                    return move(.left, tileCount: tileCount, chipCount: chipCount)
                }
                .onKeyPress(.rightArrow) {
                    guard query.isEmpty else { return .ignored }
                    return move(.right, tileCount: tileCount, chipCount: chipCount)
                }
                .accessibilityLabel("Add a card")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                .fill(theme.palette.fieldBackground)
        )
    }

    private func move(
        _ direction: CanvasAddPaletteNavigation.Direction, tileCount: Int, chipCount: Int
    ) -> KeyPress.Result {
        highlighted = CanvasAddPaletteNavigation.move(
            highlighted, direction, tileCount: tileCount, chipCount: chipCount)
        return .handled
    }

    /// A card-type tile: an 18 pt symbol over an 11 pt label. The
    /// highlighted tile (Return target) uses the selection fill and a strong
    /// hairline; hover uses the lighter hover fill.
    private func tile(_ entry: CanvasAddPaletteEntry, isHighlighted: Bool) -> some View {
        let title = title(of: entry)
        return Button {
            choose(entry)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol(of: entry))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(
                        isHighlighted ? theme.palette.textPrimary : theme.palette.textSecondary
                    )
                    .frame(height: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 4)
            .frame(width: Self.tileSize.width, height: Self.tileSize.height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill(entry, isHighlighted: isHighlighted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? theme.palette.borderStrong : Color.clear, lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover(entry, inside: $0) }
        .help(entry == .serviceIcon ? "Open the icon library" : "Add \(title)")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// A shell chip: terminal glyph, shell name, and its ⌃⌥n shortcut for the
    /// first nine shells (`CanvasCommands.terminalShellShortcutItems`).
    private func chip(_ entry: CanvasAddPaletteEntry, isHighlighted: Bool) -> some View {
        let title = title(of: entry)
        return Button {
            choose(entry)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .accessibilityHidden(true)
                Text(shellName(of: entry))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let hint = shortcutHint(of: entry) {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.textMuted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(chipFill(entry, isHighlighted: isHighlighted)))
            .overlay(
                Capsule().strokeBorder(
                    isHighlighted ? theme.palette.borderStrong : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover(entry, inside: $0) }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .modifier(CanvasAddItemShellHint(entry: entry))
    }

    private func hover(_ entry: CanvasAddPaletteEntry, inside: Bool) {
        if inside {
            hovered = entry.id
        } else if hovered == entry.id {
            hovered = nil
        }
    }

    private func fill(_ entry: CanvasAddPaletteEntry, isHighlighted: Bool) -> Color {
        if isHighlighted { return theme.palette.selection }
        return hovered == entry.id ? theme.palette.hover : theme.palette.cardBackground
    }

    private func chipFill(_ entry: CanvasAddPaletteEntry, isHighlighted: Bool) -> Color {
        if isHighlighted { return theme.palette.selection }
        return hovered == entry.id ? theme.palette.hover : theme.palette.chipBackground
    }

    private func title(of entry: CanvasAddPaletteEntry) -> String {
        switch entry {
        case .item(let item): item.title(amongShells: shells)
        case .serviceIcon: CanvasAddPaletteEntry.serviceIconTitle
        }
    }

    private func symbol(of entry: CanvasAddPaletteEntry) -> String {
        switch entry {
        case .item(let item): item.symbol
        case .serviceIcon: "square.grid.3x3"
        }
    }

    private func shellName(of entry: CanvasAddPaletteEntry) -> String {
        guard case .item(.terminalShell(let shell)) = entry else { return title(of: entry) }
        return TerminalNaming.shellMenuTitle(for: shell, among: shells)
    }

    /// "⌃⌥3" for the third shell in the catalog; nothing past the ninth.
    private func shortcutHint(of entry: CanvasAddPaletteEntry) -> String? {
        guard case .item(.terminalShell(let shell)) = entry,
            let position = shells.firstIndex(of: shell).map({ $0 + 1 }),
            CanvasNavigationShortcuts.shellShortcut(forPosition: position) != nil
        else { return nil }
        return "⌃⌥\(position)"
    }

    private func choose(_ entry: CanvasAddPaletteEntry) {
        dismiss()
        switch entry {
        case .item(let item):
            item.perform(on: board, session: session, center: boardPoint)
        case .serviceIcon:
            CanvasDiagramPanels.showLibrary(board: board, session: session)
        }
    }
}

/// A shell chip gets an accessibility hint explaining what makes it different
/// from the plain "Terminal" tile; every other entry is unchanged.
private struct CanvasAddItemShellHint: ViewModifier {
    let entry: CanvasAddPaletteEntry

    func body(content: Content) -> some View {
        if entry.isChip {
            content.accessibilityHint("Add a terminal that runs this shell")
        } else {
            content
        }
    }
}
