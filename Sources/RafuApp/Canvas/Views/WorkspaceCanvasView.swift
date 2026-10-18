import AppKit
import SwiftUI

private struct CanvasPresentationKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var canvasPresentationID: UUID? {
        get { self[CanvasPresentationKey.self] }
        set { self[CanvasPresentationKey.self] = newValue }
    }
}

struct WorkspaceCanvasView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var connectionDrag = CanvasConnectionDrag()
    @State private var interaction = CanvasInteractionState()
    @State private var panStart: CanvasViewport?
    @State private var magnifyStart: CanvasViewport?
    @State private var magnifyLastScale = 1.0
    @State private var marqueeStart: CGPoint?
    @State private var presentationID = UUID()
    @State private var spaceIsDown = false
    @State private var isPanning = false
    @State private var isDropTargeted = false
    @FocusState private var boardHasKeyboardFocus: Bool
    @AppStorage("canvasEmptyBoardTipDismissed") private var tipDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if let message = board.errorMessage {
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button("Save Again") { session.saveCanvas(board.id) }
                    Button("Save Copy") { session.saveCanvasCopy(board.id) }
                    Button("Reload…") { session.requestCanvasReload(board.id) }
                }
                .padding(10)
                .background(theme.palette.sidebarBackground)
            }
            Group {
                CanvasBar(board: board, session: session)
                Divider()
                if board.showsList {
                    CanvasListView(board: board, session: session)
                } else {
                    boardSurface
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
        .environment(\.canvasPresentationID, presentationID)
        .environment(interaction)
        .background(
            CanvasScrollBridge(
                isEnabled: false, pan: { _, _ in }, zoom: { _, _ in },
                hidden: { session.canvasResources[board.id]?.pause() },
                visible: { session.canvasResources[board.id]?.windowBecameAvailable() })
        )
        .background(
            CanvasReturnKeyMonitor(isActive: board.contentIsActive) {
                board.backToBoard()
                boardHasKeyboardFocus = true
            }
        )
        .onChange(of: board.changeStamp) { _, _ in session.canvasResources[board.id]?.prune() }
        .onChange(of: board.contentIsActive) { wasActive, isActive in
            // Leaving content by any route (menu, palette, button) returns keys to the board.
            if wasActive, !isActive { boardHasKeyboardFocus = true }
        }
        .onChange(of: board.cards.count) { _, count in
            if count > 0 { tipDismissed = true }
        }
        .onAppear { session.canvasResources[board.id]?.present(owner: presentationID) }
        .onDisappear {
            connectionDrag.reset()
            session.canvasResources[board.id]?.hide(owner: presentationID)
        }
        .onChange(of: board.showsList) { _, showsList in if showsList { connectionDrag.reset() } }
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scale(scale: 0.96).combined(with: .opacity),
                removal: .scale(scale: 0.98).combined(with: .opacity))
    }

    private var boardSurface: some View {
        GeometryReader { geometry in
            let connectionTarget = connectionDrag.target(in: board.cards, viewport: board.viewport)
            ZStack(alignment: .topLeading) {
                grid
                    .contentShape(.rect)
                    .gesture(backgroundDrag)
                    .onTapGesture {
                        board.backToBoard()
                        boardHasKeyboardFocus = true
                        board.selection = []
                        board.clearConnectionSelection()
                    }
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { value in
                            interaction.addPopoverBoardPoint = unproject(value.location)
                            interaction.addPopoverAnchor = value.location
                        }
                    )
                    .pointerStyle(isPanning ? .grabActive : .grabIdle)
                Canvas { context, _ in
                    for connection in board.connections {
                        guard let a = board.cards.first(where: { $0.id == connection.from }),
                            let b = board.cards.first(where: { $0.id == connection.to })
                        else { continue }
                        let start = project(
                            CGPoint(x: a.rect.x + a.rect.width, y: a.rect.y + a.rect.height / 2))
                        let end = project(CGPoint(x: b.rect.x, y: b.rect.y + b.rect.height / 2))
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(
                            to: end, control1: CGPoint(x: start.x + 50, y: start.y),
                            control2: CGPoint(x: end.x - 50, y: end.y))
                        context.stroke(
                            path, with: .color(theme.palette.textSecondary),
                            style: StrokeStyle(
                                lineWidth: 1, dash: [5, 4]))
                        do {
                            var arrow = Path()
                            arrow.move(to: CGPoint(x: end.x - 9, y: end.y - 5))
                            arrow.addLine(to: end)
                            arrow.addLine(to: CGPoint(x: end.x - 9, y: end.y + 5))
                            context.stroke(
                                arrow, with: .color(theme.palette.textSecondary), lineWidth: 2)
                        }
                        if connection.behavior == .session {
                            var reverse = Path()
                            reverse.move(to: CGPoint(x: start.x + 9, y: start.y - 5))
                            reverse.addLine(to: start)
                            reverse.addLine(to: CGPoint(x: start.x + 9, y: start.y + 5))
                            context.stroke(
                                reverse, with: .color(theme.palette.textSecondary), lineWidth: 2)
                        }
                        context.draw(
                            Text(connection.label).font(.caption2).foregroundStyle(
                                theme.palette.textSecondary),
                            at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 10))
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
                ForEach(visibleCards(in: geometry.size)) { card in
                    CanvasCardShell(
                        card: card, board: board, session: session,
                        focusBoard: { boardHasKeyboardFocus = true },
                        isConnectionTarget: connectionTarget == card.id,
                        updateConnectionDrag: { source, point in
                            if connectionDrag.source == nil {
                                board.backToBoard()
                                boardHasKeyboardFocus = true
                            }
                            connectionDrag.update(from: source, at: point)
                        },
                        finishConnectionDrag: { source, point in
                            if let drop = connectionDrag.finish(
                                from: source, at: point, cards: board.cards,
                                viewport: board.viewport)
                            {
                                session.connectCanvasCards(
                                    boardID: board.id, from: drop.from, to: drop.to)
                            }
                        },
                        cancelConnectionDrag: { source in
                            if connectionDrag.source == source { connectionDrag.reset() }
                        }
                    )
                    .frame(width: card.rect.width, height: card.rect.height)
                    .scaleEffect(board.viewport.scale, anchor: .topLeading)
                    .offset(
                        x: card.rect.x * board.viewport.scale + board.viewport.x,
                        y: card.rect.y * board.viewport.scale + board.viewport.y
                    )
                    .transition(cardTransition)
                }
                CanvasConnectionDragPreview(
                    drag: connectionDrag, cards: board.cards, viewport: board.viewport)
                ForEach(interaction.guides, id: \.key) { guide in
                    guideLine(guide)
                }
                if let marquee = interaction.marquee {
                    Rectangle().stroke(theme.palette.accent, lineWidth: 1)
                        .background(theme.palette.accent.opacity(0.08))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            theme.palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                        )
                        .padding(6)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                if board.cards.isEmpty, !tipDismissed {
                    emptyBoardTip
                }
            }
            .coordinateSpace(name: CanvasConnectionCoordinateSpace.board)
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                board.visibleSize = $0
            }
            .clipped()
            .popover(
                isPresented: Binding(
                    get: { interaction.addPopoverAnchor != nil },
                    set: { if !$0 { interaction.addPopoverAnchor = nil } }),
                attachmentAnchor: .rect(
                    .rect(
                        CGRect(
                            origin: interaction.addPopoverAnchor ?? .zero,
                            size: CGSize(width: 1, height: 1)))),
                arrowEdge: .bottom
            ) {
                CanvasAddPopover(
                    board: board, session: session,
                    boardPoint: interaction.addPopoverBoardPoint ?? .zero,
                    dismiss: { interaction.addPopoverAnchor = nil })
            }
            .onDrop(
                of: [.rafuEditorDrag, .fileURL],
                delegate: CanvasFileDropDelegate(
                    boardID: board.id, session: session, isTargeted: $isDropTargeted)
            )
            .background(
                CanvasScrollBridge(
                    isEnabled: true,
                    capturesScroll: { point in
                        guard board.contentIsActive, let card = board.focusedCard else {
                            return true
                        }
                        // The body starts below the 32 pt header and its hairline.
                        let origin = project(CGPoint(x: card.rect.x, y: card.rect.y + 33))
                        return !CGRect(
                            origin: origin,
                            size: CGSize(
                                width: card.rect.width * board.viewport.scale,
                                height: (card.rect.height - 33) * board.viewport.scale)
                        ).contains(point)
                    },
                    pan: { dx, dy in
                        var viewport = board.viewport
                        viewport.x = min(100_000, max(-100_000, viewport.x - dx))
                        viewport.y = min(100_000, max(-100_000, viewport.y - dy))
                        board.setViewport(viewport)
                    },
                    zoom: { factor, point in
                        setScale(
                            board.viewport.scale * factor, from: board.viewport,
                            size: geometry.size, anchor: point)
                    },
                    hidden: {}
                )
            )
            .highPriorityGesture(backgroundDrag, including: spaceIsDown ? .all : .subviews)
            .gesture(
                MagnifyGesture().onChanged { value in
                    if magnifyStart == nil {
                        magnifyStart = board.viewport
                        magnifyLastScale = board.viewport.scale
                    }
                    guard let start = magnifyStart else { return }
                    let raw = CanvasZoomMetrics.clamped(start.scale * value.magnification)
                    if CanvasZoomDetent.crossed(from: magnifyLastScale, to: raw) {
                        RafuHaptics.alignment(channel: "zoom")
                    }
                    magnifyLastScale = raw
                    setScale(
                        CanvasZoomDetent.apply(raw), from: start, size: geometry.size,
                        anchor: value.startLocation)
                }.onEnded { _ in magnifyStart = nil }
            )
            .overlay(alignment: .bottomTrailing) {
                CanvasZoomCapsule(board: board).padding(12)
            }
            .focusable()
            .focused($boardHasKeyboardFocus)
            .onChange(of: boardHasKeyboardFocus) { _, focused in if !focused { spaceIsDown = false }
            }
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { event in
                guard !board.contentIsActive else { return .ignored }
                spaceIsDown = event.phase != .up
                return .handled
            }
            .onKeyPress("z", phases: .down) { event in
                guard !board.contentIsActive, event.modifiers.contains(.command) else {
                    return .ignored
                }
                if event.modifiers.contains(.shift) {
                    board.performRedo()
                } else {
                    board.performUndo()
                }
                return .handled
            }
            .onKeyPress("a", phases: .down) { event in
                guard !board.contentIsActive, event.modifiers == .command else { return .ignored }
                board.select(Set(board.cards.map(\.id)))
                return .handled
            }
            .onKeyPress("n", phases: .down) { event in
                guard !board.contentIsActive, event.modifiers.isEmpty else { return .ignored }
                CanvasAddKind.note.perform(on: board, session: session)
                return .handled
            }
            .onKeyPress("t", phases: .down) { event in
                guard !board.contentIsActive, event.modifiers.isEmpty else { return .ignored }
                CanvasAddKind.terminal.perform(on: board, session: session)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard !board.contentIsActive else { return .ignored }
                if board.deleteSelectedConnectionIfAny() { return .handled }
                guard session.canCloseSelectedCanvasNodes else { return .ignored }
                session.closeSelectedCanvasNodes()
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
                guard !board.contentIsActive else { return .ignored }
                return arrowKey(event) ? .handled : .ignored
            }
            .onKeyPress(.return, phases: .down) { event in
                guard !board.contentIsActive, board.selection.count == 1,
                    let id = board.selection.first
                else { return .ignored }
                if event.modifiers == .option {
                    // Option-Return: Zoom to Card.
                    board.zoomToCard(id)
                    return .handled
                }
                guard event.modifiers.isEmpty else { return .ignored }
                enterContent(of: id, zoomingIfNeeded: true)
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { event in
                guard !board.contentIsActive else { return .ignored }
                let forward = !event.modifiers.contains(.shift)
                let current = board.selection.count == 1 ? board.selection.first : nil
                guard
                    let next = CanvasLayoutMath.neighbour(
                        of: current, in: board.cards, forward: forward)
                else { return .ignored }
                board.select([next])
                board.revealCard(next)
                return .handled
            }
            .onKeyPress(.escape) {
                if connectionDrag.source != nil {
                    connectionDrag.cancel()
                    return .handled
                }
                guard !board.contentIsActive else { return .ignored }
                board.selection = []
                board.connectingFrom = nil
                return .handled
            }
        }
    }

    private var emptyBoardTip: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 28)).foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text("Double-click to add a card. Drag from a card's edge to connect.")
                .font(.system(size: 13)).foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Got It") { tipDismissed = true }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func guideLine(_ guide: CanvasSnapGuide) -> some View {
        let scale = board.viewport.scale
        let isVertical = guide.axis == .vertical
        let origin = project(
            isVertical
                ? CGPoint(x: guide.position, y: guide.start)
                : CGPoint(x: guide.start, y: guide.position))
        let length = (guide.end - guide.start) * scale
        return Rectangle()
            .fill(theme.palette.accent)
            .frame(width: isVertical ? 1 : length, height: isVertical ? length : 1)
            .offset(x: origin.x - (isVertical ? 0.5 : 0), y: origin.y - (isVertical ? 0 : 0.5))
            .transition(.opacity)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    /// Arrow keys move the selection 8 pt (Shift: 40 pt). Option-Command with
    /// an arrow resizes the one selected card instead.
    private func arrowKey(_ event: KeyPress) -> Bool {
        let step = event.modifiers.contains(.shift) ? 40.0 : 8.0
        var dx = 0.0
        var dy = 0.0
        switch event.key {
        case .leftArrow: dx = -1
        case .rightArrow: dx = 1
        case .upArrow: dy = -1
        case .downArrow: dy = 1
        default: return false
        }
        if event.modifiers.contains(.command), event.modifiers.contains(.option) {
            guard board.selection.count == 1 else { return false }
            session.performCanvasEdit(board) { try board.resizeSelection(dw: dx * 8, dh: dy * 8) }
            return true
        }
        guard !board.selection.isEmpty else { return false }
        session.performCanvasEdit(board) { try board.moveSelection(dx: dx * step, dy: dy * step) }
        return true
    }

    /// Return on a selected card. A stopped terminal starts its shell (an
    /// explicit key press); other cards take keyboard focus. Below 50% zoom
    /// the card first fills the view, because its content is not shown.
    private func enterContent(of id: CanvasCardID, zoomingIfNeeded: Bool) {
        guard let card = board.cards.first(where: { $0.id == id }) else { return }
        if zoomingIfNeeded, !CanvasZoomFace(scale: board.viewport.scale).showsLiveContent {
            board.zoomToCard(id)
        }
        if case .note = card.content,
            let model = CanvasCardCommands(card: card, board: board, session: session).noteModel
        {
            // Return on a selected note starts editing (Zoom to Card first below 50%).
            if model.beginEditing() { return }
        }
        if case .terminal = card.content,
            let primary = CanvasCardCommands(card: card, board: board, session: session).primary,
            primary.id == "start" || primary.id == "restart"
        {
            primary.perform()
        }
        board.focus(id)
        board.clearConnectionSelection()
    }

    private var grid: some View {
        Canvas { context, size in
            let spacing = max(12, 24 * board.viewport.scale)
            let ox = board.viewport.x.truncatingRemainder(dividingBy: spacing)
            let oy = board.viewport.y.truncatingRemainder(dividingBy: spacing)
            for x in stride(from: ox - spacing, through: size.width, by: spacing) {
                for y in stride(from: oy - spacing, through: size.height, by: spacing) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(theme.palette.textSecondary.opacity(0.25)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Drag on the background pans. Shift-drag draws a marquee and selects live.
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            if panStart == nil && marqueeStart == nil {
                if NSEvent.modifierFlags.contains(.shift) && !spaceIsDown {
                    marqueeStart = value.startLocation
                } else {
                    panStart = board.viewport
                    isPanning = true
                }
            }
            if let start = marqueeStart {
                let marquee = CGRect(
                    x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                    width: abs(start.x - value.location.x), height: abs(start.y - value.location.y))
                interaction.marquee = marquee
                let hits = Set(
                    board.cards.filter { card in
                        marquee.intersects(
                            CGRect(
                                origin: project(CGPoint(x: card.rect.x, y: card.rect.y)),
                                size: CGSize(
                                    width: card.rect.width * board.viewport.scale,
                                    height: card.rect.height * board.viewport.scale)))
                    }.map(\.id))
                if hits != board.selection { board.select(hits) }
            } else if let start = panStart {
                board.setViewport(
                    .init(
                        scale: start.scale,
                        x: min(100_000, max(-100_000, start.x + value.translation.width)),
                        y: min(100_000, max(-100_000, start.y + value.translation.height))))
            }
        }.onEnded { _ in
            interaction.marquee = nil
            marqueeStart = nil
            panStart = nil
            isPanning = false
        }
    }

    private func project(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * board.viewport.scale + board.viewport.x,
            y: point.y * board.viewport.scale + board.viewport.y)
    }

    private func unproject(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - board.viewport.x) / board.viewport.scale,
            y: (point.y - board.viewport.y) / board.viewport.scale)
    }

    private func visibleCards(in size: CGSize) -> [CanvasCard] {
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        return board.cards.filter {
            visible.intersects(
                CGRect(
                    origin: project(CGPoint(x: $0.rect.x, y: $0.rect.y)),
                    size: CGSize(
                        width: $0.rect.width * board.viewport.scale,
                        height: $0.rect.height * board.viewport.scale)))
        }
    }

    /// Pinch and scroll zoom set the viewport directly, 1:1 with the pointer.
    private func setScale(
        _ scale: Double, from start: CanvasViewport, size: CGSize, anchor: CGPoint? = nil
    ) {
        board.setViewport(
            CanvasZoomMetrics.viewport(scaling: start, to: scale, in: size, anchor: anchor))
    }
}
