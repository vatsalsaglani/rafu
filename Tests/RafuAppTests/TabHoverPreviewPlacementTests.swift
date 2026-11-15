import CoreGraphics
import Testing

@testable import RafuApp

/// Regression for "the tab hover card covers the tab and floats between
/// tabs": it was centred on the shelf's TOP edge (over the tab and the
/// title-bar row) and clamped with a fixed 130 pt half-width, so a narrow
/// card near either edge was pushed off its tab.
@Suite("Tab hover card placement")
struct TabHoverPreviewPlacementTests {
    private let shelf = CGSize(width: 900, height: 40)
    private let card = CGSize(width: 150, height: 40)

    @Test("The card sits below the shelf, never over the hovered tab")
    func belowTheShelf() {
        let tab = CGRect(x: 300, y: 6, width: 120, height: 28)
        let origin = TabHoverPreviewPlacement.origin(
            tabFrame: tab, cardSize: card, shelfSize: shelf)
        #expect(origin.y == shelf.height + TabHoverPreviewPlacement.gap)
        #expect(origin.y > tab.maxY)
        let cardRect = CGRect(origin: origin, size: card)
        #expect(!cardRect.intersects(CGRect(origin: .zero, size: shelf)))
    }

    @Test("The card is centred on the hovered tab")
    func centredOnTab() {
        let tab = CGRect(x: 300, y: 6, width: 120, height: 28)
        let origin = TabHoverPreviewPlacement.origin(
            tabFrame: tab, cardSize: card, shelfSize: shelf)
        #expect(origin.x + card.width / 2 == tab.midX)
    }

    @Test("A narrow card on the first tab stays on that tab")
    func firstTabNarrowCard() {
        let tab = CGRect(x: 8, y: 6, width: 110, height: 28)
        let narrow = CGSize(width: 120, height: 40)
        let origin = TabHoverPreviewPlacement.origin(
            tabFrame: tab, cardSize: narrow, shelfSize: shelf)
        // Clamped only by the margin, not by a fixed half-width guess.
        #expect(origin.x == TabHoverPreviewPlacement.edgeMargin)
        #expect(origin.x < tab.midX && origin.x + narrow.width > tab.midX)
    }

    @Test("The card stays inside the group at the trailing edge")
    func trailingClamp() {
        let tab = CGRect(x: 820, y: 6, width: 110, height: 28)
        let origin = TabHoverPreviewPlacement.origin(
            tabFrame: tab, cardSize: card, shelfSize: shelf)
        #expect(origin.x + card.width == shelf.width - TabHoverPreviewPlacement.edgeMargin)
    }

    @Test("A card wider than the group keeps its leading edge in view")
    func widerThanShelf() {
        let tab = CGRect(x: 40, y: 6, width: 80, height: 28)
        let origin = TabHoverPreviewPlacement.origin(
            tabFrame: tab, cardSize: CGSize(width: 260, height: 40),
            shelfSize: CGSize(width: 200, height: 40))
        #expect(origin.x == TabHoverPreviewPlacement.edgeMargin)
    }

    @Test("A tab scrolled partly out of the strip still anchors inside the group")
    func scrolledTab() {
        let tab = CGRect(x: -60, y: 6, width: 110, height: 28)
        let origin = TabHoverPreviewPlacement.origin(
            tabFrame: tab, cardSize: card, shelfSize: shelf)
        #expect(origin.x == TabHoverPreviewPlacement.edgeMargin)
    }
}
