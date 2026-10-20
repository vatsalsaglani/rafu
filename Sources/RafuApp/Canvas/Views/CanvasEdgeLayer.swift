import AppKit
import SwiftUI

// MARK: Shared display model

/// One edge, resolved for drawing: its route in screen points and its link state.
nonisolated struct CanvasEdgeDisplay: Identifiable {
    let connection: CanvasConnection
    let route: CanvasEdgeRoute
    /// Nil for a relationship.
    let state: CanvasLinkState?
    let fromTitle: String
    let toTitle: String
    /// Where the pill goes and how wide it may be without covering a card.
    let label: CanvasEdgeLabelPlacement

    var id: UUID { connection.id }
    var isMessageLink: Bool { connection.isMessageLink }
    var stateKind: CanvasLinkState.Kind? { state?.kind }
}

enum CanvasEdgeScene {
    /// Routes every edge the current zoom and "Show Links" choice allow. All
    /// geometry is in screen points of the board surface.
    static func displays(board: CanvasBoardState, bridge: CanvasLiveBridge) -> [CanvasEdgeDisplay] {
        let viewport = board.viewport
        let tier = CanvasEdgeZoomTier(scale: viewport.scale)
        let showsRelationships: Bool
        let showsMessageLinks: Bool
        switch board.linkVisibility {
        case .all:
            showsRelationships = true
            showsMessageLinks = true
        case .messageOnly:
            showsRelationships = false
            showsMessageLinks = true
        case .none:
            showsRelationships = false
            showsMessageLinks = false
        }
        let connections = board.connections.filter { connection in
            connection.isMessageLink
                ? showsMessageLinks : (showsRelationships && tier.showsRelationships)
        }
        guard !connections.isEmpty else { return [] }

        // A card in a move or resize shows its live rect, so its edges follow
        // it on every frame. Read only past the guard: a board without edges
        // does not re-run for drag frames.
        let live = board.liveGeometry.rects
        var rects: [CanvasCardID: CGRect] = [:]
        var titles: [CanvasCardID: String] = [:]
        // Frames sit behind their members: no edge bends around one, and no
        // label has to keep clear of one.
        var frames: Set<CanvasCardID> = []
        var obstacles: [CGRect] = []
        for stored in board.cards {
            var card = stored
            if let shown = live[card.id] { card.rect = shown }
            let rect = CanvasConnectionDrag.screenRect(of: card, viewport: viewport)
            rects[card.id] = rect
            titles[card.id] = card.title
            if card.content.hasDerivedSize {
                frames.insert(card.id)
            } else {
                obstacles.append(rect)
            }
        }
        let inputs = connections.map { CanvasEdgeInput(id: $0.id, from: $0.from, to: $0.to) }
        let routes = CanvasEdgeGeometry.routes(for: inputs, rects: rects, background: frames)
        let byID = Dictionary(
            connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let states = bridge.linkStates(in: board)

        var result: [CanvasEdgeDisplay] = []
        for route in routes {
            guard let connection = byID[route.id] else { continue }
            result.append(
                CanvasEdgeDisplay(
                    connection: connection, route: route,
                    state: connection.isMessageLink ? (states[connection.id] ?? .paused) : nil,
                    fromTitle: titles[connection.from] ?? "Card",
                    toTitle: titles[connection.to] ?? "Card",
                    label: CanvasEdgeGeometry.labelPlacement(
                        for: route.curve, avoiding: obstacles)))
        }
        // Message links draw last so a relationship never hides one.
        return result.filter { !$0.isMessageLink } + result.filter { $0.isMessageLink }
    }
}

/// Stroke vocabulary from the review legend: pattern, weight and colour all
/// differ by state, and the badge word and glyph repeat it.
struct CanvasEdgeStyle {
    let color: Color
    let lineWidth: CGFloat
    let dash: [CGFloat]
    let lineCap: CGLineCap

