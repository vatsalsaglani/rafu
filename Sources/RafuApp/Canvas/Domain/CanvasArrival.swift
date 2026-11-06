import CoreGraphics
import Foundation

/// What a board does when it opens (UX Round A, B1), and when the zoom
/// capsule offers `Fit` (B2). Pure, so both rules are tested without a view.
///
/// A card is "in view" when the visible board shows at least
/// `visibleFraction` of its width AND of its height. A board opens fitted
/// when it is zoomed out past `fitBelowScale` or when no card is in view; a
/// board with a card in view keeps the viewport the user parked.
nonisolated enum CanvasArrival {
    /// Below this scale a board opens fitted (the hand-zoom floor).
    static let fitBelowScale = CanvasZoomMetrics.interactiveMinimumScale
    /// The share of a card's width and height that must be on screen.
    static let visibleFraction = 0.25

    /// True when at least one card shows less than `visibleFraction` of its
    /// width or height. False for an empty board or an unmeasured view.
    static func anyCardOutOfView(
        cards: [CanvasRect], viewport: CanvasViewport, visible: CGSize
    ) -> Bool {
        guard visible.width > 0, visible.height > 0 else { return false }
        return cards.contains { !isInView($0, viewport: viewport, visible: visible) }
    }

    /// True when the board has cards and none of them is in view.
    static func allCardsOutOfView(
        cards: [CanvasRect], viewport: CanvasViewport, visible: CGSize
    ) -> Bool {
        guard visible.width > 0, visible.height > 0, !cards.isEmpty else { return false }
        return !cards.contains { isInView($0, viewport: viewport, visible: visible) }
    }

    /// Whether a board that just opened must be fitted. With cards: the
    /// scale is below `fitBelowScale`, or every card is out of view. An
    /// empty board: only when the scale is below `fitBelowScale` (it resets
    /// to the identity viewport).
    static func needsFit(cards: [CanvasRect], viewport: CanvasViewport, visible: CGSize) -> Bool {
        guard visible.width > 0, visible.height > 0 else { return false }
        if viewport.scale < fitBelowScale { return true }
        return allCardsOutOfView(cards: cards, viewport: viewport, visible: visible)
    }

    /// The viewport an arriving board takes when `needsFit` is true: every
    /// card in view, at most 100 %, or the identity viewport for an empty
    /// board. Fit may go below the hand-zoom floor (down to 10 %).
    static func fittedViewport(cards: [CanvasRect], visible: CGSize) -> CanvasViewport {
        guard let first = cards.first else { return CanvasViewport() }
        let bounds = cards.dropFirst().reduce(first.cgRect) { $0.union($1.cgRect) }
        return CanvasZoomMetrics.viewport(fitting: bounds, in: visible)
    }

    private static func isInView(
        _ card: CanvasRect, viewport: CanvasViewport, visible: CGSize
    ) -> Bool {
        let scale = viewport.scale
        let left = card.x * scale + viewport.x
        let top = card.y * scale + viewport.y
        let width = card.width * scale
        let height = card.height * scale
        guard width > 0, height > 0 else { return false }
        let shownWidth = min(left + width, Double(visible.width)) - max(left, 0)
        let shownHeight = min(top + height, Double(visible.height)) - max(top, 0)
        return shownWidth >= width * visibleFraction && shownHeight >= height * visibleFraction
    }
}
