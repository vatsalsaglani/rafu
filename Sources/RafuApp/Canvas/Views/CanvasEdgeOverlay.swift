import AppKit
import SwiftUI

// MARK: Arrowheads

/// An arrowhead or port stub, as plain data so it can be drawn from a canvas.
nonisolated struct CanvasArrowSpec: Sendable {
    enum Kind: Sendable {
        /// Open chevron, 9 x 10 pt (relationship "To" end, disconnected ends).
        case openChevron
        /// Filled triangle, 10 x 10 pt (message links).
        case filledTriangle
        /// The 4 pt of line next to a port that has no arrowhead.
        case stub
    }

    let tip: CGPoint
    /// Unit vector that points into the port.
    let direction: CGPoint
    let kind: Kind
    let color: Color
    let lineWidth: CGFloat
}

nonisolated enum CanvasArrowDrawing {
    static func draw(_ spec: CanvasArrowSpec, in context: inout GraphicsContext) {
        let along = spec.direction
        let across = CGPoint(x: -along.y, y: along.x)
        switch spec.kind {
        case .openChevron:
            let base = CGPoint(x: spec.tip.x - along.x * 9, y: spec.tip.y - along.y * 9)
            var path = Path()
            path.move(to: CGPoint(x: base.x + across.x * 5, y: base.y + across.y * 5))
            path.addLine(to: spec.tip)
            path.addLine(to: CGPoint(x: base.x - across.x * 5, y: base.y - across.y * 5))
            context.stroke(
                path, with: .color(spec.color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        case .filledTriangle:
            let base = CGPoint(x: spec.tip.x - along.x * 10, y: spec.tip.y - along.y * 10)
            var path = Path()
            path.move(to: spec.tip)
            path.addLine(to: CGPoint(x: base.x + across.x * 5, y: base.y + across.y * 5))
            path.addLine(to: CGPoint(x: base.x - across.x * 5, y: base.y - across.y * 5))
            path.closeSubpath()
            context.fill(path, with: .color(spec.color))
        case .stub:
            var path = Path()
            path.move(to: CGPoint(x: spec.tip.x - along.x * 4, y: spec.tip.y - along.y * 4))
            path.addLine(to: spec.tip)
            context.stroke(
                path, with: .color(spec.color),
                style: StrokeStyle(lineWidth: spec.lineWidth, lineCap: .butt))
        }
    }
}

// MARK: Overlay above the cards

/// What must draw above the cards (review 7.5 and 7.6): the connection preview
/// with its target feedback, arrowheads and port stubs, the hovered or selected
/// edge with its halo and end handles, and the label and "Connect to new…"
/// popovers. It does not take hits except on the end handles.
struct CanvasEdgeOverlay: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let board: CanvasBoardState
    let session: WorkspaceSession
    let drag: CanvasConnectionDrag
    @State private var endDrag: EndDrag?
    @State private var retraction: Retraction?
    @State private var lastPreview: CanvasEdgeCurve?
    @State private var idsAtDragStart: Set<UUID> = []
    @State private var serialAtDragStart = 0
    @State private var connectNew: ConnectNewRequest?
    @State private var cursorPushed = false
    private let bridge = CanvasLiveBridge.shared

    private struct EndDrag: Equatable {
        let id: UUID
        let movingFrom: Bool
        var point: CGPoint
    }

    private struct Retraction: Identifiable {
        let id = UUID()
        let curve: CanvasEdgeCurve
    }

    private struct ConnectNewRequest {
        let source: CanvasCardID
        let point: CGPoint
    }

    var body: some View {
        let displays = CanvasEdgeScene.displays(board: board, bridge: bridge)
        let viewport = board.viewport
        ZStack(alignment: .topLeading) {
            arrowheads(displays)
            ForEach(emphasized(displays)) { display in
                emphasis(display)
            }
            connectionPreview(viewport: viewport)
            endDragPreview(displays: displays, viewport: viewport)
            if let retraction {
                CanvasConnectionRetractionView(
                    curve: retraction.curve, color: theme.palette.accent,
                    done: {
                        if self.retraction?.id == retraction.id { self.retraction = nil }
                    }
                )
                .id(retraction.id)
            }
            popoverAnchors(displays)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: drag.isActive) { was, isActive in
            if isActive {
                idsAtDragStart = Set(board.connections.map(\.id))
                serialAtDragStart = drag.outcome?.serial ?? 0
            } else if was {
                finishPreview()
            }
        }
        .onChange(of: drag.location) { _, _ in
            if drag.isActive { lastPreview = previewCurve(viewport: board.viewport) }
        }
        .onChange(of: drag.outcome?.serial) { _, _ in handle(drag.outcome) }
        .onChange(of: snapKey(viewport: viewport)) { _, key in
            // Once per port entry, and only for a user-driven drag.
            if key != nil { RafuHaptics.alignment(channel: "port") }
        }
        .onChange(of: showsNotAllowed(viewport: viewport)) { _, notAllowed in
            if notAllowed, !cursorPushed {
                NSCursor.operationNotAllowed.push()
                cursorPushed = true
            } else if !notAllowed, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    // MARK: Arrowheads and stubs

    private func arrowSpecs(for display: CanvasEdgeDisplay) -> [CanvasArrowSpec] {
        let style = CanvasEdgeStyle(
            display: display, palette: theme.palette,
            isHovered: board.hoveredConnectionID == display.id)
        let route = display.route
        guard let state = display.state else {
            return [
                CanvasArrowSpec(
                    tip: route.end, direction: route.curve.endInward, kind: .openChevron,
                    color: style.color, lineWidth: style.lineWidth),
                CanvasArrowSpec(
                    tip: route.start, direction: route.curve.startInward, kind: .stub,
                    color: style.color, lineWidth: style.lineWidth),
            ]
        }
        let kind: CanvasArrowSpec.Kind =
            state.kind == .disconnected ? .openChevron : .filledTriangle
        return [
            CanvasArrowSpec(
                tip: route.end, direction: route.curve.endInward, kind: kind,
                color: style.color, lineWidth: style.lineWidth),
            CanvasArrowSpec(
                tip: route.start, direction: route.curve.startInward, kind: kind,
                color: style.color, lineWidth: style.lineWidth),
        ]
    }

    private func arrowheads(_ displays: [CanvasEdgeDisplay]) -> some View {
        let specs = displays.flatMap { arrowSpecs(for: $0) }
        return Canvas { context, _ in
            for spec in specs { CanvasArrowDrawing.draw(spec, in: &context) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Hovered and selected edge

    private func emphasized(_ displays: [CanvasEdgeDisplay]) -> [CanvasEdgeDisplay] {
        let selected = board.selectedConnection?.id
        let hovered = board.hoveredConnectionID
        return displays.filter { $0.id == selected || $0.id == hovered }
    }

    @ViewBuilder
    private func emphasis(_ display: CanvasEdgeDisplay) -> some View {
        let isSelected = board.selectedConnection?.id == display.id
        let style = CanvasEdgeStyle(display: display, palette: theme.palette, isHovered: true)
        ZStack(alignment: .topLeading) {
            if isSelected {
                CanvasEdgeCurveShape(curve: display.route.curve)
                    .stroke(
                        theme.palette.accent.opacity(0.22),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            CanvasEdgeCurveShape(curve: display.route.curve)
                .stroke(style.color, style: style.strokeStyle)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        if isSelected {
            CanvasEdgeEndHandle(
                point: display.route.start,
                changed: { endDrag = EndDrag(id: display.id, movingFrom: true, point: $0) },
                ended: { finishEndDrag(display.id, movingFrom: true, at: $0) })
            CanvasEdgeEndHandle(
                point: display.route.end,
                changed: { endDrag = EndDrag(id: display.id, movingFrom: false, point: $0) },
                ended: { finishEndDrag(display.id, movingFrom: false, at: $0) })
        }
    }

    @ViewBuilder
    private func endDragPreview(displays: [CanvasEdgeDisplay], viewport: CanvasViewport)
        -> some View
    {
        if let endDrag, let display = displays.first(where: { $0.id == endDrag.id }) {
            let fixedIsStart = !endDrag.movingFrom
            let fixed = fixedIsStart ? display.route.start : display.route.end
            let fixedSide = fixedIsStart ? display.route.fromSide : display.route.toSide
            let snap = CanvasConnectionDrag.snap(
                at: endDrag.point, in: board.cards, viewport: viewport, excluding: nil)
            let end = snap?.point ?? endDrag.point
            let curve = CanvasEdgeGeometry.previewCurve(
                from: fixed, startSide: fixedSide, to: end, endSide: snap?.side)
            ZStack(alignment: .topLeading) {
                CanvasEdgeCurveShape(curve: curve)
                    .stroke(theme.palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Circle().strokeBorder(theme.palette.accent, lineWidth: 1.5)
                    .frame(width: snap == nil ? 8 : 12, height: snap == nil ? 8 : 12)
                    .position(end)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func finishEndDrag(_ id: UUID, movingFrom: Bool, at location: CGPoint) {
        let viewport = board.viewport
        let cards = board.cards
        let hit =
            CanvasConnectionDrag.card(at: location, in: cards, viewport: viewport)?.id
            ?? CanvasConnectionDrag.snap(
                at: location, in: cards, viewport: viewport, excluding: nil)?.card
        endDrag = nil
        if let hit {
            // Refused moves (self, identical link, the same card) change nothing.
            board.retargetConnection(id, movingFrom: movingFrom, to: hit)
        } else {
            // Dropped on the empty board: delete, with undo.
            board.deleteConnection(id)
        }
    }

    // MARK: Connection drag

    private func currentSnap(viewport: CanvasViewport) -> CanvasConnectionSnap? {
        guard drag.isActive, let source = drag.source else { return nil }
        return drag.snap(
            in: board.cards, viewport: viewport, accepts: { board.canConnect(from: source, to: $0) }
        )
    }

    private func snapKey(viewport: CanvasViewport) -> String? {
        guard let snap = currentSnap(viewport: viewport) else { return nil }
        return "\(snap.card.rawValue.uuidString)-\(snap.side.rawValue)"
    }

    private func showsNotAllowed(viewport: CanvasViewport) -> Bool {
        guard drag.isActive, let source = drag.source,
            let target = drag.target(in: board.cards, viewport: viewport)
        else { return false }
        return !board.canConnect(from: source, to: target)
    }

    private func previewCurve(viewport: CanvasViewport) -> CanvasEdgeCurve? {
        guard drag.isActive, let start = drag.startPort(in: board.cards, viewport: viewport) else {
            return nil
        }
        let snap = currentSnap(viewport: viewport)
        return CanvasEdgeGeometry.previewCurve(
            from: start.point, startSide: start.side, to: snap?.point ?? drag.location,
            endSide: snap?.side)
    }

    @ViewBuilder
    private func connectionPreview(viewport: CanvasViewport) -> some View {
        if let source = drag.source, let start = drag.startPort(in: board.cards, viewport: viewport),
            let curve = previewCurve(viewport: viewport)
        {
            let snap = currentSnap(viewport: viewport)
            ZStack(alignment: .topLeading) {
                targetFeedback(source: source, snap: snap, viewport: viewport)
                CanvasEdgeCurveShape(curve: curve)
                    .stroke(theme.palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Circle().fill(theme.palette.accent)
                    .frame(width: 12, height: 12)
                    .position(start.point)
                Circle().strokeBorder(theme.palette.accent, lineWidth: 1.5)
                    .frame(width: snap == nil ? 8 : 12, height: snap == nil ? 8 : 12)
                    .position(curve.end)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Valid targets get a 1.5 pt outline and show their ports; invalid targets
    /// (the source, an identical link, a full board) dim to 60%.
    @ViewBuilder
    private func targetFeedback(
        source: CanvasCardID, snap: CanvasConnectionSnap?, viewport: CanvasViewport
    ) -> some View {
        let targetID = drag.target(in: board.cards, viewport: viewport)
        ZStack(alignment: .topLeading) {
            if let targetID, let card = board.cards.first(where: { $0.id == targetID }) {
                let rect = CanvasConnectionDrag.screenRect(of: card, viewport: viewport)
                let radius = 8 * viewport.scale
                if board.canConnect(from: source, to: targetID) {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(theme.palette.accent, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    ForEach(CanvasPortSide.allCases, id: \.self) { side in
                        let grown = snap?.card == targetID && snap?.side == side
                        Circle()
                            .fill(grown ? theme.palette.accent : theme.palette.editorBackground)
                            .overlay(Circle().strokeBorder(theme.palette.accent, lineWidth: 1.5))
                            .frame(width: grown ? 12 : 8, height: grown ? 12 : 8)
                            .position(CanvasEdgeGeometry.portPoint(on: rect, side: side))
                    }
                } else {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(theme.palette.editorBackground.opacity(0.4))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .animation(RafuMotion.targetHighlight, value: targetID)
    }

    // MARK: Drag outcomes

    /// A cancelled or refused drag retracts to its port (160 ms, instant under
    /// Reduce Motion). A drop that made an edge draws it in instead, and a drop
    /// on the empty board opens the "Connect to new…" popover.
    private func finishPreview() {
        let outcome = drag.outcome
        let isFresh = (outcome?.serial ?? 0) != serialAtDragStart
        if isFresh, let outcome {
            switch outcome.kind {
            case .emptyBoard:
                return
            case .dropped(let drop):
                if createdEdge(for: drop) != nil { return }
            case .cancelled:
                break
            }
        }
        guard !reduceMotion, let curve = lastPreview else { return }
        retraction = Retraction(curve: curve)
    }

    private func createdEdge(for drop: CanvasConnectionDrop) -> CanvasConnection? {
        board.connections.last {
            $0.from == drop.from && $0.to == drop.to && !idsAtDragStart.contains($0.id)
        }
    }

    private func handle(_ outcome: CanvasConnectionOutcome?) {
        guard let outcome else { return }
        switch outcome.kind {
        case .dropped(let drop):
            if let edge = createdEdge(for: drop) {
                board.labelEditorIsForNewConnection = true
                board.labelEditorConnectionID = edge.id
            }
        case .emptyBoard(let source, let point):
            connectNew = ConnectNewRequest(source: source, point: point)
        case .cancelled:
            break
        }
    }

    // MARK: Popovers

    @ViewBuilder
    private func popoverAnchors(_ displays: [CanvasEdgeDisplay]) -> some View {
        if let id = board.labelEditorConnectionID, let display = displays.first(where: { $0.id == id })
        {
            Color.clear.frame(width: 1, height: 1)
                .popover(
                    isPresented: Binding(
                        get: { board.labelEditorConnectionID != nil },
                        set: { shown in
                            if !shown {
                                board.labelEditorConnectionID = nil
                                board.labelEditorIsForNewConnection = false
                            }
                        }), arrowEdge: .bottom
                ) {
                    CanvasEdgeLabelEditor(
                        board: board, connectionID: id,
                        isNew: board.labelEditorIsForNewConnection
                    ) {
                        board.labelEditorConnectionID = nil
                        board.labelEditorIsForNewConnection = false
                    }
                }
                .offset(x: display.route.midpoint.x, y: display.route.midpoint.y)
        }
        if let request = connectNew {
            Color.clear.frame(width: 1, height: 1)
                .popover(
                    isPresented: Binding(
                        get: { connectNew != nil },
                        set: { shown in if !shown { connectNew = nil } }), arrowEdge: .bottom
                ) {
                    CanvasConnectToNewPopover { kind in
                        connectNew = nil
                        let viewport = board.viewport
                        session.connectCanvasToNew(
                            kind, boardID: board.id, from: request.source,
                            at: CGPoint(
                                x: (request.point.x - viewport.x) / viewport.scale,
                                y: (request.point.y - viewport.y) / viewport.scale))
                    }
                }
                .offset(x: request.point.x, y: request.point.y)
        }
    }
}

// MARK: Pieces

private struct CanvasEdgeEndHandle: View {
    @Environment(\.rafuTheme) private var theme
    let point: CGPoint
    let changed: (CGPoint) -> Void
    let ended: (CGPoint) -> Void

    var body: some View {
        Circle().fill(theme.palette.textPrimary)
            .overlay(Circle().strokeBorder(theme.palette.editorBackground, lineWidth: 2))
            .frame(width: 10, height: 10)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
            .offset(x: point.x - 10, y: point.y - 10)
            .highPriorityGesture(
                DragGesture(
                    minimumDistance: 1,
                    coordinateSpace: .named(CanvasConnectionCoordinateSpace.board)
                )
                .onChanged { changed($0.location) }
                .onEnded { ended($0.location) }
            )
            .help("Drag to another card to reconnect this end. Drop on the empty board to delete the link.")
            .accessibilityHidden(true)
    }
}

/// The preview curve shrinking back to its port (trim end 1 to 0).
private struct CanvasConnectionRetractionView: View {
    let curve: CanvasEdgeCurve
    let color: Color
    let done: () -> Void
    @State private var trim = 1.0

    var body: some View {
        CanvasEdgeCurveShape(curve: curve)
            .trim(from: 0, to: trim)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(RafuMotion.connectionCancel, completionCriteria: .logicallyComplete) {
                    trim = 0
                } completion: {
                    done()
                }
            }
    }
}

/// "Label (optional)" at the edge midpoint. Return applies the label; clicking
/// away skips it. Terminal pairs also choose Message link or Relationship only.
private struct CanvasEdgeLabelEditor: View {
    let board: CanvasBoardState
    let connectionID: UUID
    let isNew: Bool
    let close: () -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        board: CanvasBoardState, connectionID: UUID, isNew: Bool, close: @escaping () -> Void
    ) {
        self.board = board
        self.connectionID = connectionID
        self.isNew = isNew
        self.close = close
        _text = State(initialValue: board.connection(connectionID)?.customLabel ?? "")
    }

    private var connection: CanvasConnection? { board.connection(connectionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Label (optional)", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    board.setConnectionLabel(connectionID, to: text)
                    close()
                }
                .accessibilityLabel("Link label")
            if isNew, let connection, board.bothTerminals(connection.from, connection.to) {
                VStack(alignment: .leading, spacing: 4) {
                    behaviorButton("Message link", .session, current: connection.behavior)
                    behaviorButton("Relationship only", .related, current: connection.behavior)
                }
                Text(
                    connection.behavior == .session
                        ? "Starts Paused. Resume it from the link menu or the Canvas bar."
                        : "A visual relationship. No messages pass."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { isFocused = true }
    }

    private func behaviorButton(
        _ title: String, _ behavior: CanvasConnectionBehavior, current: CanvasConnectionBehavior
    ) -> some View {
        Button {
            board.setConnectionBehavior(connectionID, to: behavior)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").opacity(current == behavior ? 1 : 0)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current == behavior ? .isSelected : [])
    }
}

private struct CanvasConnectToNewPopover: View {
    let choose: (CanvasNewCardKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to new…").font(.headline)
            Button("Note") { choose(.note) }
            Button("Terminal") { choose(.terminal) }
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
    }
}