    var strokeStyle: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: lineCap, dash: dash) }

    init(display: CanvasEdgeDisplay, palette: RafuThemePalette, isHovered: Bool) {
        let hover: CGFloat = isHovered ? 0.5 : 0
        guard let state = display.state else {
            // Relationship: 1 pt dashed textSecondary.
            color = palette.textSecondary
            lineWidth = 1 + hover
            dash = [5, 4]
            lineCap = .butt
            return
        }
        lineWidth = 1.5 + hover
        switch state.kind {
        case .live:
            color = palette.accent
            dash = []
            lineCap = .butt
        case .paused:
            color = palette.textSecondary
            dash = []
            lineCap = .butt
        case .disconnected:
            color = palette.textMuted
            dash = [2, 4]
            lineCap = .round
        case .failed:
            color = palette.error
            dash = [7, 3]
            lineCap = .butt
        }
    }
}

nonisolated struct CanvasEdgeCurveShape: Shape {
    let curve: CanvasEdgeCurve

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: curve.start)
        path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        return path
    }
}

/// A 12 screen-point invisible stroke around the curve.
private nonisolated struct CanvasEdgeHitShape: Shape {
    let curve: CanvasEdgeCurve

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: curve.start)
        path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        return path.strokedPath(
            StrokeStyle(lineWidth: CanvasEdgeGeometry.hitTolerance * 2, lineCap: .round))
    }
}

// MARK: Layer below the cards

