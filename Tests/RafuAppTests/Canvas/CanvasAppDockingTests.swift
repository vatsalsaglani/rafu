import Foundation
import Testing

@testable import RafuApp

@Suite("Native app docking geometry, visibility, and summaries")
struct CanvasAppDockingTests {
    // MARK: Coordinates

    @Test("The card body sits below the header and scales with the board")
    func bodyRect() {
        let card = CGRect(x: 100, y: 40, width: 400, height: 333)
        let full = CanvasDockGeometry.bodyRect(
            card: card, translationX: 0, translationY: 0, scale: 1)
        #expect(full == CGRect(x: 100, y: 73, width: 400, height: 300))
        let zoomed = CanvasDockGeometry.bodyRect(
            card: card, translationX: -20, translationY: 10, scale: 0.75)
        #expect(zoomed == CGRect(x: 55, y: 64.75, width: 300, height: 225))
    }

    @Test("The visible board origin is the global frame minus the board-space frame")
    func visibleBoard() {
        let global = CGRect(x: 360, y: 180, width: 400, height: 300)
        let inBoard = CGRect(x: 100, y: 73, width: 400, height: 300)
        let board = CanvasDockGeometry.visibleBoard(
            global: global, inBoard: inBoard, boardSize: CGSize(width: 900, height: 600))
        #expect(board == CGRect(x: 260, y: 107, width: 900, height: 600))
    }

