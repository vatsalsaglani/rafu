import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

// The menu bar card's custom panel (ADR 0037, Phase B): where it goes under
// the status item, when it closes, its hit outline and reveal shape, and
// the feed routing flag it drives. Pure values, plus the model's card
// lifecycle on its own `NotchCompanionModel()` (never `.shared`).

private typealias Geometry = CompanionMenuPanelGeometry

/// A Dynamic Island Mac (Mac17,13): 45 pt menu bar, Dock at the bottom.
private let islandScreen = CompanionMenuPanelScreen(
    frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrame: CGRect(x: 0, y: 70, width: 1800, height: 1169 - 70 - 45))
/// A notched Mac: 37 pt menu bar, no Dock at the bottom.
private let notchedScreen = CompanionMenuPanelScreen(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 4, width: 1512, height: 982 - 4 - 37))
/// An external display to the right: 24 pt menu bar.
private let externalScreen = CompanionMenuPanelScreen(
    frame: CGRect(x: 1800, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1800, y: 0, width: 1920, height: 1080 - 24))

private func statusItem(on screen: CompanionMenuPanelScreen, x: CGFloat, width: CGFloat = 60)
    -> CGRect
{
    let bar = screen.frame.maxY - screen.visibleFrame.maxY
    return CGRect(x: x, y: screen.frame.maxY - bar, width: width, height: bar)
}

// MARK: - Placement

@Test("Panel size: 380 x 460 content plus one shoulder at each side")
func menuPanelSize() {
    #expect(Geometry.contentSize == CGSize(width: 380, height: 460))
    #expect(Geometry.outline == .open)
    #expect(Geometry.panelSize == CGSize(width: 380 + 24, height: 460))
    #expect(Geometry.collapsedHeight == 36)
}

@Test("Island Mac: the top edge sits on the 45 pt menu bar, centred under the item")
func menuPanelIslandPlacement() {
    let anchor = statusItem(on: islandScreen, x: 1400)
    let frame = Geometry.frame(anchor: anchor, screen: islandScreen)
    #expect(frame.maxY == CGFloat(1169 - 45))
    #expect(frame.midX == anchor.midX)
    #expect(frame.size == Geometry.panelSize)
}

@Test("Notched Mac: the top edge sits on the 37 pt menu bar")
func menuPanelNotchedPlacement() {
    let anchor = statusItem(on: notchedScreen, x: 1100)
    let frame = Geometry.frame(anchor: anchor, screen: notchedScreen)
    #expect(frame.maxY == notchedScreen.visibleFrame.maxY)
    #expect(notchedScreen.frame.maxY - frame.maxY == CGFloat(37))
    #expect(frame.midX == anchor.midX)
}

@Test("Clamping: the panel stays on the screen and its body 8 pt inside the visible sides")
func menuPanelEdgeClamping() {
    let s = Geometry.outline.shoulder
    // The shoulder is wider than the margin, so at a bare screen edge the
    // screen frame is the limit.
    let right = Geometry.frame(
        anchor: statusItem(on: islandScreen, x: 1770, width: 30), screen: islandScreen)
    #expect(right.maxX == islandScreen.frame.maxX)
    #expect(islandScreen.frame.maxX - (right.maxX - s) >= Geometry.screenMargin)
    let left = Geometry.frame(
        anchor: statusItem(on: islandScreen, x: 0, width: 30), screen: islandScreen)
    #expect(left.minX == islandScreen.frame.minX)
    #expect(left.minX + s >= Geometry.screenMargin)
    // A Dock on the left: the body keeps the margin from the Dock; the
    // shoulder may reach nearer.
    let docked = CompanionMenuPanelScreen(
        frame: islandScreen.frame,
        visibleFrame: CGRect(x: 80, y: 0, width: 1720, height: 1169 - 45))
    let besideDock = Geometry.frame(
        anchor: statusItem(on: docked, x: 90, width: 30), screen: docked)
    #expect(besideDock.minX + s == 80 + Geometry.screenMargin)
}