/// Sizes its one subview to its ideal width, at most `maximumWidth`. A long
/// one-line text then truncates with an ellipsis, and a short one keeps its
/// own width, so the pill around it fits the text.
struct CanvasEdgeLabelWidthLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        return child.sizeThatFits(
            ProposedViewSize(width: min(ideal.width, maximumWidth), height: ideal.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Edges above the board and below the cards (review 7.6, Layering). The
/// matching `CanvasEdgeOverlay` draws what must sit above the cards.
struct CanvasEdgeLayer: View {
    let board: CanvasBoardState
    let session: WorkspaceSession
    var focusBoard: () -> Void = {}
    @State private var knownEdges: Set<UUID>
    private let bridge = CanvasLiveBridge.shared

    init(
        board: CanvasBoardState, session: WorkspaceSession, focusBoard: @escaping () -> Void = {}
    ) {
        self.board = board
        self.session = session
        self.focusBoard = focusBoard
        _knownEdges = State(initialValue: Set(board.connections.map(\.id)))
    }

    var body: some View {
        let displays = CanvasEdgeScene.displays(board: board, bridge: bridge)
        let tier = CanvasEdgeZoomTier(scale: board.viewport.scale)
        ZStack(alignment: .topLeading) {
            ForEach(displays) { display in
                CanvasEdgeView(
                    display: display, board: board, tier: tier,
                    isNew: !knownEdges.contains(display.id), focusBoard: focusBoard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: board.connections.map(\.id)) { _, ids in knownEdges.formUnion(ids) }
    }
}

private struct CanvasEdgeView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let display: CanvasEdgeDisplay
    let board: CanvasBoardState
    let tier: CanvasEdgeZoomTier
    let focusBoard: () -> Void
    @State private var drawn: Bool
    @State private var curveHover = false
    @State private var pillHover = false
    @State private var pulse = 0.0
    @State private var travelTick = 0
    private let bridge = CanvasLiveBridge.shared

    init(
        display: CanvasEdgeDisplay, board: CanvasBoardState, tier: CanvasEdgeZoomTier,
        isNew: Bool, focusBoard: @escaping () -> Void
    ) {
        self.display = display
        self.board = board
        self.tier = tier
        self.focusBoard = focusBoard
        _drawn = State(initialValue: !isNew)
    }

    private var isHovered: Bool { board.hoveredConnectionID == display.id }

    var body: some View {
        let _ = travelTick
        let style = CanvasEdgeStyle(display: display, palette: theme.palette, isHovered: isHovered)
        let activity =
            display.isMessageLink
            ? bridge.activity(of: display.id, in: board) : CanvasLinkActivity()
        let count = activity.visibleCount(
            at: Date(), resetAfter: CanvasLiveBridge.burstPolicy.resetAfter)
        let tooltip = CanvasLinkText.tooltip(
            from: display.fromTitle, to: display.toTitle, isMessageLink: display.isMessageLink,
            state: display.state, count: count, label: display.connection.customLabel)
        ZStack(alignment: .topLeading) {
            stroke(style)
            dot(activity: activity)
            Color.clear
                .contentShape(CanvasEdgeHitShape(curve: display.route.curve))
                .modifier(interaction(tooltip: tooltip, exposesToAccessibility: true))
            pill(count: count, tooltip: tooltip)
        }
        .onAppear {
            guard !drawn else { return }
            let animation = RafuMotion.resolve(
                RafuMotion.edgeDrawIn, reduceMotion: reduceMotion, reduced: RafuMotion.reducedFade)
            withAnimation(animation) { drawn = true }
        }
        .onChange(of: display.stateKind) { _, new in
            guard new != nil, let state = display.state else { return }
            AccessibilityNotification.Announcement(
                CanvasLinkText.announcement(target: display.toTitle, state: state)
            ).post()
        }
        .onChange(of: activity.serial) { _, _ in
            guard reduceMotion, display.isMessageLink else { return }
            // Reduce Motion: no travelling dot; the badge border brightens 0 -> 1 -> 0 in 300 ms.
            withAnimation(.easeOut(duration: 0.15), completionCriteria: .logicallyComplete) {
                pulse = 1
            } completion: {
                withAnimation(.easeIn(duration: 0.15)) { pulse = 0 }
            }
        }
    }

    // MARK: Stroke

    private func stroke(_ style: CanvasEdgeStyle) -> some View {
        ZStack {
            CanvasEdgeCurveShape(curve: display.route.curve)
                .trim(from: 0, to: (drawn || reduceMotion) ? 1 : 0)
                .stroke(style.color, style: style.strokeStyle)
                .id(display.stateKind)
                .transition(.opacity)
        }
        .opacity((drawn || !reduceMotion) ? 1 : 0)
        .animation(reduceMotion ? nil : RafuMotion.stateCrossFade, value: display.stateKind)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Message dot

    /// One 4 pt dot with a 3 pt fading trail per accepted message. The timeline
    /// exists only while a dot runs, so an idle link costs nothing.
    @ViewBuilder
    private func dot(activity: CanvasLinkActivity) -> some View {
        let travel = RafuMotion.messageTravel
        if !reduceMotion, display.isMessageLink,
            activity.isDotActive(at: Date(), travel: travel)
        {
            let curve = display.route.curve
            let color = theme.palette.accent
            let forward = activity.dotDirection == .forward
            TimelineView(.animation) { timeline in
                Canvas { context, _ in
                    guard let progress = activity.dotProgress(at: timeline.date, travel: travel)
                    else { return }
                    let head = CanvasEdgeGeometry.dotParameter(progress: progress, forward: forward)
                    let step = forward ? -0.025 : 0.025
                    var previous = curve.point(at: head)
                    for index in 1...5 {
                        let t = min(1, max(0, head + step * Double(index)))
                        let next = curve.point(at: t)
                        var segment = Path()
                        segment.move(to: previous)
                        segment.addLine(to: next)
                        let fade = 0.4 * (1 - Double(index - 1) / 5)
                        context.stroke(
                            segment, with: .color(color.opacity(fade)),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        previous = next
                    }
                    let center = curve.point(at: head)
                    context.fill(
                        Path(
                            ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
                        ),
                        with: .color(color))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: activity.dotStartedAt) {
                try? await Task.sleep(for: .seconds(travel))
                travelTick += 1
            }
        }
    }

    // MARK: Pill

    private enum PillContent {
        case none
        case text(String)
        case glyph(String)
    }

    private func pillContent(count: Int) -> PillContent {
        if let state = display.state {
            switch tier.badgeStyle {
            case .hidden: return .none
            case .glyphOnly: return .glyph(state.glyph)
            case .wordAndGlyph:
                let label = tier.showsLabels ? display.connection.customLabel : nil
                return .text(CanvasLinkText.badge(state: state, count: count, label: label))
            }
        }
        guard tier.showsLabels, let label = display.connection.customLabel else { return .none }
        return .text(label)
    }

    private var pillForeground: Color {
        switch display.state?.kind {
        case .live: theme.palette.accent
        case .failed: theme.palette.error
        case .paused, .disconnected, .none: theme.palette.textSecondary
        }
    }

    private var pillBorder: Color {
        switch display.state?.kind {
        case .live: theme.palette.accent
        case .failed: theme.palette.error
        case .paused, .disconnected: theme.palette.borderStrong
        case .none: theme.palette.borderSubtle
        }
    }

    @ViewBuilder
    private func pill(count: Int, tooltip: String) -> some View {
        switch pillContent(count: count) {
        case .none:
            EmptyView()
        case .text(let text):
            // No wider than the space between the cards around it; the
            // tooltip and the accessibility label keep the full text.
            CanvasEdgeLabelWidthLayout(
                maximumWidth: isHovered ? 480 : CGFloat(display.label.maximumWidth)
            ) {
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pillForeground)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
            }
            .background(theme.palette.elevatedBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(pillBorder, lineWidth: 1))
            .overlay(
                Capsule().strokeBorder(theme.palette.textPrimary.opacity(pulse), lineWidth: 1.5)
            )
            .modifier(interaction(tooltip: tooltip, exposesToAccessibility: false))
            .position(display.label.center)
        case .glyph(let glyph):
            Text(glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(pillForeground)
                .frame(width: 16, height: 16)
                .background(theme.palette.elevatedBackground, in: Circle())
                .overlay(Circle().strokeBorder(pillBorder, lineWidth: 1))
                .overlay(
                    Circle().strokeBorder(theme.palette.textPrimary.opacity(pulse), lineWidth: 1.5)
                )
                .modifier(interaction(tooltip: tooltip, exposesToAccessibility: false))
                .position(display.label.center)
        }
    }

    // MARK: Interaction

    private func interaction(tooltip: String, exposesToAccessibility: Bool)
        -> CanvasEdgeInteraction
    {
        CanvasEdgeInteraction(
            display: display, board: board, bridge: bridge, tooltip: tooltip,
            exposesToAccessibility: exposesToAccessibility,
            select: {
                // An edge is not focusable, so the board must hold the keys
                // for Delete to reach it. `selectConnection` leaves card
                // content, which resigns the first responder in this same
                // turn and can swallow the first request; ask again on the
                // next main-actor turn. `CanvasEdgeDeleteKeyMonitor` covers
                // a board that still has no focus.
                focusBoard()
                board.selectConnection(display.id)
                Task { @MainActor in focusBoard() }
            },
            hover: { inside in
                // The curve and the pill are separate hit targets; the edge is
                // hovered while the pointer is over either one.
                if exposesToAccessibility { curveHover = inside } else { pillHover = inside }
                let hovering = curveHover || pillHover
                if hovering {
                    board.hoveredConnectionID = display.id
                } else if board.hoveredConnectionID == display.id {
                    board.hoveredConnectionID = nil
                }
            })
    }
}

/// Click, hover, tooltip, context menu and accessibility for one edge. Applied
/// to the curve hit area (the accessibility element) and to the pill.
private struct CanvasEdgeInteraction: ViewModifier {
    let display: CanvasEdgeDisplay
    let board: CanvasBoardState
    let bridge: CanvasLiveBridge
    let tooltip: String
    let exposesToAccessibility: Bool
    let select: () -> Void
    let hover: (Bool) -> Void

    private var accessibilityLabel: String {
        CanvasLinkText.accessibilityLabel(
            from: display.fromTitle, to: display.toTitle, isMessageLink: display.isMessageLink,
            state: display.state, label: display.connection.customLabel)
    }

    func body(content: Content) -> some View {
        content
            .onTapGesture(perform: select)
            .onHover(perform: hover)
            .help(tooltip)
            .contextMenu { menuItems }
            .accessibilityHidden(!exposesToAccessibility)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(
                board.selectedConnection?.id == display.id ? [.isButton, .isSelected] : .isButton
            )
            .accessibilityAction(.default, select)
            .accessibilityActions {
                if display.isMessageLink {
                    Button("Pause") { bridge.pause(display.id, in: board) }
                    Button("Resume") { bridge.resume(display.id, in: board) }
                }
                Button("Delete") { board.deleteConnection(display.id) }
                Button("Go to Source") { board.goToCard(display.connection.from) }
                Button("Go to Target") { board.goToCard(display.connection.to) }
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Rename Label…") {
            board.labelEditorIsForNewConnection = false
            board.labelEditorConnectionID = display.id
        }
        if display.isMessageLink {
            if display.state?.kind == .paused {
                Button("Resume Link") { bridge.resume(display.id, in: board) }
            } else {
                Button("Pause Link") { bridge.pause(display.id, in: board) }
            }
        } else {
            Button("Reverse Direction") { board.reverseConnection(display.id) }
        }
        Divider()
        Button("Delete Link", role: .destructive) { board.deleteConnection(display.id) }
    }
}
