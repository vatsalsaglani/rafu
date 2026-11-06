import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// UX Round A, B1/B2: a board opens with its cards in view, and the zoom
/// capsule offers Fit while a card is out of view.
@Suite("Ensemble arrival and the Fit rule")
struct CanvasArrivalTests {
    private let visible = CGSize(width: 1_000, height: 700)
    private let card = CanvasRect(x: 100, y: 100, width: 400, height: 300)

    @Test("A board saved at 10 % with cards is fitted on arrival")
    func lowScaleFits() {
        let viewport = CanvasViewport(scale: 0.1, x: 0, y: 0)
        #expect(CanvasArrival.needsFit(cards: [card], viewport: viewport, visible: visible))
    }

    @Test("A card 30 % visible at 50 % keeps the parked viewport")
    func partlyVisibleKeeps() {
        // At 0.5 the card is 200 × 150 on screen. Put 30 % of each axis
        // inside the bottom-right corner of the view.
        let scale = 0.5
        let viewport = CanvasViewport(
            scale: scale, x: 1_000 - 100 * scale - 60, y: 700 - 100 * scale - 45)
        #expect(!CanvasArrival.needsFit(cards: [card], viewport: viewport, visible: visible))
        #expect(
            CanvasArrival.anyCardOutOfView(cards: [card], viewport: viewport, visible: visible)
                == false)
    }

    @Test("Every card off-screen at 100 % is fitted")
    func allOffScreenFits() {
        let viewport = CanvasViewport(scale: 1, x: -5_000, y: -5_000)
        #expect(CanvasArrival.needsFit(cards: [card], viewport: viewport, visible: visible))
        let fitted = CanvasArrival.fittedViewport(cards: [card], visible: visible)
        #expect(
            !CanvasArrival.anyCardOutOfView(cards: [card], viewport: fitted, visible: visible))
        #expect(fitted.scale <= 1)
    }

    @Test("An empty board at 10 % resets to the identity viewport; at 100 % it is kept")
    func emptyBoard() {
        #expect(
            CanvasArrival.needsFit(
                cards: [], viewport: CanvasViewport(scale: 0.1, x: 0, y: 0), visible: visible))
        #expect(CanvasArrival.fittedViewport(cards: [], visible: visible) == CanvasViewport())
        #expect(
            !CanvasArrival.needsFit(
                cards: [], viewport: CanvasViewport(scale: 1, x: 300, y: -40), visible: visible))
    }

    @Test("Fit shows for one far card and hides when every card is inside")
    func anyCardOutOfView() {
        let viewport = CanvasViewport()
        let far = CanvasRect(x: 9_000, y: 9_000, width: 380, height: 260)
        #expect(
            CanvasArrival.anyCardOutOfView(
                cards: [card, far], viewport: viewport, visible: visible))
        #expect(
            !CanvasArrival.anyCardOutOfView(cards: [card], viewport: viewport, visible: visible))
        #expect(!CanvasArrival.anyCardOutOfView(cards: [], viewport: viewport, visible: visible))
        // An unmeasured view never offers Fit.
        #expect(
            !CanvasArrival.anyCardOutOfView(cards: [far], viewport: viewport, visible: .zero))
    }

    @Test("Hand zoom stops at 25 %, but a board Fit left lower does not jump")
    func interactiveFloor() {
        #expect(CanvasZoomMetrics.interactiveClamped(0.05, from: 1) == 0.25)
        #expect(CanvasZoomMetrics.interactiveClamped(9, from: 1) == CanvasZoomMetrics.maximumScale)
        #expect(CanvasZoomMetrics.interactiveClamped(0.1, from: 0.15) == 0.15)
        #expect(CanvasZoomMetrics.interactiveClamped(0.18, from: 0.15) == 0.18)
        #expect(CanvasZoomMetrics.isAtInteractiveFloor(0.25))
        #expect(!CanvasZoomMetrics.isAtInteractiveFloor(0.3))
        // Old files at 10 % still decode.
        #expect(CanvasViewport(scale: 0.1, x: 0, y: 0).isValid)
    }
}
