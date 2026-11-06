import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// UX Round A, B3: the overview's geometry.
@Suite("Ensemble overview geometry")
struct CanvasMinimapLayoutTests {
    private let visible = CGSize(width: 1_000, height: 700)
    private let cards = [
        CanvasRect(x: -2_000, y: -400, width: 380, height: 260),
        CanvasRect(x: 100, y: 100, width: 640, height: 420),
        CanvasRect(x: 3_000, y: 1_800, width: 380, height: 260),
    ]

    private var inner: CGRect {
        CGRect(origin: .zero, size: CanvasMinimapLayout.size).insetBy(
            dx: CanvasMinimapLayout.inset - 0.001, dy: CanvasMinimapLayout.inset - 0.001)
    }

    @Test("Every card and the visible board map inside the overview, minus its inset")
    func insideBounds() {
        let layout = CanvasMinimapLayout(
            cards: cards, viewport: CanvasViewport(scale: 0.5, x: 200, y: 100), visible: visible)
        for card in cards {
            #expect(inner.contains(layout.rect(card)), "\(card)")
        }
        #expect(inner.contains(layout.viewportRect))
    }

    @Test("boardPoint(at:) inverts rect(_:)")
    func inverse() {
        let layout = CanvasMinimapLayout(cards: cards, viewport: CanvasViewport(), visible: visible)
        let card = cards[1]
        let mapped = layout.rect(card)
        let back = layout.boardPoint(at: CGPoint(x: mapped.midX, y: mapped.midY))
        #expect(abs(back.x - (card.x + card.width / 2)) < 0.001)
        #expect(abs(back.y - (card.y + card.height / 2)) < 0.001)
    }

    @Test("viewport(centering:) puts the board point at the visible centre")
    func centering() {
        let point = CGPoint(x: 1_234, y: -567)
        let viewport = CanvasMinimapLayout.viewport(centering: point, scale: 0.75, visible: visible)
        #expect(viewport.scale == 0.75)
        #expect(abs(point.x * 0.75 + viewport.x - 500) < 0.001)
        #expect(abs(point.y * 0.75 + viewport.y - 350) < 0.001)
        #expect(viewport.isValid)
    }

    @Test("An empty board maps the visible board only")
    func emptyBoard() {
        let layout = CanvasMinimapLayout(cards: [], viewport: CanvasViewport(), visible: visible)
        #expect(inner.contains(layout.viewportRect))
        #expect(layout.viewportRect.width > 0)
    }
}
