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

/// Grouped items: [Note, Terminal] [File…, Image…] [Web App…, Mac App…].
struct CanvasAddMenuItems: View {
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        item(.note)
        item(.terminal)
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
        .help("Add to Canvas")
        .accessibilityLabel("Add to Canvas")
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
    @State private var hovered: CanvasAddKind?
    @FocusState private var queryFocused: Bool

    var body: some View {
        let kinds = CanvasAddKind.matches(query)
        let current = kinds.indices.contains(highlighted) ? kinds[highlighted] : nil
        VStack(alignment: .leading, spacing: 4) {
            searchField(kinds)
            Divider().padding(.vertical, 2)
            ForEach(kinds) { kind in
                row(kind, isHighlighted: kind == current)
            }
            if kinds.isEmpty {
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

    private func searchField(_ matches: [CanvasAddKind]) -> some View {
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

    /// One card type. The highlighted row (Return target) uses the selection
    /// fill; hover uses the lighter hover fill. No gold.
    private func row(_ kind: CanvasAddKind, isHighlighted: Bool) -> some View {
        Button {
            choose(kind)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(kind.title)
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
                    .fill(rowFill(kind, isHighlighted: isHighlighted))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = kind
            } else if hovered == kind {
                hovered = nil
            }
        }
        .accessibilityLabel(kind.title)
    }

    private func rowFill(_ kind: CanvasAddKind, isHighlighted: Bool) -> Color {
        if isHighlighted { return theme.palette.selection }
        return hovered == kind ? theme.palette.hover : Color.clear
    }

    private func choose(_ kind: CanvasAddKind) {
        dismiss()
        kind.perform(on: board, session: session, center: boardPoint)
    }
}
