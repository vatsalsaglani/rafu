import AppKit
import SwiftUI

/// An extra trailing palette button supplied by another workstream (X9 uses
/// it for "Icons…"). Register once, before boards appear, with
/// `CanvasToolPalette.register(_:)`. `key` is an optional single-letter
/// shortcut that must not collide with a built-in tool key.
struct CanvasToolPaletteItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var key: Character?
    let perform: @MainActor (CanvasBoardState, WorkspaceSession) -> Void

    init(
        id: String, title: String, symbol: String, key: Character? = nil,
        perform: @escaping @MainActor (CanvasBoardState, WorkspaceSession) -> Void
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.key = key
        self.perform = perform
    }

    var helpText: String {
        key.map { "\(title) (\(String($0).uppercased()))" } ?? title
    }
}

/// The compact floating whiteboard palette, centred at the top of the board:
/// Select, Hand, Rectangle, Ellipse, Diamond, Arrow, Line, Pen, Text, Mermaid,
/// Image…, then a style menu and any registered extra items.
///
/// Single-letter shortcuts work only while the board itself has keyboard
/// focus (`isFocused` of the board's focusable ancestor) and no card content
/// is active. Escape returns a drawing tool to Select.
struct CanvasToolPalette: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.isFocused) private var boardIsFocused
    let board: CanvasBoardState
    let session: WorkspaceSession
    let tool: CanvasWhiteboardTool

    private(set) static var extraItems: [CanvasToolPaletteItem] = []

    /// Adds `item` after the built-in tools. A second item with the same `id`
    /// replaces the first.
    static func register(_ item: CanvasToolPaletteItem) {
        extraItems.removeAll { $0.id == item.id }
        extraItems.append(item)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedTools
                .fixedSize(horizontal: true, vertical: false)
            compactTools
        }
        .padding(4)
        .background(theme.palette.elevatedBackground, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(theme.palette.borderSubtle)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .background(
            CanvasToolKeyMonitor(isActive: keysActive) { key in handle(key) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whiteboard tools")
        // The board places the palette (`WorkspaceCanvasView.boardTopOverlay`)
        // so the paused-links notice can stack below it.
    }

    private var expandedTools: some View {
        HStack(spacing: 2) {
            ForEach(CanvasWhiteboardToolKind.allCases) { kind in
                toolButton(kind)
                if kind == .hand || kind == .pen || kind == .mermaid {
                    separator
                }
            }
            separator
            CanvasWhiteboardStyleMenu(board: board, tool: tool)
            if !Self.extraItems.isEmpty {
                separator
                ForEach(Self.extraItems) { item in extraButton(item) }
            }
        }
    }

    /// Split groups can be narrower than the full palette. Keep selection and
    /// panning visible and expose every remaining tool in a native menu.
    private var compactTools: some View {
        HStack(spacing: 2) {
            toolButton(.select)
            toolButton(.hand)
            Menu {
                ForEach(CanvasWhiteboardToolKind.allCases.filter { $0 != .select && $0 != .hand }) {
                    kind in
                    Button(kind.title, systemImage: kind.symbol) { choose(kind) }
                }
                if !Self.extraItems.isEmpty {
                    Divider()
                    ForEach(Self.extraItems) { item in
                        Button(item.title, systemImage: item.symbol) {
                            item.perform(board, session)
                        }
                    }
                }
            } label: {
                Image(systemName: "pencil.and.outline")
                    .frame(width: 28, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Drawing Tools")
            .accessibilityLabel("Drawing Tools")
            separator
            CanvasWhiteboardStyleMenu(board: board, tool: tool)
        }
    }

    private var keysActive: Bool {
        boardIsFocused && !board.contentIsActive && board.renamingCardID == nil
    }

    private var separator: some View {
        Rectangle().fill(theme.palette.borderSubtle)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    private func toolButton(_ kind: CanvasWhiteboardToolKind) -> some View {
        let isOn = tool.kind == kind
        return Button {
            choose(kind)
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(isOn ? theme.palette.textPrimary : theme.palette.textSecondary)
                .background(
                    isOn ? theme.palette.accentSoft : Color.clear, in: .rect(cornerRadius: 6)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(kind.helpText)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func extraButton(_ item: CanvasToolPaletteItem) -> some View {
        Button {
            item.perform(board, session)
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(theme.palette.textSecondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(item.helpText)
        .accessibilityLabel(item.title)
    }

    private func choose(_ kind: CanvasWhiteboardToolKind) {
        if kind == .image {
            tool.kind = .select
            session.chooseCanvasFile(board.id, imageOnly: true)
            return
        }
        tool.kind = kind
        if kind != .select { board.selection = [] }
    }

    /// Returns true when the key was used.
    private func handle(_ key: CanvasToolKey) -> Bool {
        switch key {
        case .escape:
            guard tool.kind != .select else { return false }
            tool.kind = .select
            return true
        case .character(let character):
            if let kind = CanvasWhiteboardToolKind.matching(key: character) {
                choose(kind)
                return true
            }
            if let item = Self.extraItems.first(where: { $0.key == character }) {
                item.perform(board, session)
                return true
            }
            return false
        }
    }
}

/// The style the next item uses; it also restyles the selected whiteboard
/// items (one undoable edit).
struct CanvasWhiteboardStyleMenu: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let tool: CanvasWhiteboardTool

    var body: some View {
        Menu {
            Picker("Colour", selection: binding(\.ink)) {
                ForEach(CanvasInk.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Fill", selection: binding(\.fill)) {
                ForEach(CanvasFill.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Line", selection: binding(\.weight)) {
                ForEach(CanvasLineWeight.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Dashed", isOn: binding(\.dashed))
            Picker("Text Size", selection: binding(\.textSize)) {
                ForEach(CanvasTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Circle()
                .fill(tool.ink.color(in: theme.palette))
                .frame(width: 14, height: 14)
                .overlay { Circle().strokeBorder(theme.palette.borderStrong) }
                .frame(width: 28, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Style")
        .accessibilityLabel("Style")
        .accessibilityValue(tool.ink.title)
    }

    private func binding<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<CanvasWhiteboardTool, Value>
    ) -> Binding<Value> {
        Binding(
            get: { tool[keyPath: keyPath] },
            set: { value in
                tool[keyPath: keyPath] = value
                restyleSelection()
            })
    }

    /// Applies the tool's style to every selected shape, stroke and text.
    private func restyleSelection() {
        let selected = board.selection
        guard !selected.isEmpty else { return }
        do {
            try board.edit { document in
                for index in document.cards.indices
                where selected.contains(document.cards[index].id) {
                    switch document.cards[index].content {
                    case .shape(var shape):
                        shape.stroke = tool.ink
                        shape.fill = tool.fill
                        shape.weight = tool.weight
                        shape.dashed = tool.dashed
                        document.cards[index].content = .shape(shape)
                    case .stroke(var stroke):
                        stroke.ink = tool.ink
                        stroke.weight = tool.weight
                        stroke.dashed = tool.dashed
                        document.cards[index].content = .stroke(stroke)
                    case .text(var text):
                        text.ink = tool.ink
                        text.size = tool.textSize
                        document.cards[index].content = .text(text)
                    default:
                        break
                    }
                }
            }
        } catch {
            board.errorMessage = error.localizedDescription
        }
    }
}

enum CanvasToolKey: Equatable {
    case escape
    case character(Character)
}

/// Sees palette keys before the board's own key handlers. It acts only while
/// `isActive` (the board has focus), only for its own key window, only for
/// a lowercase letter or Escape with no modifiers, and never while a text
/// view (a field editor, note or source editor) is the first responder.
struct CanvasToolKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let perform: (CanvasToolKey) -> Bool

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.isActive = isActive
        view.perform = perform
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.isActive = isActive
        view.perform = perform
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    static func key(for event: NSEvent) -> CanvasToolKey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty, !event.isARepeat else { return nil }
        if event.keyCode == 53 { return .escape }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
            let character = characters.first, character.isLetter, character.isLowercase
        else { return nil }
        return .character(character)
    }

    final class Host: NSView {
        var isActive = false
        var perform: ((CanvasToolKey) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isActive, let window = self.window, event.window === window,
                    window.isKeyWindow, window.attachedSheet == nil,
                    !(window.firstResponder is NSText),
                    let key = CanvasToolKeyMonitor.key(for: event),
                    perform?(key) == true
                else { return event }
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit { detach() }
    }
}
