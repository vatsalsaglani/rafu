import SwiftUI

/// The board overview (UX Round A, B3): a 140 × 90 pt vector map of every
/// card rect and the visible board, drawn in one `Canvas`. No bitmap, no
/// per-card view, no shadow. Click or drag in it to move the visible board
/// there (pointer-driven, so no animation). The board view decides when it
/// shows: capsule hover, a pan and 1.5 s after it, or Show Overview.
struct CanvasMinimapView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let board: CanvasBoardState
    /// The mapping at the start of a drag in the overview. Moving the board
    /// changes the mapped area, so a drag keeps one mapping to stay stable
    /// under the pointer.
    @State private var dragLayout: CanvasMinimapLayout?

    var body: some View {
        // Read the board here, in `body`, not inside the `Canvas` renderer:
        // the renderer runs outside Observation tracking (see the dot grid).
        let cards = board.cards.map(\.rect)
        let viewport = board.viewport
        let layout =
            dragLayout
            ?? CanvasMinimapLayout(cards: cards, viewport: viewport, visible: board.visibleSize)
        let cardFill = theme.palette.textSecondary.opacity(0.25)
        let cardStroke = theme.palette.textSecondary
        let frameColor = theme.palette.accent
        let increased = contrast == .increased
        let frameUnder = theme.palette.borderStrong
        Canvas { context, _ in
            for card in cards {
                let path = Path(
                    roundedRect: layout.rect(card), cornerRadius: 1.5, style: .continuous)
                context.fill(path, with: .color(cardFill))
                context.stroke(path, with: .color(cardStroke), lineWidth: 1)
            }
            let frame = Path(
                roundedRect: layout.viewportRect, cornerRadius: 2, style: .continuous)
            if increased {
                context.stroke(frame, with: .color(frameUnder), lineWidth: 3.5)
            }
            context.stroke(frame, with: .color(frameColor), lineWidth: 1.5)
        }
        .frame(width: CanvasMinimapLayout.size.width, height: CanvasMinimapLayout.size.height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.palette.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect(cornerRadius: 8))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragLayout == nil { dragLayout = layout }
                    let mapping = dragLayout ?? layout
                    board.setViewport(
                        CanvasMinimapLayout.viewport(
                            centering: mapping.boardPoint(at: value.location),
                            scale: board.viewport.scale, visible: board.visibleSize))
                }
                .onEnded { _ in dragLayout = nil }
        )
        .help("Click or drag to move the view")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ensemble overview")
        .accessibilityValue(
            "\(cards.count == 1 ? "1 card" : "\(cards.count) cards"), "
                + viewport.scale.formatted(.percent.precision(.fractionLength(0))))
    }
}
