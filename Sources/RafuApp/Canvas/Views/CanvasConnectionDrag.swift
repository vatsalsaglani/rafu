import SwiftUI

nonisolated enum CanvasConnectionCoordinateSpace {
    static let board = "RafuCanvasConnectionBoard"
}

nonisolated struct CanvasConnectionDrop: Equatable, Sendable {
    let from: CanvasCardID
    let to: CanvasCardID
}

/// Transient pointer state. A drag does not edit the document until a valid drop.
nonisolated struct CanvasConnectionDrag {
    private(set) var source: CanvasCardID?
    private(set) var location = CGPoint.zero
    private(set) var isCancelled = false

    mutating func update(from source: CanvasCardID, at location: CGPoint) {
        if self.source == nil {
            self.source = source
            isCancelled = false
        }
        guard self.source == source, !isCancelled else { return }
        self.location = location
    }

    mutating func cancel() { isCancelled = true }
    mutating func reset() { self = Self() }

    func target(in cards: [CanvasCard], viewport: CanvasViewport) -> CanvasCardID? {
        guard let source, !isCancelled, viewport.scale.isFinite, viewport.scale > 0,
            location.x.isFinite, location.y.isFinite,
            cards.contains(where: { $0.id == source })
        else { return nil }
        let point = CGPoint(
            x: (location.x - viewport.x) / viewport.scale,
            y: (location.y - viewport.y) / viewport.scale)
        // The last card is painted on top. Do not connect through it to a hidden card.
        guard
            let hit = cards.reversed().first(where: {
                CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height)
                    .contains(point)
            }), hit.id != source
        else { return nil }
        return hit.id
    }

    func start(in cards: [CanvasCard], viewport: CanvasViewport) -> CGPoint? {
        guard !isCancelled, let card = cards.first(where: { $0.id == source }) else { return nil }
        return CGPoint(
            x: (card.rect.x + card.rect.width) * viewport.scale + viewport.x,
            y: (card.rect.y + card.rect.height / 2) * viewport.scale + viewport.y)
    }

    mutating func finish(
        from source: CanvasCardID, at location: CGPoint,
        cards: [CanvasCard], viewport: CanvasViewport
    ) -> CanvasConnectionDrop? {
        defer { reset() }
        guard self.source == source else { return nil }
        update(from: source, at: location)
        guard let target = target(in: cards, viewport: viewport) else { return nil }
        return CanvasConnectionDrop(from: source, to: target)
    }
}

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

struct CanvasConnectionDragPreview: View {
    @Environment(\.rafuTheme) private var theme
    let drag: CanvasConnectionDrag
    let cards: [CanvasCard]
    let viewport: CanvasViewport

    var body: some View {
        Canvas { context, _ in
            guard let start = drag.start(in: cards, viewport: viewport) else { return }
            let end = drag.location
            let bend = max(40, abs(end.x - start.x) / 2)
            var path = Path()
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + bend, y: start.y),
                control2: CGPoint(x: end.x - bend, y: end.y))
            context.stroke(
                path, with: .color(theme.palette.accent),
                style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            context.fill(
                Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)),
                with: .color(theme.palette.accent))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
