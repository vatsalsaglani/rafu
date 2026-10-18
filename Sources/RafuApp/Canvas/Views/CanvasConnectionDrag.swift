import SwiftUI

nonisolated enum CanvasConnectionCoordinateSpace {
    static let board = "RafuCanvasConnectionBoard"
}

nonisolated struct CanvasConnectionDrop: Equatable, Sendable {
    let from: CanvasCardID
    let to: CanvasCardID
}

/// A port of a target card that the preview end snapped to.
nonisolated struct CanvasConnectionSnap: Equatable, Sendable {
    let card: CanvasCardID
    let side: CanvasPortSide
    /// Screen position of the port.
    let point: CGPoint
}

/// How the last drag ended. The edge overlay reacts to a new `serial`: it opens
/// the label popover after a drop, the "Connect to new…" popover after a drop on
/// the empty board, and retracts the preview after a cancel.
nonisolated struct CanvasConnectionOutcome: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case dropped(CanvasConnectionDrop)
        /// Released over empty board at `point` (surface coordinates).
        case emptyBoard(source: CanvasCardID, point: CGPoint)
        /// Escape, a drop on the source, or a removed source.
        case cancelled
    }

    let serial: Int
    let kind: Kind
}

/// Transient pointer state. A drag does not edit the document until a valid drop.
/// All locations are in the board surface space (`CanvasConnectionCoordinateSpace.board`).
nonisolated struct CanvasConnectionDrag {
    private(set) var source: CanvasCardID?
    private(set) var location = CGPoint.zero
    private(set) var isCancelled = false
    private(set) var outcome: CanvasConnectionOutcome?
    private var outcomeSerial = 0

    var isActive: Bool { source != nil && !isCancelled }

    mutating func update(from source: CanvasCardID, at location: CGPoint) {
        if self.source == nil {
            self.source = source
            isCancelled = false
        }
        guard self.source == source, !isCancelled else { return }
        self.location = location
    }

    mutating func cancel() { isCancelled = true }

    /// Clears the pointer state. The last outcome stays, so a later reset
    /// (for example when the view disappears) cannot hide it from the overlay.
    mutating func reset() {
        let kept = outcome
        let serial = outcomeSerial
        self = Self()
        outcome = kept
        outcomeSerial = serial
    }

    static func screenRect(of card: CanvasCard, viewport: CanvasViewport) -> CGRect {
        CGRect(
            x: card.rect.x * viewport.scale + viewport.x,
            y: card.rect.y * viewport.scale + viewport.y,
            width: card.rect.width * viewport.scale, height: card.rect.height * viewport.scale)
    }

    private func isUsable(viewport: CanvasViewport) -> Bool {
        viewport.scale.isFinite && viewport.scale > 0 && location.x.isFinite
            && location.y.isFinite
    }

    private func boardPoint(viewport: CanvasViewport) -> CGPoint {
        CGPoint(
            x: (location.x - viewport.x) / viewport.scale,
            y: (location.y - viewport.y) / viewport.scale)
    }

    /// The topmost card under the pointer, which may be the source.
    private func cardUnderPointer(in cards: [CanvasCard], viewport: CanvasViewport) -> CanvasCard? {
        let point = boardPoint(viewport: viewport)
        return cards.reversed().first {
            CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height)
                .contains(point)
        }
    }

    /// The drop target: the topmost card under the pointer, or, when the pointer
    /// is over empty board, a card with a port within 24 screen points.
    func target(in cards: [CanvasCard], viewport: CanvasViewport) -> CanvasCardID? {
        guard let source, !isCancelled, isUsable(viewport: viewport),
            cards.contains(where: { $0.id == source })
        else { return nil }
        // The last card is painted on top. Do not connect through it to a hidden card.
        if let hit = cardUnderPointer(in: cards, viewport: viewport) {
            return hit.id == source ? nil : hit.id
        }
        return snap(in: cards, viewport: viewport)?.card
    }

    /// The nearest port within 24 screen points of the pointer, on a card that
    /// `accepts` as a target. The preview end jumps to it.
    func snap(
        in cards: [CanvasCard], viewport: CanvasViewport,
        accepts: (CanvasCardID) -> Bool = { _ in true }
    ) -> CanvasConnectionSnap? {
        guard let source, !isCancelled, isUsable(viewport: viewport) else { return nil }
        return Self.snap(
            at: location, in: cards, viewport: viewport, excluding: source, accepts: accepts)
    }

    static func snap(
        at point: CGPoint, in cards: [CanvasCard], viewport: CanvasViewport,
        excluding excluded: CanvasCardID?, accepts: (CanvasCardID) -> Bool = { _ in true }
    ) -> CanvasConnectionSnap? {
        var best: (snap: CanvasConnectionSnap, distance: Double)?
        for card in cards.reversed() where card.id != excluded && accepts(card.id) {
            let rect = screenRect(of: card, viewport: viewport)
            guard let port = CanvasEdgeGeometry.snappedPort(on: rect, to: point) else {
                continue
            }
            if best == nil || port.distance < (best?.distance ?? .infinity) {
                best = (
                    CanvasConnectionSnap(card: card.id, side: port.side, point: port.point),
                    port.distance
                )
            }
        }
        return best?.snap
    }

    /// The topmost card under a screen point.
    static func card(
        at point: CGPoint, in cards: [CanvasCard], viewport: CanvasViewport
    ) -> CanvasCard? {
        cards.reversed().first {
            screenRect(of: $0, viewport: viewport).contains(point)
        }
    }

    /// The port on the source that faces the target (or the pointer).
    func startPort(
        in cards: [CanvasCard], viewport: CanvasViewport
    ) -> (side: CanvasPortSide, point: CGPoint)? {
        guard !isCancelled, let card = cards.first(where: { $0.id == source }) else { return nil }
        let rect = Self.screenRect(of: card, viewport: viewport)
        var aim = location
        if let targetID = target(in: cards, viewport: viewport),
            let targetCard = cards.first(where: { $0.id == targetID })
        {
            aim = CanvasEdgeGeometry.center(of: Self.screenRect(of: targetCard, viewport: viewport))
        }
        let center = CanvasEdgeGeometry.center(of: rect)
        // Right until the pointer leaves the source.
        let side: CanvasPortSide =
            hypot(aim.x - center.x, aim.y - center.y) < 1
            ? .right : CanvasEdgeGeometry.facingSide(from: center, to: aim)
        return (side, CanvasEdgeGeometry.portPoint(on: rect, side: side))
    }

    /// The screen point where the preview starts: the facing port of the source.
    func start(in cards: [CanvasCard], viewport: CanvasViewport) -> CGPoint? {
        startPort(in: cards, viewport: viewport)?.point
    }

    mutating func finish(
        from source: CanvasCardID, at location: CGPoint,
        cards: [CanvasCard], viewport: CanvasViewport
    ) -> CanvasConnectionDrop? {
        guard self.source == source else {
            reset()
            return nil
        }
        let wasCancelled = isCancelled
        update(from: source, at: location)
        var drop: CanvasConnectionDrop?
        var kind = CanvasConnectionOutcome.Kind.cancelled
        if !wasCancelled, isUsable(viewport: viewport), cards.contains(where: { $0.id == source }) {
            if let targetID = target(in: cards, viewport: viewport) {
                let value = CanvasConnectionDrop(from: source, to: targetID)
                drop = value
                kind = .dropped(value)
            } else if cardUnderPointer(in: cards, viewport: viewport) == nil {
                kind = .emptyBoard(source: source, point: self.location)
            }
        }
        let serial = outcomeSerial + 1
        reset()
        outcomeSerial = serial
        outcome = CanvasConnectionOutcome(serial: serial, kind: kind)
        return drop
    }
}

