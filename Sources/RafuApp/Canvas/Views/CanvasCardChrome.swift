import AppKit
import RafuCore
import SwiftUI

/// The actions of one card, shared by the header buttons, the "…" menu, the
/// context menu and the VoiceOver actions so they cannot drift apart.
struct CanvasCardCommands {
    struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let perform: () -> Void
    }

    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    private var resources: CanvasBoardResources? { session.canvasResources[board.id] }

    /// The small observable model of a note card; nil for every other type.
    var noteModel: CanvasNoteModel? {
        guard case .note = card.content else { return nil }
        return session.canvasNoteModel(boardID: board.id, card: card)
    }

    /// The thing the card does: Edit Note, Open in Editor, Start Shell, Load, Open App.
    var primary: Action? {
        switch card.content {
        case .note:
            if noteModel?.isEditing == true {
                return Action(id: "edit", title: "Done Editing", symbol: "checkmark") {
                    noteModel?.endEditing()
                }
            }
            return Action(id: "edit", title: "Edit Note", symbol: "pencil") {
                if noteModel?.beginEditing() != true { board.focus(card.id) }
            }
        case .file(let path), .image(let path):
            return Action(
                id: "open", title: "Open in Editor", symbol: "arrow.up.forward.square"
            ) { session.openCanvasFile(path) }
        case .terminal(let groupID):
            guard let pane = session.terminal.terminalGroup(groupID)?.panes.first else {
                return nil
            }
            if pane.status == .stopped, pane.startAvailability == .available {
                return Action(id: "start", title: "Start Shell", symbol: "play.fill") {
                    board.terminalStartRequest = card.id
                }
            }
            if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
                return Action(id: "restart", title: "Restart Shell", symbol: "arrow.clockwise") {
                    board.terminalStartRequest = card.id
                }
            }
            return nil
        case .web:
            guard let web = resources?.web(for: card) else { return nil }
            if web.webView == nil {
                return Action(id: "load", title: "Load", symbol: "play.fill") { load() }
            }
            return Action(id: "reload", title: "Reload", symbol: "arrow.clockwise") {
                web.stop()
                load()
            }
        case .nativeApp:
            return Action(
                id: "open", title: "Open \(card.title)", symbol: "arrow.up.forward.app"
            ) { resources?.nativeApp(for: card)?.openApp() }
        }
    }

    /// Extra primary-group items that appear only in the menu.
    var secondary: [Action] {
        switch card.content {
        case .web:
            guard let web = resources?.web(for: card) else { return [] }
            var items: [Action] = []
            if web.webView != nil {
                items.append(
                    Action(id: "stop", title: "Stop Loading", symbol: "stop.fill") { web.stop() })
            }
            if let url = web.destination.url {
                items.append(
                    Action(
                        id: "browser", title: "Open in Browser", symbol: "safari"
                    ) { NSWorkspace.shared.open(url) })
            }
            return items
        case .nativeApp:
            guard let app = resources?.nativeApp(for: card) else { return [] }
            if app.isDocked {
                return [
                    Action(
                        id: "undock", title: "Undock \(card.title)",
                        symbol: "rectangle.portrait.and.arrow.right"
                    ) { app.undock() }
                ]
            }
            return [
                Action(
                    id: "dock", title: "Dock \(card.title)", symbol: "rectangle.inset.filled"
                ) { app.dock(appName: card.title, session: session) }
            ]
        default:
            return []
        }
    }

    /// "Running", "Not running", "Exited (1)", "Not loaded", or "3/5" for notes.
    var stateWord: String? {
        switch card.content {
        case .terminal(let groupID):
            guard let pane = session.terminal.terminalGroup(groupID)?.panes.first else {
                return "Unavailable"
            }
            var code: Int32?
            if case .exited(let reported)? = session.terminal.terminalController(for: pane.id)?
                .status
            {
                code = reported
            }
            return CanvasCardPresentation.terminalState(status: pane.status, exitCode: code)
        case .web:
            guard let web = resources?.web(for: card) else { return nil }
            return web.webView == nil ? "Not loaded" : web.status
        case .note(let text):
            if let model = noteModel {
                return model.isEditing ? "Editing" : model.progressText
            }
            return CanvasCardSummaryText.taskCount(in: String(text.prefix(8_192)))
        default:
            return nil
        }
    }

    func load() {
        board.focus(card.id)
        session.connectCanvasWeb(card.id, board: board.id)
    }

    func zoomToCard() {
        board.select([card.id])
        board.zoomToCard(card.id)
    }

    func connect(to targetID: CanvasCardID) {
        session.connectCanvasCards(boardID: board.id, from: card.id, to: targetID)
    }

    func move(dx: Double, dy: Double) {
        board.select([card.id])
        session.performCanvasEdit(board) { try board.moveSelection(dx: dx, dy: dy) }
    }

    func resize(dw: Double, dh: Double) {
        board.select([card.id])
        session.performCanvasEdit(board) { try board.resizeSelection(dw: dw, dh: dh) }
    }

    func reorder(toFront: Bool) {
        session.performCanvasEdit(board) { try board.reorder([card.id], toFront: toFront) }
    }

    func requestRemoval() {
        board.select([card.id])
        session.closeSelectedCanvasNodes()
    }
}

