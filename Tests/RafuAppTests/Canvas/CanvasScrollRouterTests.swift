import AppKit
import Foundation
import Testing

@testable import RafuApp

/// Wheel and trackpad routing over the board: a hovered card's scroll view
/// gets the scroll while it can move that way; otherwise the board pans.
@Suite("Canvas scroll router")
struct CanvasScrollRouterTests {
    typealias Input = CanvasScrollRouter.Input

    /// A 100 pt tall view over 300 pt of content, `y` pt from the top.
    static func vertical(y: Double) -> CanvasScrollExtent {
        CanvasScrollExtent(
            offset: CGPoint(x: 0, y: y), contentSize: CGSize(width: 200, height: 300),
            visibleSize: CGSize(width: 200, height: 100))
    }

    /// A 200 pt wide code block over 500 pt of content, `x` pt from leading.
    static func horizontal(x: Double) -> CanvasScrollExtent {
        CanvasScrollExtent(
            offset: CGPoint(x: x, y: 0), contentSize: CGSize(width: 500, height: 40),
            visibleSize: CGSize(width: 200, height: 40))
    }

    static let fits = CanvasScrollExtent(
        offset: .zero, contentSize: CGSize(width: 200, height: 80),
        visibleSize: CGSize(width: 200, height: 100))

    static func input(
        _ phase: CanvasScrollRouter.Phase, at time: TimeInterval = 0, dx: Double = 0,
        dy: Double = -10, zoom: Bool = false, pan: Bool = false, active: Bool = false,
        extents: [CanvasScrollExtent] = []
    ) -> Input {
        Input(
            phase: phase, timestamp: time, deltaX: dx, deltaY: dy, zoomModifier: zoom,
            panOverridesCards: pan, overActiveCardBody: active, extents: extents)
    }

    // MARK: Extent

    @Test("canScroll stops within 0.5 pt of each end")
    func extentEnds() {
        // Negative deltaY moves toward the bottom.
        #expect(Self.vertical(y: 0).canScroll(deltaX: 0, deltaY: -5))
        #expect(!Self.vertical(y: 0).canScroll(deltaX: 0, deltaY: 5))
        #expect(!Self.vertical(y: 0.4).canScroll(deltaX: 0, deltaY: 5))
        #expect(Self.vertical(y: 0.6).canScroll(deltaX: 0, deltaY: 5))
        #expect(!Self.vertical(y: 200).canScroll(deltaX: 0, deltaY: -5))
        #expect(!Self.vertical(y: 199.6).canScroll(deltaX: 0, deltaY: -5))
        #expect(Self.vertical(y: 199.4).canScroll(deltaX: 0, deltaY: -5))
        #expect(Self.vertical(y: 200).canScroll(deltaX: 0, deltaY: 5))
    }

    @Test("canScroll uses the dominant axis, vertical on a tie")
    func extentDominantAxis() {
        let middle = CanvasScrollExtent(
            offset: CGPoint(x: 0, y: 100), contentSize: CGSize(width: 200, height: 300),
            visibleSize: CGSize(width: 200, height: 100))
        #expect(middle.canScroll(deltaX: 3, deltaY: -4))
        #expect(!middle.canScroll(deltaX: -5, deltaY: -4))
        #expect(middle.canScroll(deltaX: 5, deltaY: -5))
        #expect(Self.horizontal(x: 0).canScroll(deltaX: -8, deltaY: 1))
        #expect(!Self.horizontal(x: 0).canScroll(deltaX: 8, deltaY: 1))
        #expect(!Self.horizontal(x: 300).canScroll(deltaX: -8, deltaY: 1))
    }

    @Test("Zero deltas ask whether the view overflows at all")
    func extentZeroDelta() {
        #expect(Self.vertical(y: 0).canScroll(deltaX: 0, deltaY: 0))
        #expect(Self.horizontal(x: 0).canScroll(deltaX: 0, deltaY: 0))
        #expect(!Self.fits.canScroll(deltaX: 0, deltaY: 0))
        #expect(!Self.fits.canScroll(deltaX: 0, deltaY: -5))
    }

    // MARK: Rules in order

    @Test("Space or the Hand tool pans the board over everything")
    func ruleOnePanOverride() {
        var router = CanvasScrollRouter()
        let route = router.route(
            Self.input(.began, zoom: true, pan: true, active: true, extents: [Self.vertical(y: 0)]))
        #expect(route == .board)
    }

