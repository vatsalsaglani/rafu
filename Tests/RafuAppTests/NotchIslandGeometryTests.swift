import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// Dynamic Island screens (Mac17,13, macOS 27.2): cutout classification, the
/// "shared island" capsule geometry, the regression lock that keeps notched
/// and plain screens unchanged, and the island usage glance. Every metric
/// below is a real measurement; nothing here reads `NSScreen`.

/// Mac17,13: 1512×993 pt, 40 pt top inset, 59 pt island camera at x 726.5.
private let islandScreen = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 993),
    visibleFrame: CGRect(x: 0, y: 75, width: 1512, height: 873),
    safeAreaTopInset: 40,
    auxiliaryTopLeft: CGRect(x: 0, y: 953, width: 726.5, height: 40),
    auxiliaryTopRight: CGRect(x: 785.5, y: 953, width: 726.5, height: 40),
    isBuiltin: true,
    backingScaleFactor: 2)

/// 14-inch MacBook Pro: 1710×1107 pt, 33 pt inset, 185 pt notch.
private let notchedScreen = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
    visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
    safeAreaTopInset: 33,
    auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 763, height: 33),
    auxiliaryTopRight: CGRect(x: 948, y: 1074, width: 762, height: 33))

private let plainScreen = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
    safeAreaTopInset: 0,
    auxiliaryTopLeft: nil,
    auxiliaryTopRight: nil)

/// An island screen whose inset is fractional (macOS 27 can report 33.5 or
/// 40.25), to prove every frame snaps to the pixel grid.
private let fractionalIslandScreen = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 993),
    visibleFrame: CGRect(x: 0, y: 75, width: 1512, height: 873),
    safeAreaTopInset: 40.25,
    auxiliaryTopLeft: CGRect(x: 0, y: 952.75, width: 726.5, height: 40.25),
    auxiliaryTopRight: CGRect(x: 785.5, y: 952.75, width: 726.5, height: 40.25),
    isBuiltin: true,
    backingScaleFactor: 2)

// MARK: - Classification

@Test("cutout: island camera, notch, none, and a one-sided aux area")
func islandCutoutClassification() {
    #expect(NotchHUDGeometry.cutout(for: islandScreen) == .islandCamera)
    #expect(NotchHUDGeometry.cutout(for: notchedScreen) == .notch)
    #expect(NotchHUDGeometry.cutout(for: plainScreen) == .none)
    let oneSided = NotchScreenMetrics(
        frame: islandScreen.frame, visibleFrame: islandScreen.visibleFrame,
        safeAreaTopInset: 40, auxiliaryTopLeft: islandScreen.auxiliaryTopLeft,
        auxiliaryTopRight: nil)
    #expect(NotchHUDGeometry.cutout(for: oneSided) == .none)
}

@Test("cutout: fractional insets keep their class (33.5 notch, 40.25 island)")
func islandCutoutFractionalInsets() {
    let fractionalNotch = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTopInset: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 763, height: 33.5),
        auxiliaryTopRight: CGRect(x: 948, y: 1073.5, width: 762, height: 33.5))
    #expect(NotchHUDGeometry.cutout(for: fractionalNotch) == .notch)
    #expect(NotchHUDGeometry.cutout(for: fractionalIslandScreen) == .islandCamera)
}

@Test("housingRect finds the island camera; notchRect is nil there and unchanged on a notch")
func islandHousingAndNotchRect() {
    #expect(
        NotchHUDGeometry.housingRect(for: islandScreen)
            == CGRect(x: 726.5, y: 953, width: 59, height: 40))
    #expect(NotchHUDGeometry.notchRect(for: islandScreen) == nil)
    #expect(
        NotchHUDGeometry.notchRect(for: notchedScreen)
            == CGRect(x: 763, y: 1074, width: 185, height: 33))
}

@Test("hudFrame on an island: the no-notch layout below the menu bar, no black band")
func islandHUDFrameUsesNoNotchLayout() {
    let content = CGSize(width: 360, height: 120)
    let frame = NotchHUDGeometry.hudFrame(
        for: islandScreen, contentSize: content, state: .compact)
    #expect(frame.maxY == 948)
    #expect(frame.width == content.width)
    #expect(frame.height == content.height)
    #expect(NotchHUDGeometry.bandInset(for: islandScreen) == 0)
}

// MARK: - Island geometry