/// One menu for every card type, in one order (review C18). Used by the header
/// "…" button and by right-click on the header.
struct CanvasCardMenuContent: View {
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        let commands = CanvasCardCommands(card: card, board: board, session: session)
        if let primary = commands.primary {
            Button(primary.title, systemImage: primary.symbol, action: primary.perform)
        }
        ForEach(commands.secondary) { item in
            Button(item.title, systemImage: item.symbol, action: item.perform)
        }
        Divider()
        Button("Zoom to Card", systemImage: "arrow.up.left.and.arrow.down.right") {
            commands.zoomToCard()
        }
        Menu("Connect To", systemImage: "point.3.connected.trianglepath.dotted") {
            ForEach(board.cards) { target in
                if target.id != card.id {
                    Button(target.title) { commands.connect(to: target.id) }
                }
            }
        }
        .disabled(board.cards.count < 2)
        if case .terminal = card.content {
            Button("Copy Mention", systemImage: "at") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    CanvasBridgePeer.mention(for: card.title), forType: .string)
            }
        }
        Divider()
        Button("Rename…", systemImage: "pencil") { board.renamingCardID = card.id }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            session.duplicateCanvasCard(board.id, card.id)
        }
        Divider()
        Menu("Arrange", systemImage: "square.3.layers.3d") {
            Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") {
                commands.reorder(toFront: true)
            }
            Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") {
                commands.reorder(toFront: false)
            }
            Menu("Move and Resize") {
                Button("Move Left  ←") { commands.move(dx: -8, dy: 0) }
                Button("Move Right  →") { commands.move(dx: 8, dy: 0) }
                Button("Move Up  ↑") { commands.move(dx: 0, dy: -8) }
                Button("Move Down  ↓") { commands.move(dx: 0, dy: 8) }
                Divider()
                Button("Make Narrower  ⌥⌘←") { commands.resize(dw: -8, dh: 0) }
                Button("Make Wider  ⌥⌘→") { commands.resize(dw: 8, dh: 0) }
                Button("Make Shorter  ⌥⌘↑") { commands.resize(dw: 0, dh: -8) }
                Button("Make Taller  ⌥⌘↓") { commands.resize(dw: 0, dh: 8) }
            }
        }
        Divider()
        Button("Remove from Canvas…", systemImage: "minus.circle", role: .destructive) {
            commands.requestRemoval()
        }
    }
}

/// Inline title editing (double-click the title). Return saves, Esc cancels.
struct CanvasCardRenameField: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    let fontSize: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Card name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(theme.palette.textPrimary)
            .focused($focused)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                    .fill(theme.palette.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                    .strokeBorder(theme.palette.focusRing, lineWidth: 1)
            )
            .onSubmit { commit() }
            .onKeyPress(.escape) {
                board.renamingCardID = nil
                return .handled
            }
            .onAppear {
                text = card.title
                focused = true
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, board.renamingCardID == card.id { board.renamingCardID = nil }
            }
            .accessibilityLabel("Card name")
    }

    private func commit() {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        board.renamingCardID = nil
        guard name != card.title, CanvasDocument.validTitle(name) else { return }
        session.performCanvasEdit(board) {
            try board.edit { value in
                if let index = value.cards.firstIndex(where: { $0.id == card.id }) {
                    value.cards[index].title = name
                }
            }
        }
    }
}