    @Test("The content-active card body gets the event with any modifier")
    func ruleTwoActiveBody() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, zoom: true, active: true)) == .content)
        var plain = CanvasScrollRouter()
        #expect(plain.route(Self.input(.began, active: true)) == .content)
    }

    @Test("⌘ or ⌃ zooms even over a scrollable card")
    func ruleThreeZoom() {
        var router = CanvasScrollRouter()
        #expect(
            router.route(Self.input(.began, zoom: true, extents: [Self.vertical(y: 0)])) == .zoom)
    }

    @Test("A scroll view that can move gets the event; one that cannot leaves it to the board")
    func ruleFourAndFive() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, extents: [Self.vertical(y: 0)])) == .content)
        var atEnd = CanvasScrollRouter()
        #expect(atEnd.route(Self.input(.began, extents: [Self.vertical(y: 200)])) == .board)
        var short = CanvasScrollRouter()
        #expect(short.route(Self.input(.began, extents: [Self.fits])) == .board)
        var none = CanvasScrollRouter()
        #expect(none.route(Self.input(.began)) == .board)
    }

    @Test("A vertical swipe over a horizontal code block scrolls the outer note")
    func nestedHorizontalInsideVertical() {
        let nested = [Self.horizontal(x: 0), Self.vertical(y: 50)]
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, dy: -6, extents: nested)) == .content)
        var sideways = CanvasScrollRouter()
        #expect(sideways.route(Self.input(.began, dx: -6, dy: 0, extents: nested)) == .content)
        let bottom = [Self.horizontal(x: 300), Self.vertical(y: 200)]
        var stuck = CanvasScrollRouter()
        #expect(stuck.route(Self.input(.began, dx: -6, dy: 0, extents: bottom)) == .board)
    }

    @Test("Zero-delta began goes to content that overflows")
    func zeroDeltaBegan() {
        var router = CanvasScrollRouter()
        #expect(
            router.route(Self.input(.began, dy: 0, extents: [Self.vertical(y: 200)])) == .content)
        var short = CanvasScrollRouter()
        #expect(short.route(Self.input(.began, dy: 0, extents: [Self.fits])) == .board)
    }

    // MARK: Latching

    @Test("A gesture keeps its route through changed, ended and momentum")
    func latchThroughGesture() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, at: 0, extents: [Self.vertical(y: 0)])) == .content)
        #expect(!router.needsDecision(.changed, at: 0.1))
        // The card reached its end mid-gesture: the gesture stays with it.
        #expect(router.route(Self.input(.changed, at: 0.1)) == .content)
        #expect(router.route(Self.input(.ended, at: 0.2)) == .content)
        #expect(router.route(Self.input(.momentum, at: 0.3)) == .content)
        #expect(router.route(Self.input(.momentum, at: 0.9)) == .content)
        // The next gesture starts at the end: the board takes it.
        #expect(router.needsDecision(.began, at: 2))
        #expect(router.route(Self.input(.began, at: 2, extents: [Self.vertical(y: 200)])) == .board)
        #expect(
            router.route(Self.input(.changed, at: 2.1, extents: [Self.vertical(y: 0)])) == .board)
    }

    @Test("A board gesture re-reads ⌘ and Space per event")
    func boardLatchReadsModifiers() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, at: 0)) == .board)
        #expect(router.route(Self.input(.changed, at: 0.1, zoom: true)) == .zoom)
        #expect(router.route(Self.input(.changed, at: 0.2, zoom: true, pan: true)) == .board)
        #expect(router.route(Self.input(.changed, at: 0.3)) == .board)
    }

    @Test("A content gesture ignores ⌘ pressed mid-gesture")
    func contentLatchIgnoresModifiers() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, extents: [Self.vertical(y: 0)])) == .content)
        #expect(router.route(Self.input(.changed, at: 0.1, zoom: true)) == .content)
    }

    @Test("mayBegin and cancelled clear the latch; mayBegin passes through")
    func mayBeginAndCancelled() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, extents: [Self.vertical(y: 0)])) == .content)
        #expect(router.route(Self.input(.cancelled, at: 0.1)) == .content)
        #expect(router.needsDecision(.changed, at: 0.2))
        #expect(router.route(Self.input(.mayBegin, at: 5)) == .content)
        #expect(router.needsDecision(.changed, at: 5.1))
        // An unlatched changed event decides on its own.
        #expect(router.route(Self.input(.changed, at: 5.1)) == .board)
    }

    @Test("A legacy wheel keeps its route while ticks are under 0.25 s apart")
    func legacyLatch() {
        var router = CanvasScrollRouter()
        #expect(
            router.route(Self.input(.legacy, at: 0, extents: [Self.vertical(y: 0)])) == .content)
        #expect(!router.needsDecision(.legacy, at: 0.2))
        #expect(
            router.route(Self.input(.legacy, at: 0.2, extents: [Self.vertical(y: 200)])) == .content
        )
        // 0.3 s after the last tick: a fresh decision.
        #expect(router.needsDecision(.legacy, at: 0.5))
        #expect(
            router.route(Self.input(.legacy, at: 0.5, extents: [Self.vertical(y: 200)])) == .board)
    }

    @Test("A gesture that starts under 0.3 s after a board pan stays with the board")
    func panStreak() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, at: 0)) == .board)
        #expect(router.route(Self.input(.momentum, at: 1)) == .board)
        // 0.2 s after the last board pan, over a scrollable card.
        #expect(router.route(Self.input(.began, at: 1.2, extents: [Self.vertical(y: 0)])) == .board)
        // 0.4 s after the last board pan.
        var later = CanvasScrollRouter()
        #expect(later.route(Self.input(.began, at: 0)) == .board)
        #expect(
            later.route(Self.input(.began, at: 0.4, extents: [Self.vertical(y: 0)])) == .content)
    }

    @Test("The pan streak does not take the content-active card body or zoom")
    func panStreakKeepsEarlierRules() {
        var router = CanvasScrollRouter()
        #expect(router.route(Self.input(.began, at: 0)) == .board)
        #expect(router.route(Self.input(.began, at: 0.1, active: true)) == .content)
        var zoom = CanvasScrollRouter()
        #expect(zoom.route(Self.input(.began, at: 0)) == .board)
        #expect(zoom.route(Self.input(.began, at: 0.1, zoom: true)) == .zoom)
    }

    // MARK: AppKit adapter

    @Test("AppKit phases map to router phases")
    @MainActor
    func phaseMapping() {
        typealias Host = CanvasScrollBridge.Host
        #expect(Host.routerPhase(phase: .mayBegin, momentumPhase: []) == .mayBegin)
        #expect(Host.routerPhase(phase: .began, momentumPhase: []) == .began)
        #expect(Host.routerPhase(phase: .changed, momentumPhase: []) == .changed)
        #expect(Host.routerPhase(phase: .stationary, momentumPhase: []) == .changed)
        #expect(Host.routerPhase(phase: .ended, momentumPhase: []) == .ended)
        #expect(Host.routerPhase(phase: .cancelled, momentumPhase: []) == .cancelled)
        #expect(Host.routerPhase(phase: [], momentumPhase: .began) == .momentum)
        #expect(Host.routerPhase(phase: [], momentumPhase: .changed) == .momentum)
        #expect(Host.routerPhase(phase: [], momentumPhase: .ended) == .momentum)
        #expect(Host.routerPhase(phase: [], momentumPhase: []) == .legacy)
    }

    @Test("A scroll view's extent measures from the top of a flipped document")
    @MainActor
    func extentOfScrollView() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let document = FlippedView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        scrollView.documentView = document
        let top = CanvasScrollBridge.Host.extent(of: scrollView)
        #expect(top?.contentSize == CGSize(width: 200, height: 300))
        #expect(top?.visibleSize == CGSize(width: 200, height: 100))
        #expect(top?.offset.y == 0)
        #expect(top?.canScroll(deltaX: 0, deltaY: -5) == true)
        #expect(top?.canScroll(deltaX: 0, deltaY: 5) == false)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 200))
        let bottom = CanvasScrollBridge.Host.extent(of: scrollView)
        #expect(bottom?.offset.y == 200)
        #expect(bottom?.canScroll(deltaX: 0, deltaY: -5) == false)
        #expect(bottom?.canScroll(deltaX: 0, deltaY: 5) == true)
    }

    @Test("A scroll view's extent measures from the top of an unflipped document")
    @MainActor
    func extentOfUnflippedScrollView() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        // Unflipped: origin y 200 shows the top of the document.
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 200))
        #expect(CanvasScrollBridge.Host.extent(of: scrollView)?.offset.y == 0)
        scrollView.contentView.scroll(to: .zero)
        #expect(CanvasScrollBridge.Host.extent(of: scrollView)?.offset.y == 200)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