@Test("island frames: resting, wide, and open on Mac17,13")
func islandFramesOnReferenceScreen() {
    #expect(NotchIslandGeometry.scale(for: islandScreen) == 1)
    #expect(NotchIslandGeometry.systemReserveHalfWidth(for: islandScreen) == 70)
    #expect(
        NotchIslandGeometry.restingFrame(for: islandScreen)
            == CGRect(x: 701.5, y: 911, width: 109, height: 33))
    #expect(
        NotchIslandGeometry.wideFrame(for: islandScreen)
            == CGRect(x: 615, y: 911, width: 282, height: 33))
    #expect(
        NotchIslandGeometry.openFrame(for: islandScreen, contentHeight: 373)
            == CGRect(x: 536, y: 571, width: 440, height: 373))
    #expect(NotchIslandGeometry.openCornerRadius(for: islandScreen) == 28)
}

@Test("island frames are nil on a notched screen and on a plain screen")
func islandFramesNilElsewhere() {
    for screen in [notchedScreen, plainScreen] {
        #expect(NotchIslandGeometry.systemReserveHalfWidth(for: screen) == nil)
        #expect(NotchIslandGeometry.restingFrame(for: screen) == nil)
        #expect(NotchIslandGeometry.wideFrame(for: screen) == nil)
        #expect(NotchIslandGeometry.openFrame(for: screen, contentHeight: 373) == nil)
        #expect(NotchIslandGeometry.systemZone(for: screen) == nil)
    }
}

@Test(
    "island nesting: housing ⊂ resting ⊂ menu-bar gap; system pill ⊂ reserve ⊂ wide ⊂ system card ⊂ open card"
)
func islandNestingAgainstMeasuredSystemIsland() throws {
    let reserve = try #require(NotchIslandGeometry.systemReserveHalfWidth(for: islandScreen))
    let center = try #require(NotchHUDGeometry.housingRect(for: islandScreen)).midX
    let resting = try #require(NotchIslandGeometry.restingFrame(for: islandScreen))
    let wide = try #require(NotchIslandGeometry.wideFrame(for: islandScreen))
    let open = try #require(
        NotchIslandGeometry.openFrame(for: islandScreen, contentHeight: 373))
    // Measured from screenshots of the system island (pt).
    let systemMusicPill: ClosedRange<CGFloat> = 688.7...819.5
    let systemClickedCard: ClosedRange<CGFloat> = 613.7...898.3

    // The resting pill is about as wide as the menu bar's gap around the
    // island (menu titles end at x ≈ 701 and resume at x ≈ 807, ±1 pt).
    let housing = try #require(NotchHUDGeometry.housingRect(for: islandScreen))
    #expect(resting.minX <= housing.minX && housing.maxX <= resting.maxX)
    #expect(resting.minX >= 700 && resting.maxX <= 812)
    #expect(wide.minX <= resting.minX && resting.maxX <= wide.maxX)

    let chain: [ClosedRange<CGFloat>] = [
        systemMusicPill,
        (center - reserve)...(center + reserve),
        wide.minX...wide.maxX,
        systemClickedCard,
        open.minX...open.maxX,
    ]
    for (inner, outer) in zip(chain, chain.dropFirst()) {
        #expect(outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound)
    }
    let zone = try #require(NotchIslandGeometry.systemZone(for: islandScreen))
    #expect(zone == CGRect(x: 686, y: 953.5, width: 140, height: 39.5))
}

@Test("island pill hangs 4 pt below the menu bar, never inside the menu-bar band")
func islandCapsuleVerticalPlacement() throws {
    let resting = try #require(NotchIslandGeometry.restingFrame(for: islandScreen))
    #expect(resting.maxY == islandScreen.visibleFrame.maxY - 4)
    #expect(resting.maxY < islandScreen.visibleFrame.maxY)
}

@Test("island open card: oversized content caps at maxPeekHeight and stays on screen")
func islandOpenCardCaps() throws {
    let cap = NotchCompanionGeometry.maxPeekHeight(for: islandScreen)
    let open = try #require(
        NotchIslandGeometry.openFrame(for: islandScreen, contentHeight: 5000))
    #expect(open.height == cap)
    #expect(open.maxY == islandScreen.visibleFrame.maxY - 4)
    #expect(islandScreen.frame.contains(open))
}

