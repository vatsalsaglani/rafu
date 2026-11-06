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
        case .reload(let id):
            CanvasReloadConfirmation(boardID: id, session: session)
        default:
            CanvasBasicDialogView(dialog: dialog, session: session)
        }
    }
}

/// New Ensemble, Rename Ensemble, Rename Card and Add Web App: one field in
/// the Rafu popup language (ADR 0033). Return saves; Escape cancels.
struct CanvasBasicDialogView: View {
    @Environment(\.rafuTheme) private var theme
    let dialog: CanvasDialog
    let session: WorkspaceSession
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(symbol: symbol, title: title)
            VStack(alignment: .leading, spacing: 10) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .rafuField(isFocused: fieldFocused)
                    .accessibilityLabel(placeholder)
                    .onSubmit { submit() }
                if case .renameCard(let boardID, let cardID) = dialog,
                    let card = session.canvas.boards[boardID]?.cards.first(where: {
                        $0.id == cardID
                    }),
                    case .terminal = card.content
                {
                    Text("Mention: \(CanvasBridgePeer.mention(for: text))")
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .foregroundStyle(theme.palette.textPrimary)
                    note(
                        "Use this name in a prompt to a connected agent. Each connected terminal needs a different name."
                    )
                }
                if case .web = dialog {
                    note(
                        "Use a loopback URL. Credentials are not allowed. Query strings and fragments are removed before saving. The app can contact external services after you connect."
                    )
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(theme.palette.error)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            RafuPopupFooter(hints: [("↩", actionTitle), ("esc", "Cancel")]) {
                Button("Cancel") { session.canvasDialog = nil }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { submit() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .frame(width: 480, alignment: .top)
        .rafuPopupSurface(.sheet)
        .task {
            text = initialText
            fieldFocused = true
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
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

    private var symbol: String {
        switch dialog {
        case .newBoard: "plus.rectangle.on.rectangle"
        case .web: "globe"
        default: "pencil"
        }
    }

    private var placeholder: String {
        if case .web = dialog { "http://localhost:3000" } else { "Name" }
    }
    private var actionTitle: String {
        switch dialog {
        case .newBoard: "Create"
        case .web: "Add"
        default: "Save"
        }
    }
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
                case .library, .shortcuts, .reload: break
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

/// Reload Ensemble?: it drops unsaved changes, so Reload is destructive and
/// Return cancels.
struct CanvasReloadConfirmation: View {
    let boardID: CanvasID
    let session: WorkspaceSession
    @State private var error: String?

    var body: some View {
        RafuConfirmPopup(
            symbol: "arrow.clockwise", title: "Reload Ensemble?",
            message: error
                ?? "Reload replaces this window's Ensemble with the saved version. Unsaved Ensemble changes will be lost.",
            actions: [.init("Reload", isDestructive: true, perform: reload)]
        ) {
            session.canvasDialog = nil
        }
    }

    private func reload() {
        Task {
            guard await session.reloadCanvas(boardID) else {
                error = "The Ensemble could not be reloaded."
                return
            }
            session.canvasDialog = nil
        }
    }
}

/// Which saved Ensemble the Open Ensemble list selects. Pure, so it is
/// unit-tested.
nonisolated enum CanvasLibrarySelection {
    /// The previous selection while it is still listed, otherwise the first
    /// row, so Return always has a target.
    static func initial(items: [CanvasSummary], previous: CanvasID?) -> CanvasID? {
        if let previous, items.contains(where: { $0.id == previous }) { return previous }
        return items.first?.id
    }

    /// The row above or below `current`, clamped to the list.
    static func move(_ current: CanvasID?, by offset: Int, in items: [CanvasSummary]) -> CanvasID? {
        guard !items.isEmpty else { return nil }
        let index = items.firstIndex { $0.id == current } ?? 0
        return items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// The items whose title contains `query`, in library order.
    static func filter(_ items: [CanvasSummary], query: String) -> [CanvasSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    /// "3 saved in this workspace".
    static func subtitle(count: Int) -> String {
        count == 0 ? "None saved in this workspace" : "\(count) saved in this workspace"
    }
}

/// Open Ensemble: search, "N cards · edited 2 h ago" rows, the first row
/// selected, Return opens. Delete asks first, inside the same popup, and
/// Return there cancels (review C15, ADR 0033).
struct CanvasLibrarySheet: View {
    @Environment(\.rafuTheme) private var theme
    let session: WorkspaceSession
    @State private var query = ""
    @State private var selection: CanvasID?
    @FocusState private var searchFocused: Bool

    private var items: [CanvasSummary] {
        CanvasLibrarySelection.filter(session.canvas.library, query: query)
    }

    var body: some View {
        if let pending = session.pendingCanvasDelete {
            deleteConfirmation(pending)
        } else {
            library
        }
    }

    private var library: some View {
        let items = items
        let selected = items.first { $0.id == selection }
        return VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(
                symbol: "square.on.square.dashed", title: "Open Ensemble", subtitle: subtitle)
            RafuPopupSearchField(
                prompt: "Search Ensembles", text: $query, hint: "⌘F", focus: $searchFocused
            )
            .onSubmit { if let selection { open(selection) } }
            .onKeyPress(.downArrow) {
                selection = CanvasLibrarySelection.move(selection, by: 1, in: items)
                return .handled
            }
            .onKeyPress(.upArrow) {
                selection = CanvasLibrarySelection.move(selection, by: -1, in: items)
                return .handled
            }
            // Backspace edits the search text; on an empty field it asks to
            // delete the selected saved Ensemble.
            .onKeyPress(.delete) {
                guard query.isEmpty, let selected, canDelete(selected.id) else { return .ignored }
                requestDelete(selected)
                return .handled
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if let notice = session.canvas.libraryNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            RafuPopupDivider()
            list(items)
                .frame(height: 280)
            RafuPopupFooter(hints: [("↑↓", "Move"), ("↩", "Open"), ("⌫", "Delete")]) {
                Button("Delete…") { if let selected { requestDelete(selected) } }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .disabled(selected.map { !canDelete($0.id) } ?? true)
                    .help("Delete the selected saved Ensemble")
                    .accessibilityHint("Asks before deleting")
                Button("Open") { if let selection { open(selection) } }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .frame(width: 520, alignment: .top)
        .rafuPopupSurface(.sheet)
        .background {
            // Escape closes; the header shows the `esc` hint.
            Button("Close") { session.canvasDialog = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .task { await session.prepareCanvasLibrary() }
        .onAppear { searchFocused = true }
        .onChange(of: session.canvas.library, initial: true) { _, _ in reselect() }
        .onChange(of: query) { _, _ in reselect() }
    }

    @ViewBuilder
    private func list(_ items: [CanvasSummary]) -> some View {
        if session.canvas.isLoading, items.isEmpty {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            if query.isEmpty {
                RafuEmptyState(
                    symbol: "square.on.square.dashed", message: "No saved Ensembles yet",
                    actionTitle: "New Ensemble…"
                ) { session.canvasDialog = .newBoard }
            } else {
                RafuEmptyState(
                    symbol: "magnifyingglass", message: "No Ensemble matches “\(query)”.")
            }
        } else {
            let openElsewhere = openInOtherWindows()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            row(item, openElsewhere: openElsewhere.contains(item.id))
                                .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id, anchor: nil) }
                }
            }
        }
    }

    private func row(_ item: CanvasSummary, openElsewhere: Bool) -> some View {
        Button {
            selection = item.id
        } label: {
            RafuPopupRow(
                symbol: "square.on.square.dashed", title: item.title, caption: detail(item),
                trailing: openLabel(item.id, openElsewhere: openElsewhere),
                isSelected: item.id == selection)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(item.id) })
        .accessibilityHint("Return opens it")
        .contextMenu {
            Button("Open") { open(item.id) }
            if canDelete(item.id) {
                Divider()
                Button("Delete Saved Ensemble…", role: .destructive) { requestDelete(item) }
            }
        }
    }

    private func deleteConfirmation(_ item: CanvasSummary) -> some View {
        RafuConfirmPopup(
            symbol: "trash", title: "Delete “\(item.title)”?",
            message:
                "This deletes its saved layout and notes. Source files and external apps are not deleted.",
            actions: [
                .init("Delete Ensemble", isDestructive: true) {
                    session.pendingCanvasDelete = nil
                    Task { _ = await session.canvas.deleteSaved(item) }
                }
            ]
        ) {
            session.pendingCanvasDelete = nil
        }
    }

    private var subtitle: String {
        if session.canvas.isLoading, session.canvas.library.isEmpty { return "Loading…" }
        return CanvasLibrarySelection.subtitle(count: session.canvas.library.count)
    }

    private func reselect() {
        selection = CanvasLibrarySelection.initial(items: items, previous: selection)
    }

    /// Open boards can not be deleted from here: close the tab first.
    private func canDelete(_ id: CanvasID) -> Bool { session.canvas.boards[id] == nil }

    private func openLabel(_ id: CanvasID, openElsewhere: Bool) -> String? {
        if session.canvas.boards[id] != nil { return "open in this window" }
        return openElsewhere ? "open in another window" : nil
    }

    /// Boards open in another window of the same workspace.
    private func openInOtherWindows() -> Set<CanvasID> {
        guard let root = session.rootURL?.standardizedFileURL else { return [] }
        var ids = Set<CanvasID>()
        for snapshot in WorkspaceWindowRegistry.shared.sessionSnapshots()
        where snapshot.session !== session && snapshot.rootURL.standardizedFileURL == root {
            ids.formUnion(snapshot.session.canvas.boards.keys)
        }
        return ids
    }

    private func detail(_ item: CanvasSummary) -> String {
        let count = session.canvas.boards[item.id]?.cards.count ?? item.cardCount
        return CanvasCardSummaryText.libraryDetail(cardCount: count, modified: item.modified)
    }

    private func open(_ id: CanvasID) {
        session.canvasDialog = nil
        Task { await session.openCanvas(id) }
    }

    private func requestDelete(_ item: CanvasSummary) {
        guard canDelete(item.id) else { return }
        session.pendingCanvasDelete = item
    }
}

/// Help > Ensemble Shortcuts. The pointer paths are in the card and Ensemble
/// menus; these are the keys (review 7.2). The Tools and Add blocks read
/// `CanvasBoardKeyMap`, so they always match the badges.
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
        ("⌫", "Remove the selection from the Ensemble. Files are never deleted"),
        ("⌘F", "Find a card by name, kind, agent, or link, and go to it"),
        ("⌘9, ⌥⌘9, ⌘0", "Zoom to fit, zoom to selection, actual size"),
        ("⌥⌘L", "Connect two selected cards"),
        ("⌃⌥1…⌃⌥9", "Add a terminal with that shell (when the machine has more than one)"),
        ("⌃⌘←↑→↓", "Focus the card in that direction"),
        ("⌃⌘], ⌃⌘[", "Focus the next or previous card"),
    ]

    /// Tool letters, in tool bar order, then the extra tool bar items.
    static var toolRows: [(String, String)] {
        CanvasWhiteboardToolKind.allCases.map { (CanvasBoardKeyMap.display($0.key), $0.title) }
            + [
                (CanvasBoardKeyMap.iconLibraryItemID, "Icon Library…"),
                (CanvasBoardKeyMap.convertToFrameItemID, "Convert Selection to Frame"),
            ].compactMap { id, title in
                CanvasBoardKeyMap.paletteItemKeys[id].map { (CanvasBoardKeyMap.display($0), title) }
            }
    }

    /// Add letters, in Add palette order, then Service Icon….
    static var addRows: [(String, String)] {
        CanvasAddKind.allCases.compactMap { kind in
            kind.key.map { (CanvasBoardKeyMap.display($0), "Add \(kind.title)") }
        }
            + (CanvasBoardKeyMap.serviceIconKey.map {
                [(CanvasBoardKeyMap.display($0), "Add \(CanvasAddPaletteEntry.serviceIconTitle)")]
            } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(
                symbol: "keyboard", title: "Ensemble Shortcuts",
                subtitle: "Letters work while the board has focus")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 24) {
                        block("Tools", rows: Self.toolRows)
                        block("Add", rows: Self.addRows)
                    }
                    block("Board", rows: Self.rows, keyCaps: false)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
            RafuPopupFooter(hints: [("esc", "Close")]) {
                Button("Done") { session.canvasDialog = nil }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 600, alignment: .top)
        .rafuPopupSurface(.sheet)
        .background {
            Button("Close") { session.canvasDialog = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func block(_ title: String, rows: [(String, String)], keyCaps: Bool = true)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        if keyCaps {
                            RafuKeyHint(row.0)
                        } else {
                            Text(row.0)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.palette.textPrimary)
                        }
                        Text(row.1)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.1), \(row.0)")
                }
            }
        }
    }
}
