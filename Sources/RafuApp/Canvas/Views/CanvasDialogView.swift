import RafuCore
import SwiftUI

struct CanvasDialogView: View {
    let dialog: CanvasDialog
    let session: WorkspaceSession

    var body: some View {
        switch dialog {
        case .connection(let id, let from, let to):
            CanvasConnectionDialog(boardID: id, initialFrom: from, initialTo: to, session: session)
        case .connectionLabel(let id, let edge):
            CanvasConnectionDialog(boardID: id, edgeID: edge, session: session)
        case .library:
            CanvasLibrarySheet(session: session)
        case .shortcuts:
            CanvasShortcutsSheet(session: session)
        default:
            CanvasBasicDialogView(dialog: dialog, session: session)
        }
    }
}

struct CanvasBasicDialogView: View {
    @Environment(\.rafuTheme) private var theme
    let dialog: CanvasDialog
    let session: WorkspaceSession
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if case .reload = dialog {
                Text(
                    "Reload replaces this window's Ensemble with the saved version. Unsaved Ensemble changes will be lost."
                )
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                if case .renameCard(let boardID, let cardID) = dialog,
                    let card = session.canvas.boards[boardID]?.cards.first(where: {
                        $0.id == cardID
                    }),
                    case .terminal = card.content
                {
                    Text("Mention: \(CanvasBridgePeer.mention(for: text))")
                        .font(.callout.monospaced()).textSelection(.enabled)
                    Text(
                        "Use this name in a prompt to a connected agent. Each connected terminal needs a different name."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if case .web = dialog {
                    Text(
                        "Use a loopback URL. Credentials are not allowed. Query strings and fragments are removed before saving. The app can contact external services after you connect."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(theme.palette.error).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { session.canvasDialog = nil }
                Button(actionTitle) { submit() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(24).frame(width: 480)
        .task {
            text = initialText
        }
    }

    private var title: String {
        switch dialog {
        case .newBoard: "New Ensemble"
        case .library: "Open Ensemble"
        case .renameBoard: "Rename Ensemble"
        case .renameCard: "Rename Card"
        case .web: "Add Web App"
        case .connection: "Connect Cards"
        case .connectionLabel: "Edit Link"
        case .reload: "Reload Ensemble?"
        case .shortcuts: "Ensemble Shortcuts"
        }
    }
    private var placeholder: String {
        if case .web = dialog { "http://localhost:3000" } else { "Name" }
    }
    private var actionTitle: String { if case .reload = dialog { "Reload" } else { "Save" } }
    private var initialText: String {
        switch dialog {
        case .renameBoard(let id): session.canvas.boards[id]?.title ?? ""
        case .renameCard(let id, let card):
            session.canvas.boards[id]?.cards.first { $0.id == card }?.title ?? ""
        case .connectionLabel(let id, let edge):
            session.canvas.boards[id]?.connections.first { $0.id == edge }?.label ?? ""
        case .connection: "Related to"
        default: ""
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch dialog {
                case .newBoard:
                    guard await session.createCanvas(named: text) else {
                        error =
                            session.canvas.libraryNotice
                            ?? "Enter an Ensemble name of 1 to 120 characters."
                        return
                    }
                case .library, .shortcuts: break
                case .reload(let id):
                    guard await session.reloadCanvas(id) else {
                        error = "The Ensemble could not be reloaded."
                        return
                    }
                case .renameBoard(let id):
                    try session.canvas.boards[id]?.edit { $0.title = text }
                case .renameCard(let id, let card):
                    try session.canvas.boards[id]?.edit { value in
                        if let index = value.cards.firstIndex(where: { $0.id == card }) {
                            value.cards[index].title = text
                        }
                    }
                case .web(let id):
                    let destination = try CanvasWebDestination(text)
                    try session.canvas.boards[id]?.add(
                        title: String(destination.address.prefix(120)),
                        content: .web(destination: destination))
                case .connection(let id, let from, let to):
                    guard let to else { throw CanvasError.unavailable }
                    try session.canvas.boards[id]?.edit {
                        $0.connections.append(.init(from: from, to: to, label: text))
                    }
                case .connectionLabel(let id, let edge):
                    try session.canvas.boards[id]?.edit { value in
                        if let index = value.connections.firstIndex(where: { $0.id == edge }) {
                            value.connections[index].label = text
                        }
                    }
                }
                session.canvasDialog = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Open Canvas: search, "N cards · edited 2 h ago" rows, Open as the default
/// button. Deleting is one step deeper, with a confirmation (review C15).
struct CanvasLibrarySheet: View {
    @Environment(\.rafuTheme) private var theme
    let session: WorkspaceSession
    @State private var query = ""
    @State private var selection: CanvasID?

    private var items: [CanvasSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return session.canvas.library }
        return session.canvas.library.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    private var selectedItem: CanvasSummary? {
        session.canvas.library.first { $0.id == selection }
    }

    private var canDeleteSelection: Bool {
        guard let selection else { return false }
        return session.canvas.boards[selection] == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Ensemble").font(.system(size: 15, weight: .semibold))
            TextField("Search", text: $query, prompt: Text("Search Ensembles"))
                .textFieldStyle(.roundedBorder)
            if let notice = session.canvas.libraryNotice {
                Text(notice).font(.callout).foregroundStyle(theme.palette.textSecondary)
            }
            if session.canvas.isLoading { ProgressView().controlSize(.small) }
            if items.isEmpty, !session.canvas.isLoading {
                Text(query.isEmpty ? "No saved Ensembles." : "No Ensemble matches the search.")
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(items, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1)
                        Text(detail(item)).font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
                .contextMenu(forSelectionType: CanvasID.self) { ids in
                    if let id = ids.first, let item = summary(id) {
                        Button("Open") { open(id) }
                        if session.canvas.boards[id] == nil {
                            Divider()
                            Button("Delete Saved Ensemble…", role: .destructive) { delete(item) }
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                .frame(height: 240)
            }
            HStack {
                Button {
                    if let item = selectedItem { delete(item) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!canDeleteSelection)
                .help("Delete the selected saved Ensemble")
                .accessibilityLabel("Delete Saved Ensemble")
                Spacer()
                Button("Cancel", role: .cancel) { session.canvasDialog = nil }
                Button("Open") { if let selection { open(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(24).frame(width: 480)
        .task { await session.prepareCanvasLibrary() }
    }

    private func summary(_ id: CanvasID) -> CanvasSummary? {
        session.canvas.library.first { $0.id == id }
    }

    private func detail(_ item: CanvasSummary) -> String {
        let count = session.canvas.boards[item.id]?.cards.count ?? item.cardCount
        return CanvasCardSummaryText.libraryDetail(cardCount: count, modified: item.modified)
    }

    private func open(_ id: CanvasID) {
        session.canvasDialog = nil
        Task { await session.openCanvas(id) }
    }

    private func delete(_ item: CanvasSummary) {
        // Deletion uses a separate confirmation with the record revision.
        session.pendingCanvasDelete = item
        session.canvasDialog = nil
    }
}

/// Help > Canvas Shortcuts. The pointer paths are in the card and Canvas
/// menus; these are the keys (review 7.2).
struct CanvasShortcutsSheet: View {
    @Environment(\.rafuTheme) private var theme
    let session: WorkspaceSession

    private static let rows: [(String, String)] = [
        ("Double-click the board", "Add a card at that point"),
        ("Drag a card's header", "Move it. Hold ⌘ to turn off snapping"),
        ("Drag from a card's edge port", "Connect to another card"),
        ("Drag the board, or Space + drag", "Pan"),
        ("⇧-drag on the board", "Select with a marquee"),
        ("Pinch, or ⌃ + scroll", "Zoom"),
        ("Return", "Enter the selected card. On a stopped terminal, start its shell"),
        ("⌃⇥", "Return to Board"),
        ("Esc", "Deselect, when the board has focus"),
        ("Arrow keys", "Move the selection 8 pt. Add ⇧ for 40 pt"),
        ("⌥⌘ + arrow keys", "Resize the selected card"),
        ("Tab, ⇧Tab", "Select the next or previous card"),
        ("N, T", "New note, new terminal"),
        ("⌫", "Remove the selection from the Ensemble. Files are never deleted"),
        ("⌘9, ⌥⌘9, ⌘0", "Zoom to fit, zoom to selection, actual size"),
        ("⌥⌘L", "Connect two selected cards"),
        ("⌃⌥1…⌃⌥9", "Add a terminal with that shell (when the machine has more than one)"),
        ("⌃⌘←↑→↓", "Focus the card in that direction"),
        ("⌃⌘], ⌃⌘[", "Focus the next or previous card"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ensemble Shortcuts").font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Self.rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).fontWeight(.medium)
                        Text(row.1).foregroundStyle(theme.palette.textSecondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { session.canvasDialog = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
    }
}