@Test("island frames snap to the pixel grid for a fractional inset")
func islandFramesSnapToPixels() throws {
    let scale = fractionalIslandScreen.backingScaleFactor
    let rects = [
        try #require(NotchIslandGeometry.restingFrame(for: fractionalIslandScreen)),
        try #require(NotchIslandGeometry.wideFrame(for: fractionalIslandScreen)),
        try #require(
            NotchIslandGeometry.openFrame(for: fractionalIslandScreen, contentHeight: 373.3)),
        try #require(NotchIslandGeometry.systemZone(for: fractionalIslandScreen)),
    ]
    for rect in rects {
        for value in [rect.minX, rect.minY, rect.width, rect.height] {
            #expect((value * scale).rounded() == value * scale)
        }
    }
    #expect(NotchHUDGeometry.pixelAligned(1.3, scale: 2) == 1.5)
    #expect(NotchHUDGeometry.pixelAligned(1.3, scale: 0) == 1)
}

// MARK: - Companion surface and frame dispatch

@Test("surface: notch, island, and pill only when allowed")
func islandSurfaceMapping() {
    #expect(NotchCompanionGeometry.surface(for: islandScreen, allowsPill: false) == .island)
    #expect(NotchCompanionGeometry.surface(for: islandScreen, allowsPill: true) == .island)
    #expect(NotchCompanionGeometry.surface(for: notchedScreen, allowsPill: true) == .notch)
    #expect(NotchCompanionGeometry.surface(for: plainScreen, allowsPill: true) == .pill)
    #expect(NotchCompanionGeometry.surface(for: plainScreen, allowsPill: false) == nil)
}

@Test("island dispatch: no pill, no notch strip; resting/expanded/peek use the capsule")
func islandFrameDispatch() {
    #expect(NotchCompanionGeometry.pillFrame(for: islandScreen) == nil)
    #expect(NotchCompanionGeometry.restingStripFrame(for: islandScreen) == nil)
    #expect(NotchCompanionGeometry.expandedStripFrame(for: islandScreen) == nil)
    #expect(
        NotchCompanionGeometry.restingFrame(for: islandScreen, allowsPill: true)
            == NotchIslandGeometry.restingFrame(for: islandScreen))
    #expect(
        NotchCompanionGeometry.restingFrame(for: islandScreen, allowsPill: false)
            == NotchIslandGeometry.restingFrame(for: islandScreen))
    #expect(
        NotchCompanionGeometry.expandedFrame(for: islandScreen, allowsPill: false)
            == NotchIslandGeometry.wideFrame(for: islandScreen))
    #expect(
        NotchCompanionGeometry.peekPanelFrame(for: islandScreen, contentHeight: 373)
            == NotchIslandGeometry.openFrame(for: islandScreen, contentHeight: 373))
}

@Test("regression lock: notched and plain screens keep their exact frames")
func islandRegressionLockNotchedAndPlain() {
    #expect(
        NotchCompanionGeometry.restingStripFrame(for: notchedScreen)
            == CGRect(x: 679, y: 1074, width: 269, height: 33))
    #expect(
        NotchCompanionGeometry.expandedStripFrame(for: notchedScreen)
            == CGRect(x: 673, y: 1074, width: 365, height: 33))
    #expect(
        NotchCompanionGeometry.restingFrame(for: notchedScreen, allowsPill: true)
            == CGRect(x: 679, y: 1074, width: 269, height: 33))
    #expect(
        NotchCompanionGeometry.expandedFrame(for: notchedScreen, allowsPill: true)
            == CGRect(x: 673, y: 1074, width: 365, height: 33))
    let peek = NotchCompanionGeometry.peekPanelFrame(for: notchedScreen, contentHeight: 373)
    // The open panel is 440 plus a 12 pt concave shoulder on each side
    // (`CompanionOutline`, Cider's notch outline); still centred on the notch.
    #expect(peek == CGRect(x: 623.5, y: 734, width: 464, height: 373))
    #expect(peek.maxY == 1107)

    #expect(
        NotchCompanionGeometry.restingFrame(for: plainScreen, allowsPill: true)
            == NotchCompanionGeometry.pillFrame(for: plainScreen))
    #expect(
        NotchCompanionGeometry.expandedFrame(for: plainScreen, allowsPill: true)
            == NotchCompanionGeometry.pillFrame(for: plainScreen, expanded: true))
    #expect(NotchCompanionGeometry.restingFrame(for: plainScreen, allowsPill: false) == nil)
}

