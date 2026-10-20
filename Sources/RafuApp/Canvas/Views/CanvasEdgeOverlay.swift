import AppKit
import SwiftUI

// MARK: Overlay above the cards

/// Interaction chrome above the cards: the connection drag preview with its
/// target feedback, the end handles of the selected edge, and the label and
/// "Connect to new…" popovers. No edge stroke, halo or arrowhead draws here;
/// edges stay below every card (`CanvasEdgeLayering`). It takes hits only on
/// the end handles.
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
            if let selected = displays.first(where: { $0.id == board.selectedConnection?.id }) {
                endHandles(selected)
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

    // MARK: Selected edge

    /// The two end handles of the selected edge. A handle whose port lies
    /// under another card is not shown: that card hides the edge there, and
    /// a handle above it would take the card's clicks.
    @ViewBuilder
    private func endHandles(_ display: CanvasEdgeDisplay) -> some View {
        let ends: Set<CanvasCardID> = [display.connection.from, display.connection.to]
        let live = board.liveGeometry.rects
        let cards = board.cards
        let viewport = board.viewport
        let startCovered = CanvasEdgeLayering.isCovered(
            display.route.start, cards: cards, live: live, viewport: viewport, excluding: ends)
        let endCovered = CanvasEdgeLayering.isCovered(
            display.route.end, cards: cards, live: live, viewport: viewport, excluding: ends)
        if !startCovered {
            CanvasEdgeEndHandle(
                point: display.route.start,
                changed: { endDrag = EndDrag(id: display.id, movingFrom: true, point: $0) },
                ended: { finishEndDrag(display.id, movingFrom: true, at: $0) })
        }
        if !endCovered {
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
        if let source = drag.source,
            let start = drag.startPort(in: board.cards, viewport: viewport),
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
        if let id = board.labelEditorConnectionID,
            let display = displays.first(where: { $0.id == id })
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
                .offset(x: display.label.center.x, y: display.label.center.y)
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
            .help(
                "Drag to another card to reconnect this end. Drop on the empty board to delete the link."
            )
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
                        ? "Starts Paused. Resume it from the link menu or the Ensemble bar."
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