    @Test("Hosting view → window → screen → AX on the primary display")
    func primaryDisplayChain() {
        // A 1000-point-high unflipped content view; the body is 100 pt from its top.
        let body = CGRect(x: 50, y: 100, width: 400, height: 300)
        let window = CanvasDockGeometry.flipped(body, inHeight: 1_000)
        #expect(window == CGRect(x: 50, y: 600, width: 400, height: 300))
        let screen = CanvasDockGeometry.screenRect(
            window: window, windowOrigin: CGPoint(x: 200, y: 40))
        #expect(screen == CGRect(x: 250, y: 640, width: 400, height: 300))
        // Primary display 1440×1117: AX y = 1117 − (640 + 300).
        let ax = CanvasDockGeometry.axRect(screen: screen, primaryScreenHeight: 1_117)
        #expect(ax == CGRect(x: 250, y: 177, width: 400, height: 300))
        #expect(
            CanvasDockGeometry.screenRect(ax: ax, primaryScreenHeight: 1_117) == screen)
    }

    @Test(
        "Secondary displays share the primary display's flip",
        arguments: [
            // A display above the primary: AppKit y beyond the primary height.
            (
                CGRect(x: 100, y: 1_500, width: 400, height: 300),
                CGRect(x: 100, y: -683, width: 400, height: 300)
            ),
            // A display to the left: negative x is kept.
            (
                CGRect(x: -1_700, y: 200, width: 400, height: 300),
                CGRect(x: -1_700, y: 617, width: 400, height: 300)
            ),
            // A display below the primary: AX y beyond the primary height.
            (
                CGRect(x: 0, y: -900, width: 400, height: 300),
                CGRect(x: 0, y: 1_717, width: 400, height: 300)
            ),
        ])
    func multiDisplay(screen: CGRect, expected: CGRect) {
        #expect(CanvasDockGeometry.axRect(screen: screen, primaryScreenHeight: 1_117) == expected)
        #expect(CanvasDockGeometry.screenRect(ax: expected, primaryScreenHeight: 1_117) == screen)
    }

    @Test("A small app size adjustment is Rafu's placement; a move is the user's")
    func placementTolerance() {
        let expected = CGRect(x: 250, y: 177, width: 400, height: 300)
        #expect(CanvasDockGeometry.isRafuPlacement(expected, expected: expected))
        // A terminal rounding its size to whole cells.
        #expect(
            CanvasDockGeometry.isRafuPlacement(
                CGRect(x: 250, y: 177, width: 393, height: 289), expected: expected))
        #expect(
            !CanvasDockGeometry.isRafuPlacement(
                CGRect(x: 290, y: 177, width: 400, height: 300), expected: expected))
        #expect(
            !CanvasDockGeometry.isRafuPlacement(
                CGRect(x: 250, y: 177, width: 600, height: 300), expected: expected))
    }

    // MARK: Visibility and zoom

    @Test("An app's fixed or minimum window size must stay inside the visible card")
    func minimumWindowSize() {
        let body = CGRect(x: 200, y: 100, width: 400, height: 240)
        // Calculator can accept the position but keep a taller minimum size.
        #expect(
            !CanvasDockGeometry.fits(
                CGRect(x: 200, y: 100, width: 230, height: 408), inside: body))
        #expect(
            CanvasDockGeometry.fits(
                CGRect(x: 200, y: 100, width: 230, height: 408),
                inside: CGRect(x: 200, y: 100, width: 400, height: 440)))
        // Smaller fixed-size windows and pixel rounding are allowed.
        #expect(
            CanvasDockGeometry.fits(
                CGRect(x: 202, y: 98, width: 230, height: 240), inside: body))
        // A placement refused by the app must not cover a neighbouring node.
        #expect(!CanvasDockGeometry.fits(body.offsetBy(dx: 20, dy: 0), inside: body))
    }

    private func conditions(
        scale: Double = 1, body: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300)
    ) -> CanvasDockConditions {
        CanvasDockConditions(
            scale: scale, body: body, visibleBoard: CGRect(x: 0, y: 0, width: 1_000, height: 800))
    }

    @Test("A fully visible card at 100% places the window over its body")
    func placesVisibleCard() {
        #expect(
            CanvasDockVisibility.placement(conditions())
                == .place(CGRect(x: 100, y: 100, width: 400, height: 300)))
    }

    @Test("Docking needs at least 75% zoom")
    func zoomThreshold() {
        #expect(
            CanvasDockVisibility.placement(conditions(scale: 0.75))
                != .pause(.zoomedOut))
        #expect(CanvasDockVisibility.placement(conditions(scale: 0.74)) == .pause(.zoomedOut))
        #expect(CanvasDockVisibility.placement(conditions(scale: 0.3)) == .pause(.zoomedOut))
    }

    @Test("A partly visible body is clipped to the board; too little visible pauses")
    func clipping() {
        let partly = conditions(body: CGRect(x: 800, y: 100, width: 400, height: 300))
        #expect(
            CanvasDockVisibility.placement(partly)
                == .place(CGRect(x: 800, y: 100, width: 200, height: 300)))
        let sliver = conditions(body: CGRect(x: 950, y: 100, width: 400, height: 300))
        #expect(CanvasDockVisibility.placement(sliver) == .pause(.offBoard))
        let gone = conditions(body: CGRect(x: 2_000, y: 100, width: 400, height: 300))
        #expect(CanvasDockVisibility.placement(gone) == .pause(.offBoard))
    }

    @Test("Hidden Ensembles, hidden windows, other apps, and unmounted cards pause")
    func pauseReasons() {
        var value = conditions()
        value.isMounted = false
        #expect(CanvasDockVisibility.placement(value) == .pause(.notMounted))
        value.isFrontmostRafuOrDocked = false
        #expect(CanvasDockVisibility.placement(value) == .pause(.otherAppActive))
        value.isHostWindowVisible = false
        #expect(CanvasDockVisibility.placement(value) == .pause(.windowHidden))
        value.isLive = false
        #expect(CanvasDockVisibility.placement(value) == .pause(.ensembleHidden))
        var covered = conditions()
        covered.isCovered = true
        #expect(CanvasDockVisibility.placement(covered) == .pause(.covered))
    }

    @Test("Only a card drawn later and overlapping the body covers it")
    func covering() {
        let docked = CGRect(x: 0, y: 0, width: 400, height: 333)
        let overBody = CGRect(x: 300, y: 200, width: 200, height: 200)
        let overHeaderOnly = CGRect(x: 0, y: -100, width: 400, height: 120)
        #expect(CanvasDockVisibility.isCovered(index: 0, in: [docked, overBody]))
        #expect(!CanvasDockVisibility.isCovered(index: 1, in: [docked, overBody]))
        #expect(!CanvasDockVisibility.isCovered(index: 0, in: [docked, overHeaderOnly]))
        #expect(!CanvasDockVisibility.isCovered(index: 3, in: [docked]))
    }

    @Test("Placement is throttled to one update per display frame")
    func throttle() {
        var throttle = CanvasDockThrottle(framesPerSecond: 60)
        #expect(throttle.delay(at: 10) == 0)
        throttle.recordApply(at: 10)
        #expect(abs(throttle.delay(at: 10.004) - (1.0 / 60 - 0.004)) < 0.000_001)
        #expect(throttle.delay(at: 10.02) == 0)
        #expect(CanvasDockThrottle(framesPerSecond: 0).interval == 1.0 / 30)
        #expect(CanvasDockThrottle(framesPerSecond: 240).interval == 1.0 / 120)
    }

    @Test("States read plainly")
    func stateWords() {
        #expect(CanvasDockState.notDocked.label == "Not docked")
        #expect(CanvasDockState.docked.label == "Docked")
        #expect(CanvasDockState.paused(.zoomedOut).label == "Docked")
        #expect(CanvasDockState.undocked("moved").label == "Undocked")
        #expect(CanvasDockState.needsPermission.label == "Needs permission")
        #expect(CanvasDockState.paused(.zoomedOut).isDocked)
        #expect(!CanvasDockState.undocked("moved").isDocked)
        #expect(
            CanvasDockState.needsPermission.detail(appName: "Notes", identity: .release)
                == "Allow app control for Rafu in System Settings ▸ Privacy & Security.")
        #expect(
            CanvasDockState.needsPermission.detail(appName: "Notes", identity: .lightning)
                == "Allow app control for Rafu Lightning in System Settings ▸ Privacy & Security.")
        #expect(
            CanvasDockState.paused(.zoomedOut).detail(appName: "Notes")
                == "Zoom to 75% or more to use Notes here.")
    }

    // MARK: Accessibility summary

    struct FakeNode: CanvasAXSummaryNode {
        var role: String?
        var subrole: String?
        var title: String?
        var value: String?
        var frame: CGRect?
        var kids: [FakeNode] = []
        func children(limit: Int) -> [FakeNode] { Array(kids.prefix(limit)) }
    }

    @Test("The summary lists role, title, and value in tree order with indentation")
    func summaryShape() {
        let root = FakeNode(
            role: "AXWindow", title: "Notes",
            kids: [
                FakeNode(role: "AXButton", title: "New Note"),
                FakeNode(
                    role: "AXGroup",
                    kids: [FakeNode(role: "AXStaticText", value: "Line one\nLine two")]),
            ])
        let text = CanvasAXSummary.summarize(root: root, header: "Summary")
        #expect(
            text == """
                Summary
                AXWindow "Notes"
                  AXButton "New Note"
                  AXGroup
                    AXStaticText = "Line one Line two"

                """)
    }

    @Test("Secure text fields never contribute a value or children")
    func secureFieldsSkipped() {
        let secret = "hunter2-secret"
        let root = FakeNode(
            role: "AXWindow",
            kids: [
                FakeNode(
                    role: "AXTextField", subrole: "AXSecureTextField", title: "Password",
                    value: secret, kids: [FakeNode(role: "AXStaticText", value: secret)]),
                FakeNode(role: "AXSecureTextField", value: secret),
                FakeNode(role: "AXTextField", title: "User", value: "ada"),
            ])
        let text = CanvasAXSummary.summarize(root: root, header: "Summary")
        #expect(!text.contains(secret))
        #expect(text.contains("AXSecureTextField \"Password\" (value hidden)"))
        #expect(text.contains("AXTextField \"User\" = \"ada\""))
    }

    @Test("The summary is bounded by bytes, depth, and field length")
    func summaryBounds() {
        let long = String(repeating: "x", count: 5_000)
        let wide = FakeNode(
            role: "AXWindow",
            kids: (0..<2_000).map { FakeNode(role: "AXStaticText", value: "\($0) \(long)") })
        let text = CanvasAXSummary.summarize(root: wide, header: "Summary")
        #expect(text.utf8.count <= CanvasAXSummary.maximumBytes)
        #expect(text.hasSuffix(CanvasAXSummary.truncationMarker))
        #expect(
            !text.contains(
                String(repeating: "x", count: CanvasAXSummary.maximumFieldCharacters + 1)))

        var deep = FakeNode(role: "AXStaticText", title: "bottom")
        for _ in 0..<20 { deep = FakeNode(role: "AXGroup", kids: [deep]) }
        let nested = CanvasAXSummary.summarize(root: deep, header: "Summary")
        #expect(!nested.contains("bottom"))
        #expect(nested.split(separator: "\n").count == CanvasAXSummary.maximumDepth + 2)
    }

    @Test("Elements outside the window are skipped, and a stop request ends the walk")
    func visibilityAndDeadline() {
        let root = FakeNode(
            role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            kids: [
                FakeNode(
                    role: "AXButton", title: "Shown",
                    frame: CGRect(x: 10, y: 10, width: 50, height: 20)),
                FakeNode(
                    role: "AXButton", title: "Scrolled away",
                    frame: CGRect(x: 10, y: 900, width: 50, height: 20)),
            ])
        let text = CanvasAXSummary.summarize(
            root: root, header: "Summary", visibleRect: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(text.contains("Shown") && !text.contains("Scrolled away"))
        let stopped = CanvasAXSummary.summarize(
            root: root, header: "Summary", shouldContinue: { false })
        #expect(stopped == "Summary\n" + CanvasAXSummary.truncationMarker)
    }
}
