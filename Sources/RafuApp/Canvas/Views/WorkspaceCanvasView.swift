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
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var panStart: CanvasViewport?
    @State private var magnifyStart: CanvasViewport?
    @State private var marqueeStart: CGPoint?
    @State private var marquee: CGRect?
    @State private var presentationID = UUID()
    @State private var spaceIsDown = false
    @FocusState private var boardHasKeyboardFocus: Bool

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
                toolbar
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
        .background(
            CanvasScrollBridge(
                isEnabled: false, pan: { _, _ in }, zoom: { _ in },
                hidden: { session.canvasResources[board.id]?.pause() },
                visible: { session.canvasResources[board.id]?.windowBecameAvailable() })
        )
        .onChange(of: board.changeStamp) { _, _ in session.canvasResources[board.id]?.prune() }
        .onAppear { session.canvasResources[board.id]?.present(owner: presentationID) }
        .onDisappear { session.canvasResources[board.id]?.hide(owner: presentationID) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(board.title).font(.headline).lineLimit(1)
            if board.isDirty { Text("Modified").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            CanvasAddCardMenu(board: board, session: session)
            Button("Arrange") { session.performCanvasEdit(board) { try board.arrange() } }
            Button("Connect…") { session.requestCanvasConnection(board.id) }
                .disabled(board.selection.count != 2)
            Button("Focus") {
                if let id = board.selection.first { board.focus(id) }
            }
            .disabled(board.selection.count != 1)
            if board.contentIsActive {
                Button("Leave Content") {
                    board.backToBoard()
                    boardHasKeyboardFocus = true
                }
            }
            Button(board.showsList ? "Board" : "List") {
                board.backToBoard()
                board.showsList.toggle()
            }
            Menu {
                Button("Rename…") { session.canvasDialog = .renameBoard(board.id) }
                Button("Save") { session.saveCanvas(board.id) }
                Button("Undo", action: board.performUndo).disabled(!board.canUndo)
                Button("Redo", action: board.performRedo).disabled(!board.canRedo)
                Button("Align Left") {
                    session.performCanvasEdit(board) { try board.alignSelection(leading: true) }
                }.disabled(board.selection.count < 2)
                Button("Align Top") {
                    session.performCanvasEdit(board) { try board.alignSelection(leading: false) }
                }.disabled(board.selection.count < 2)
                Button("Select All") { board.selection = Set(board.cards.map(\.id)) }
                Button("Remove Selected…") { session.requestCanvasCardRemoval(board.id) }
                    .disabled(board.selection.isEmpty)
                Button("Close Canvas") { session.closeCanvas(board.id) }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Canvas actions")
            }
            .fixedSize()
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var boardSurface: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                grid
                    .contentShape(.rect)
                    .gesture(backgroundDrag)
                    .onTapGesture {
                        board.backToBoard()
                        boardHasKeyboardFocus = true
                        board.selection = []
                    }
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
                        context.draw(
                            Text(connection.label).font(.caption2).foregroundStyle(
                                theme.palette.textSecondary),
                            at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 10))
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
                ForEach(visibleCards(in: geometry.size)) { card in
                    CanvasCardShell(card: card, board: board, session: session) {
                        boardHasKeyboardFocus = true
                    }
                    .frame(width: card.rect.width, height: card.rect.height)
                    .scaleEffect(board.viewport.scale, anchor: .topLeading)
                    .offset(
                        x: card.rect.x * board.viewport.scale + board.viewport.x,
                        y: card.rect.y * board.viewport.scale + board.viewport.y)
                }
                if let marquee {
                    Rectangle().stroke(theme.palette.accent, lineWidth: 1)
                        .background(theme.palette.accent.opacity(0.08))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                if board.cards.isEmpty {
                    ContentUnavailableView {
                        Label("Your task has room to grow", systemImage: "rectangle.3.group")
                    } description: {
                        Text(
                            "Add a file, note, terminal, or app. Each live resource starts only when you ask."
                        )
                    } actions: {
                        CanvasAddCardMenu(board: board, session: session)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                board.visibleSize = $0
            }
            .clipped()
            .onDrop(
                of: [.rafuEditorDrag, .fileURL],
                delegate: CanvasFileDropDelegate(boardID: board.id, session: session)
            )
            .background(
                CanvasScrollBridge(
                    isEnabled: true,
                    capturesScroll: { point in
                        guard board.contentIsActive, let card = board.focusedCard else {
                            return true
                        }
                        let origin = project(CGPoint(x: card.rect.x, y: card.rect.y + 36))
                        return !CGRect(
                            origin: origin,
                            size: CGSize(
                                width: card.rect.width * board.viewport.scale,
                                height: (card.rect.height - 66) * board.viewport.scale)
                        ).contains(point)
                    },
                    pan: { dx, dy in
                        var viewport = board.viewport
                        viewport.x = min(100_000, max(-100_000, viewport.x - dx))
                        viewport.y = min(100_000, max(-100_000, viewport.y - dy))
                        board.setViewport(viewport)
                    },
                    zoom: { factor in zoom(factor, size: geometry.size) },
                    hidden: {}
                )
            )
            .highPriorityGesture(backgroundDrag, including: spaceIsDown ? .all : .subviews)
            .gesture(
                MagnifyGesture().onChanged { value in
                    if magnifyStart == nil { magnifyStart = board.viewport }
                    guard let start = magnifyStart else { return }
                    setScale(start.scale * value.magnification, from: start, size: geometry.size)
                }.onEnded { _ in magnifyStart = nil }
            )
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Button {
                        zoom(1 / 1.2, size: geometry.size)
                    } label: {
                        Image(systemName: "minus").accessibilityLabel("Zoom out")
                    }
                    Text(board.viewport.scale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(minWidth: 42)
                    Button {
                        zoom(1.2, size: geometry.size)
                    } label: {
                        Image(systemName: "plus").accessibilityLabel("Zoom in")
                    }
                    Button("1:1") { setScale(1, from: board.viewport, size: geometry.size) }
                    Button("Fit All") { fit(size: geometry.size) }
                }
                .controlSize(.small).buttonStyle(.bordered)
                .padding(8).background(theme.palette.sidebarBackground, in: .rect(cornerRadius: 8))
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                Text(
                    "Drop files to add nodes. Shift-drag selects nodes. ⌘⇧W closes selected nodes."
                )
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8).background(theme.palette.editorBackground.opacity(0.9))
                .padding(8).allowsHitTesting(false)
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
            .onKeyPress(.delete) {
                guard !board.contentIsActive else { return .ignored }
                session.requestCanvasCardRemoval(board.id)
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
                guard !board.contentIsActive else { return .ignored }
                switch event.key {
                case .leftArrow:
                    session.performCanvasEdit(board) { try board.moveSelection(dx: -10, dy: 0) }
                case .rightArrow:
                    session.performCanvasEdit(board) { try board.moveSelection(dx: 10, dy: 0) }
                case .upArrow:
                    session.performCanvasEdit(board) { try board.moveSelection(dx: 0, dy: -10) }
                case .downArrow:
                    session.performCanvasEdit(board) { try board.moveSelection(dx: 0, dy: 10) }
                default: return .ignored
                }
                return .handled
            }
            .onKeyPress(.return) {
                guard !board.contentIsActive, let id = board.selection.first,
                    board.selection.count == 1
                else {
                    return .ignored
                }
                board.focus(id)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !board.contentIsActive else { return .ignored }
                board.selection = []
                board.connectingFrom = nil
                return .handled
            }
        }
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

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            if panStart == nil && marqueeStart == nil {
                if NSEvent.modifierFlags.contains(.shift) && !spaceIsDown {
                    marqueeStart = value.startLocation
                } else {
                    panStart = board.viewport
                }
            }
            if let start = marqueeStart {
                marquee = CGRect(
                    x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                    width: abs(start.x - value.location.x), height: abs(start.y - value.location.y))
            } else if let start = panStart {
                board.setViewport(
                    .init(
                        scale: start.scale,
                        x: min(100_000, max(-100_000, start.x + value.translation.width)),
                        y: min(100_000, max(-100_000, start.y + value.translation.height))))
            }
        }.onEnded { _ in
            if let marquee {
                board.selection = Set(
                    board.cards.filter { card in
                        let origin = project(CGPoint(x: card.rect.x, y: card.rect.y))
                        return marquee.intersects(
                            CGRect(
                                origin: origin,
                                size: CGSize(
                                    width: card.rect.width * board.viewport.scale,
                                    height: card.rect.height * board.viewport.scale)))
                    }.map(\.id))
            }
            marquee = nil
            marqueeStart = nil
            panStart = nil
        }
    }

    private func project(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * board.viewport.scale + board.viewport.x,
            y: point.y * board.viewport.scale + board.viewport.y)
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

    private func zoom(_ factor: Double, size: CGSize) {
        setScale(board.viewport.scale * factor, from: board.viewport, size: size)
    }

    private func setScale(_ scale: Double, from start: CanvasViewport, size: CGSize) {
        let scale = min(2, max(0.25, scale))
        let ratio = scale / start.scale
        board.setViewport(
            .init(
                scale: scale,
                x: size.width / 2 - (size.width / 2 - start.x) * ratio,
                y: size.height / 2 - (size.height / 2 - start.y) * ratio))
    }

    private func fit(size: CGSize) {
        guard let first = board.cards.first else {
            board.setViewport(.init())
            return
        }
        var bounds = CGRect(
            x: first.rect.x, y: first.rect.y, width: first.rect.width, height: first.rect.height)
        for card in board.cards.dropFirst() {
            bounds = bounds.union(
                CGRect(
                    x: card.rect.x, y: card.rect.y, width: card.rect.width, height: card.rect.height
                ))
        }
        let scale = min(
            1, max(0.25, min((size.width - 80) / bounds.width, (size.height - 100) / bounds.height))
        )
        board.setViewport(
            .init(
                scale: scale,
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale))
    }
}