@Test("A short screen gives a shorter card above the Dock; sections scroll")
func menuPanelShortScreen() {
    let small = CompanionMenuPanelScreen(
        frame: CGRect(x: 0, y: 0, width: 800, height: 400),
        visibleFrame: CGRect(x: 0, y: 60, width: 800, height: 400 - 60 - 24))
    let frame = Geometry.frame(anchor: statusItem(on: small, x: 600), screen: small)
    #expect(frame.maxY == CGFloat(400 - 24))
    #expect(frame.minY == 60 + Geometry.screenMargin)
    #expect(frame.height < Geometry.contentSize.height)
}

@Test("Auto-hidden or full-screen menu bar: the shown item's bottom is the top edge")
func menuPanelHiddenMenuBar() {
    let fullScreen = CompanionMenuPanelScreen(
        frame: islandScreen.frame, visibleFrame: islandScreen.frame)
    let anchor = CGRect(x: 1400, y: 1169 - 45, width: 60, height: 45)
    #expect(Geometry.frame(anchor: anchor, screen: fullScreen).maxY == CGFloat(1169 - 45))
    // An anchor off the screen (no window frame yet) falls back to the
    // visible frame's top.
    let offScreen = CGRect(x: 1400, y: 5000, width: 60, height: 45)
    #expect(Geometry.frame(anchor: offScreen, screen: islandScreen).maxY == CGFloat(1169 - 45))
}

@Test("Multiple screens: the card opens on the screen that shows the item")
func menuPanelMultipleScreens() throws {
    let screens = [islandScreen, externalScreen]
    let external = statusItem(on: externalScreen, x: 3500)
    #expect(Geometry.screen(for: external, among: screens) == externalScreen)
    let frame = try #require(Geometry.frame(anchor: external, screens: screens))
    #expect(frame.maxY == CGFloat(1080 - 24))
    #expect(frame.minX >= externalScreen.frame.minX)
    #expect(frame.maxX <= externalScreen.frame.maxX)

    let builtIn = statusItem(on: islandScreen, x: 1400)
    #expect(Geometry.screen(for: builtIn, among: screens) == islandScreen)
    // An anchor whose centre is on no screen belongs to the one it overlaps
    // most (here 35 x 20 pt on the external display, 5 x 109 pt built in).
    let seam = CGRect(x: 1795, y: 1060, width: 40, height: 200)
    #expect(Geometry.screen(for: seam, among: screens) == externalScreen)
    #expect(Geometry.screen(for: .zero, among: []) == nil)
    #expect(Geometry.frame(anchor: builtIn, screens: []) == nil)
}

// MARK: - Close rules

@Test("Close rules: outside clicks, Escape, the item, Spaces, and lock close; inside does not")
func menuPanelClosePolicy() {
    typealias Policy = CompanionMenuPanelClosePolicy
    #expect(!Policy.closes(on: .mouseDown(.panel)))
    // The item's own action toggles the card.
    #expect(!Policy.closes(on: .mouseDown(.statusItem)))
    #expect(Policy.closes(on: .mouseDown(.otherRafuWindow)))
    #expect(Policy.closes(on: .mouseDown(.otherApp)))
    for event: CompanionMenuPanelCloseEvent in [
        .escape, .statusItemToggled, .closeButton, .activeSpaceChanged, .screenLocked,
        .resignedKey, .removed,
    ] {
        #expect(Policy.closes(on: event))
    }
}