@Test("preferredForCompanion: an island screen beats an earlier plain one; preferred does not")
func islandCompanionScreenSelection() {
    #expect(
        NotchScreenSelection.preferredForCompanion(from: [plainScreen, islandScreen])
            == islandScreen)
    #expect(NotchScreenSelection.preferred(from: [plainScreen, islandScreen]) == plainScreen)
}

// MARK: - Usage glance

private let glanceNow = Date(timeIntervalSince1970: 1_800_000_000)

private func glanceSnapshot(_ id: UsageProviderID, _ windows: [(String, Double?)])
    -> UsageSnapshot
{
    UsageSnapshot(
        providerID: id,
        windows: windows.map { label, percent in
            UsageWindow(
                label: label, percent: percent, tokens: percent == nil ? 1_000 : nil,
                resetsAt: nil)
        },
        costLine: nil, identity: nil)
}

private func glanceName(_ id: UsageProviderID) -> String {
    id == .claude ? "Claude" : "Codex"
}

private func glance(_ frontLine: [UsageSnapshot], mode: UsageDisplayMode = .used)
    -> NotchIslandUsageGlance?
{
    NotchIslandUsageGlance.resolve(
        frontLine: frontLine, observedAt: [:], mode: mode, displayName: glanceName,
        now: glanceNow)
}

@Test("usage glance: nil without a ring window")
func islandGlanceNilWithoutRingWindow() {
    #expect(glance([]) == nil)
    #expect(glance([glanceSnapshot(.claude, [("5h", nil)])]) == nil)
}

@Test("usage glance: one window reads as its percent, level, and spoken label")
func islandGlanceSingleWindow() throws {
    let result = try #require(glance([glanceSnapshot(.claude, [("5h", 83)])]))
    #expect(result.fraction == 0.83)
    #expect(result.percentText == "83%")
    #expect(result.level == .warning)
    #expect(result.tone == .primary)
    #expect(result.spokenLabel == "Usage: Claude, 5-hour session 83%, warning")

    let calm = try #require(glance([glanceSnapshot(.claude, [("5h", 41)])]))
    #expect(calm.level == .normal)
    #expect(calm.spokenLabel == "Usage: Claude, 5-hour session 41%")
}

@Test("usage glance: the worst level wins across providers")
func islandGlanceWorstLevelWins() throws {
    let result = try #require(
        glance([
            glanceSnapshot(.claude, [("5h", 50), ("7d", 60)]),
            glanceSnapshot(.codex, [("5h", 97)]),
        ]))
    #expect(result.level == .critical)
    #expect(result.percentText == "97%")
    #expect(result.spokenLabel == "Usage: Codex, 5-hour session 97%, critical")
}

@Test("usage glance: a level tie goes to the most used window, in both display modes")
func islandGlanceTieBreaksOnUsedShare() throws {
    let snapshots = [glanceSnapshot(.claude, [("5h", 40), ("7d", 60)])]
    let used = try #require(glance(snapshots))
    #expect(used.percentText == "60%")
    #expect(used.tone == .secondary)
    #expect(used.spokenLabel == "Usage: Claude, Weekly 60%")

    let remaining = try #require(glance(snapshots, mode: .remaining))
    #expect(remaining.percentText == "40%")
    #expect(remaining.fraction == 0.4)
    #expect(remaining.spokenLabel == "Usage: Claude remaining, Weekly 40%")
}

@Test("usage glance: equal windows keep the earlier one")
func islandGlanceEqualKeepsEarlier() throws {
    let result = try #require(
        glance([
            glanceSnapshot(.claude, [("5h", 30)]),
            glanceSnapshot(.codex, [("5h", 30)]),
        ]))
    #expect(result.spokenLabel == "Usage: Claude, 5-hour session 30%")
}

/// Regression: AppKit moves a window ordered below the menu-bar level out of
/// the menu-bar band. The macOS 27 overflow layering orders the resting
/// companion at level 23, which moved the island capsule from 6.5 pt below
/// the screen top to below the menu bar (y 45 on Mac17,13). The panel must
/// keep the frame the geometry gives it.
@MainActor
@Test func notchPanelKeepsAnInMenuBarFrameBelowTheMenuBarLevel() {
    let panel = NotchHUDPanel(contentRect: .zero)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
    let capsule = CGRect(x: 642, y: 953.5, width: 228, height: 33)
    #expect(panel.constrainFrameRect(capsule, to: NSScreen.main) == capsule)
}