/// Four connection ports at the side midpoints of a card (review 7.5). It fills
/// the card frame; apply it with `.overlay`. A drag from a port reports board
/// surface locations; a click or the keyboard calls `connect` (the Connect sheet).
struct CanvasConnectionPorts: View {
    let title: String
    /// Hover, selection, or keyboard focus on the card.
    let isVisible: Bool
    let connect: () -> Void
    let changed: (CGPoint) -> Void
    let ended: (CGPoint) -> Void
    let cancelled: () -> Void
    /// Pass the board zoom to keep ports at 8, 12 and 20 screen points when the
    /// card is scaled. The default of 1 draws them in card points.
    var viewportScale: Double = 1
    @State private var hoveredSide: CanvasPortSide?

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.25, viewportScale)
            let hit = 20 / scale
            ZStack(alignment: .topLeading) {
                ForEach(CanvasPortSide.allCases, id: \.self) { side in
                    let point = CanvasEdgeGeometry.portPoint(
                        on: CGRect(origin: .zero, size: proxy.size), side: side)
                    CanvasConnectionPortDot(
                        side: side, title: title, isVisible: isVisible,
                        isHovered: hoveredSide == side, scale: scale,
                        setHover: { inside in
                            if inside {
                                hoveredSide = side
                            } else if hoveredSide == side {
                                hoveredSide = nil
                            }
                        },
                        connect: connect, changed: changed, ended: ended, cancelled: cancelled
                    )
                    .offset(x: point.x - hit / 2, y: point.y - hit / 2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
}

private struct CanvasConnectionPortDot: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let side: CanvasPortSide
    let title: String
    let isVisible: Bool
    let isHovered: Bool
    let scale: Double
    let setHover: (Bool) -> Void
    let connect: () -> Void
    let changed: (CGPoint) -> Void
    let ended: (CGPoint) -> Void
    let cancelled: () -> Void
    @GestureState private var isDragging = false

    private var isGrown: Bool { isHovered || isDragging }

    var body: some View {
        let diameter = (isGrown ? 12.0 : 8.0) / scale
        Button(action: connect) {
            ZStack {
                Circle().fill(isGrown ? theme.palette.accent : theme.palette.editorBackground)
                Circle().strokeBorder(theme.palette.accent, lineWidth: 1.5 / scale)
            }
            .frame(width: diameter, height: diameter)
            .frame(width: 20 / scale, height: 20 / scale)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isVisible || isGrown ? 1 : 0)
        .animation(RafuMotion.hoverIn, value: isVisible)
        .animation(reduceMotion ? nil : RafuMotion.hoverIn, value: isGrown)
        .allowsHitTesting(isVisible || isGrown)
        .onHover(perform: setHover)
        .help("Drag to another card to connect, or click to choose a target.")
        .accessibilityLabel("Connect \(title)")
        .accessibilityHint("Drag to another card, or activate to choose a target.")
        // One port is enough for VoiceOver; the others do the same thing.
        .accessibilityHidden(side != .right)
        .highPriorityGesture(
            DragGesture(
                minimumDistance: 3, coordinateSpace: .named(CanvasConnectionCoordinateSpace.board)
            )
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { changed($0.location) }
            .onEnded { ended($0.location) }
        )
        .onChange(of: isDragging) { _, active in if !active { cancelled() } }
    }
}

/// The first connection control. `CanvasConnectionPorts` supersedes it; remove
/// it once `CanvasCardShell` uses the ports.
struct CanvasConnectionHandle: View {
    let title: String
    let connect: () -> Void
    let changed: (CGPoint) -> Void
    let ended: (CGPoint) -> Void
    let cancelled: () -> Void
    @GestureState private var isDragging = false

    var body: some View {
        Button(action: connect) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.background, in: .circle)
                .overlay { Circle().strokeBorder(.secondary, lineWidth: 1) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Drag to another card to connect, or click to choose a target.")
        .accessibilityLabel("Connect \(title)")
        .accessibilityHint("Drag to another card, or activate to choose a target.")
        .highPriorityGesture(
            DragGesture(
                minimumDistance: 3, coordinateSpace: .named(CanvasConnectionCoordinateSpace.board)
            )
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { changed($0.location) }
            .onEnded { ended($0.location) }
        )
        .onChange(of: isDragging) { _, active in if !active { cancelled() } }
    }
}