/// "Return to Board ⌃⇥", shown only while this card's content has focus.
struct CanvasReturnToBoardButton: View {
    @Environment(\.rafuTheme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("Return to Board")
                Text("⌃⇥").foregroundStyle(theme.palette.textMuted)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.chipBackground))
            .overlay(Capsule().strokeBorder(theme.palette.accent.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Return to Board (Control-Tab)")
        .accessibilityLabel("Return to Board")
        .accessibilityHint("Moves keyboard focus out of the card. The card stays selected.")
    }
}

/// Header chip: "Modified" or "Preview". Shape and word, not colour alone.
struct CanvasHeaderBadge: View {
    @Environment(\.rafuTheme) private var theme
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.palette.textSecondary)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Capsule().fill(theme.palette.chipBackground))
        .fixedSize()
    }
}

/// Eight 8 pt hit zones around the card with the matching resize cursors, and
/// four corner handles while the card is selected.
struct CanvasResizeZones: View {
    @Environment(\.rafuTheme) private var theme
    let size: CGSize
    let scale: Double
    let showsHandles: Bool
    let changed: (CanvasResizeEdges, DragGesture.Value) -> Void
    let ended: () -> Void

    /// 8 screen points, never smaller than 8 board units.
    private var zone: CGFloat { CGFloat(min(40, max(8, 8 / max(scale, 0.01)))) }

    var body: some View {
        ZStack {
            ForEach(CanvasResizeEdges.all, id: \.rawValue) { edges in
                zoneView(edges)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func zoneView(_ edges: CanvasResizeEdges) -> some View {
        let isCorner =
            [CanvasResizeEdges.left, .right, .top, .bottom]
            .filter { edges.contains($0) }.count == 2
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        let width: CGFloat =
            isCorner ? zone * 1.5 : (horizontal ? zone : max(0, size.width - zone * 3))
        let height: CGFloat =
            isCorner ? zone * 1.5 : (vertical ? zone : max(0, size.height - zone * 3))
        return Color.clear
            .frame(width: width, height: height)
            .overlay {
                if isCorner, showsHandles {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.palette.elevatedBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(theme.palette.accent, lineWidth: 1)
                        )
                        .frame(width: 8, height: 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .pointerStyle(Self.pointer(for: edges))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { changed(edges, $0) }
                    .onEnded { _ in ended() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.alignment(for: edges))
            .accessibilityHidden(true)
    }

    private static func alignment(for edges: CanvasResizeEdges) -> Alignment {
        let left = edges.contains(.left)
        let right = edges.contains(.right)
        let top = edges.contains(.top)
        let bottom = edges.contains(.bottom)
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeading
        case (_, true, true, _): return .topTrailing
        case (true, _, _, true): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        case (true, _, _, _): return .leading
        case (_, true, _, _): return .trailing
        case (_, _, true, _): return .top
        default: return .bottom
        }
    }

    private static func pointer(for edges: CanvasResizeEdges) -> PointerStyle {
        let left = edges.contains(.left)
        let right = edges.contains(.right)
        let top = edges.contains(.top)
        let bottom = edges.contains(.bottom)
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .frameResize(position: .topLeading)
        case (_, true, true, _): return .frameResize(position: .topTrailing)
        case (true, _, _, true): return .frameResize(position: .bottomLeading)
        case (_, true, _, true): return .frameResize(position: .bottomTrailing)
        case (true, _, _, _): return .frameResize(position: .leading)
        case (_, true, _, _): return .frameResize(position: .trailing)
        case (_, _, true, _): return .frameResize(position: .top)
        default: return .frameResize(position: .bottom)
        }
    }
}