@Test("Click targets: global is another app; local matches the panel or the item window")
func menuPanelClickTargets() {
    typealias Policy = CompanionMenuPanelClosePolicy
    #expect(
        Policy.clickTarget(
            isGlobal: true, eventWindowNumber: 7, panelWindowNumber: 7, statusItemWindowNumber: 9)
            == .otherApp)
    #expect(
        Policy.clickTarget(
            isGlobal: false, eventWindowNumber: 7, panelWindowNumber: 7, statusItemWindowNumber: 9)
            == .panel)
    #expect(
        Policy.clickTarget(
            isGlobal: false, eventWindowNumber: 9, panelWindowNumber: 7, statusItemWindowNumber: 9)
            == .statusItem)
    #expect(
        Policy.clickTarget(
            isGlobal: false, eventWindowNumber: 3, panelWindowNumber: 7, statusItemWindowNumber: 9)
            == .otherRafuWindow)
    #expect(
        Policy.clickTarget(
            isGlobal: false, eventWindowNumber: nil, panelWindowNumber: 7,
            statusItemWindowNumber: 9) == .otherApp)
}

// MARK: - Hit outline and reveal

@Test("Hit outline: the body takes clicks; beside a shoulder and below a corner it does not")
func menuPanelHitOutline() {
    let size = Geometry.panelSize
    let s = Geometry.outline.shoulder
    let inside = { CompanionOutline.contains($0, size: size, limits: Geometry.outline) }
    #expect(inside(CGPoint(x: size.width / 2, y: 1)))
    #expect(inside(CGPoint(x: size.width / 2, y: size.height / 2)))
    #expect(inside(CGPoint(x: s + 2, y: s + 2)))
    // Beside the left shoulder, under its curve.
    #expect(!inside(CGPoint(x: 2, y: s - 1)))
    // Beside the body, below the shoulders.
    #expect(!inside(CGPoint(x: s / 2, y: size.height / 2)))
    #expect(!inside(CGPoint(x: size.width - s / 2, y: size.height / 2)))
    // Outside a round bottom corner.
    #expect(!inside(CGPoint(x: s + 1, y: size.height - 1)))
}

@Test("Reveal shape: collapsed to three shoulders at 0, the full outline at 1, clamped")
func menuPanelRevealShape() {
    let rect = CGRect(origin: .zero, size: Geometry.panelSize)
    #expect(
        CompanionMenuRevealShape.revealedRect(in: rect, progress: 0).height
            == Geometry.collapsedHeight)
    #expect(CompanionMenuRevealShape.revealedRect(in: rect, progress: 1) == rect)
    #expect(CompanionMenuRevealShape.revealedRect(in: rect, progress: 2) == rect)
    #expect(
        CompanionMenuRevealShape.revealedRect(in: rect, progress: -1).height
            == Geometry.collapsedHeight)
    let half = CompanionMenuRevealShape.revealedRect(in: rect, progress: 0.5)
    #expect(half.minY == 0)
    #expect(half.height == Geometry.collapsedHeight + (rect.height - Geometry.collapsedHeight) / 2)
    // At 1 the reveal draws exactly the companion outline.
    #expect(
        CompanionMenuRevealShape(progress: 1).path(in: rect)
            == CompanionOutline(limits: Geometry.outline).path(in: rect))
}

// MARK: - Feed routing parity

@MainActor
@Test("Routing flag: the open card takes bells; a closed card hands them to the drop-down")
func menuPanelRoutingParity() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.menu-panel-routing")
    defer { TestDefaultsSuite.remove(suite) }
    let model = NotchCompanionModel()
    model.displayPreferences = NotchDisplayPreferenceStore(suiteName: suite)
    model.setSurfaceForTesting(.island)

    model.menuPopoverWillShow()
    let open = CompanionHoverPolicy.companionArbitration(
        hoverState: model.hoverState, feedAvailable: model.isAttentionFeedAvailable,
        menuPopoverShown: model.isMenuPopoverShown)
    #expect(open.routeToFeed && !open.showDropDown)

    model.menuPopoverDidClose()
    let closed = CompanionHoverPolicy.companionArbitration(
        hoverState: model.hoverState, feedAvailable: model.isAttentionFeedAvailable,
        menuPopoverShown: model.isMenuPopoverShown)
    #expect(!closed.routeToFeed && closed.showDropDown)
}
