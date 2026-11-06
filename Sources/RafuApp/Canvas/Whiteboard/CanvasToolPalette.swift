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

    var helpText: String { CanvasBoardKeyMap.helpText(title, key: key) }
}

/// The whiteboard palette: Select, Hand, Rectangle, Ellipse, Diamond, Arrow,
/// Line, Pen, Text, Mermaid, Image…, then a style menu and any registered
/// extra items. `.floating` is the compact card centred at the top of the
/// board; `.hosted` sits flat in a wide Ensemble bar (UX Round C, B7).
///
/// The palette does not read keys. The board installs the letter-key
/// monitor (`CanvasToolKeyHandler`, `WorkspaceCanvasView.boardChrome`), so
/// the shortcuts work in both placements, only while the board itself has
/// keyboard focus and no card content is active. Escape returns a drawing
/// tool to Select.
struct CanvasToolPalette: View {
    enum Placement { case floating, hosted }

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let board: CanvasBoardState
    let session: WorkspaceSession
    let tool: CanvasWhiteboardTool
    /// Gives the board keyboard focus. Choosing a tool calls it, so Escape
    /// and the tool letters work next even when card content had the keys.
    var focusBoard: () -> Void = {}
    var placement: Placement = .floating

    private(set) static var extraItems: [CanvasToolPaletteItem] = []

    /// Adds `item` after the built-in tools. A second item with the same `id`
    /// replaces the first.
    static func register(_ item: CanvasToolPaletteItem) {
        extraItems.removeAll { $0.id == item.id }
        extraItems.append(item)
    }

    var body: some View {
        switch placement {
        case .hosted:
            // The bar guarantees the width (`CanvasBarLayout`). No card: no
            // padding, background, hairline or shadow.
            expandedTools
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Whiteboard tools")
        case .floating:
            // The board places the palette (`WorkspaceCanvasView.boardTopOverlay`)
            // so the paused-links notice can stack below it.
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Whiteboard tools")
        }
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
                    Button(kind.helpText, systemImage: kind.symbol) { choose(kind) }
                }
                if !Self.extraItems.isEmpty {
                    Divider()
                    ForEach(Self.extraItems) { item in
                        Button(item.helpText, systemImage: item.symbol) {
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
                .overlay(alignment: .bottomTrailing) {
                    CanvasToolKeyBadge(key: kind.key, isSelected: isOn)
                }
                .background(
                    isOn ? theme.palette.accentSoft : Color.clear, in: .rect(cornerRadius: 6)
                )
                .overlay {
                    // Flat in the bar, the selected tool has no card behind
                    // it; Increase Contrast gives its fill an edge.
                    if isOn, placement == .hosted, contrast == .increased {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.palette.borderStrong)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(kind.helpText)
        .accessibilityLabel(kind.title)
        .accessibilityHint("Shortcut \(CanvasBoardKeyMap.display(kind.key))")
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
                .overlay(alignment: .bottomTrailing) {
                    if let key = item.key { CanvasToolKeyBadge(key: key, isSelected: false) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(item.helpText)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.key.map { "Shortcut \(CanvasBoardKeyMap.display($0))" } ?? "")
    }

    private func choose(_ kind: CanvasWhiteboardToolKind) {
        Self.choose(kind, tool: tool, board: board, session: session)
        if kind != .image { focusBoard() }
    }

    /// Picks `kind` for `board`. The palette and the Ensemble ▸ Tools menu
    /// share it. Image is an action: it opens the image chooser.
    static func choose(
        _ kind: CanvasWhiteboardToolKind, tool: CanvasWhiteboardTool, board: CanvasBoardState,
        session: WorkspaceSession
    ) {
        if kind == .image {
            tool.kind = .select
            session.chooseCanvasFile(board.id, imageOnly: true)
            return
        }
        tool.kind = kind
        if kind != .select { board.selection = [] }
        // A tool acts on the board, so the keys come back to it: with a
        // terminal or note still active, Escape and V went to that card and
        // the Hand tool could not be left from the keyboard.
        if board.contentIsActive { board.backToBoard() }
    }
}

/// The palette's single-letter keys, owned by the board (UX Round C, B7):
/// the board's `CanvasToolKeyMonitor` calls `handle`, so the keys work
/// whether the palette floats on the board or sits in the bar.
@MainActor
enum CanvasToolKeyHandler {
    /// The letters act only while the board itself has keyboard focus, no
    /// card content is active and no card title is being renamed.
    static func keysActive(boardFocused: Bool, board: CanvasBoardState) -> Bool {
        boardFocused && !board.contentIsActive && board.renamingCardID == nil
    }

    /// Returns true when the key was used. N and T are left to the board
    /// view (`CanvasBoardKeyMap.boardHandledAddKinds`), so they run once.
    static func handle(
        _ key: CanvasToolKey, tool: CanvasWhiteboardTool, board: CanvasBoardState,
        session: WorkspaceSession
    ) -> Bool {
        if let kind = CanvasWhiteboardToolKind.resolve(key, from: tool.kind) {
            // The board already has the keys, so no focus hand-off is needed.
            CanvasToolPalette.choose(kind, tool: tool, board: board, session: session)
            return true
        }
        guard case .character(let character) = key else { return false }
        if let item = CanvasToolPalette.extraItems.first(where: { $0.key == character }) {
            item.perform(board, session)
            return true
        }
        if let kind = CanvasBoardKeyMap.monitorAddKind(for: character) {
            kind.perform(on: board, session: session, animated: false)
            return true
        }
        return false
    }
}

/// The shortcut letter at the bottom-right of a tool button, as in Figma and
/// Excalidraw. VoiceOver reads the shortcut from the button's hint instead.
struct CanvasToolKeyBadge: View {
    let key: Character
    let isSelected: Bool
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(CanvasBoardKeyMap.display(key))
            .font(.system(size: 9, weight: .medium, design: .rounded).monospaced())
            .foregroundStyle(
                isSelected || contrast == .increased
                    ? theme.palette.textSecondary : theme.palette.textMuted
            )
            .padding(.trailing, 2)
            .padding(.bottom, 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
            // A borderless menu keeps only the text and image of its label:
            // the old ink-circle label drew nothing and left an empty slot
            // in the tool bar. The label is a symbol; the ink dot is drawn
            // over the menu, outside its label.
            Image(systemName: "paintpalette")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(theme.palette.textSecondary)
        .fixedSize()
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(tool.ink.color(in: theme.palette))
                .frame(width: 6, height: 6)
                .overlay { Circle().strokeBorder(theme.palette.borderStrong, lineWidth: 0.5) }
                .padding(.trailing, 3)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
/// a lowercase letter or Escape with no modifiers, and never while text
/// input (a field editor, note, source editor or terminal) is the first
/// responder.
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

    /// False while text input has the keys (a field editor, a note, a
    /// source editor, or a terminal, which is an `NSTextInputClient`), so a
    /// letter types there instead of picking a tool.
    static func responderAllowsBoardKeys(_ responder: NSResponder?) -> Bool {
        CanvasEdgeDeleteKeyMonitor.Host.responderAllowsEdgeDelete(responder)
    }

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
                    CanvasToolKeyMonitor.responderAllowsBoardKeys(window.firstResponder),
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
