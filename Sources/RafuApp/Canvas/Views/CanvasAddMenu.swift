import SwiftUI

/// What the Add menu and the Add popover can make (review C19, 7.4).
enum CanvasAddKind: CaseIterable, Identifiable {
    case note, terminal, file, image, webApp, macApp

    var id: Self { self }

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
    @FocusState private var queryFocused: Bool

    private var matches: [CanvasAddKind] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return CanvasAddKind.allCases }
        return CanvasAddKind.allCases.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Add a card", text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { if let first = matches.first { choose(first) } }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                        .fill(theme.palette.fieldBackground)
                )
                .accessibilityLabel("Add a card")
            ForEach(matches) { kind in
                Button {
                    choose(kind)
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 3)
            }
            if matches.isEmpty {
                Text("No matching card type").foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 8)
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .frame(width: 200)
        .onAppear { queryFocused = true }
        .onExitCommand { dismiss() }
    }

    private func choose(_ kind: CanvasAddKind) {
        dismiss()
        kind.perform(on: board, session: session, center: boardPoint)
    }
}
