import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// The companion's shared chrome (`CompanionChrome.swift`): the gradient
/// border decision, the hanging outline, the tab tokens, and the agent card
/// text. Pure values, no windows.

private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

private func glow(
    visible: Bool = true, motionAllowed: Bool = true, reduceMotion: Bool = false,
    increaseContrast: Bool = false, reduceTransparency: Bool = false, anyWorking: Bool = false,
    sweepUntil: Date? = nil
) -> CompanionGlowState? {
    CompanionGlowPolicy.resolve(
        visible: visible, motionAllowed: motionAllowed, reduceMotion: reduceMotion,
        increaseContrast: increaseContrast, reduceTransparency: reduceTransparency,
        anyWorking: anyWorking, sweepUntil: sweepUntil, now: now)
}

// MARK: - Gradient border

@Test("CompanionGlowPolicy: no border while the surface is closed, whatever else is true")
func glowHiddenWhenClosed() {
    #expect(glow(visible: false) == nil)
    #expect(glow(visible: false, anyWorking: true, sweepUntil: now.addingTimeInterval(1)) == nil)
    #expect(glow(visible: false, increaseContrast: true) == nil)
}

@Test("CompanionGlowPolicy: open and idle is Cider's still 1 pt gradient")
func glowStillWhenIdle() {
    #expect(glow() == CompanionGlowState(fill: .gradient, motion: .still, lineWidth: 1))
    #expect(glow()?.period == nil)
}

@Test("CompanionGlowPolicy: the attention sweep lasts 2.4 s at 2 pt, then settles")
func glowAttentionSweepWindow() {
    #expect(CompanionGlowPolicy.attentionSweepDuration == 2.4)
    let sweeping = glow(sweepUntil: now.addingTimeInterval(0.5))
    #expect(sweeping == CompanionGlowState(fill: .gradient, motion: .attentionSweep, lineWidth: 2))
    #expect(sweeping?.period == CompanionGlowPolicy.attentionSweepPeriod)
    // The end of the window is exclusive: at and after it the border is
    // back to its resting state.
    #expect(glow(sweepUntil: now)?.motion == .still)
    #expect(glow(sweepUntil: now.addingTimeInterval(-1))?.lineWidth == 1)
    // The sweep wins over the slow working sweep while it lasts.
    #expect(
        glow(anyWorking: true, sweepUntil: now.addingTimeInterval(1))?.motion == .attentionSweep)
    #expect(glow(anyWorking: true, sweepUntil: now)?.motion == .workingSweep)
}

@Test("CompanionGlowPolicy: a slow sweep only while open and an agent works")
func glowWorkingSweep() {
    let working = glow(anyWorking: true)
    #expect(working == CompanionGlowState(fill: .gradient, motion: .workingSweep, lineWidth: 1))
    #expect(working?.period == CompanionGlowPolicy.workingSweepPeriod)
    #expect(CompanionGlowPolicy.workingSweepPeriod > CompanionGlowPolicy.attentionSweepPeriod)
    #expect(glow(visible: false, anyWorking: true) == nil)
}

@Test("CompanionGlowPolicy: Reduce Motion and a hidden window keep the border still")
func glowStillUnderReduceMotionOrHidden() {
    let sweep = now.addingTimeInterval(1)
    for state in [
        glow(reduceMotion: true, anyWorking: true, sweepUntil: sweep),
        glow(motionAllowed: false, anyWorking: true, sweepUntil: sweep),
    ] {
        #expect(state?.motion == .still)
        #expect(state?.period == nil)
        #expect(state?.fill == .gradient)
    }
    // The wider attention line still shows, without motion.
    #expect(glow(reduceMotion: true, sweepUntil: sweep)?.lineWidth == 2)
}

@Test("CompanionGlowPolicy: Increase Contrast is one solid still line")
func glowSolidUnderIncreaseContrast() {
    #expect(
        glow(increaseContrast: true, anyWorking: true)
            == CompanionGlowState(fill: .solid, motion: .still, lineWidth: 1))
    #expect(
        glow(increaseContrast: true, reduceTransparency: true)?.fill == .solid)
}

@Test("CompanionGlowPolicy: Reduce Transparency drops the faded stops but keeps motion rules")
func glowOpaqueUnderReduceTransparency() {
    #expect(glow(reduceTransparency: true)?.fill == .opaqueGradient)
    #expect(glow(reduceTransparency: true, anyWorking: true)?.motion == .workingSweep)
}

@Test("CompanionGlowPolicy: only a rising attention count starts a sweep")
func glowSweepTrigger() {
    #expect(CompanionGlowPolicy.startsSweep(oldAttention: 0, newAttention: 1))
    #expect(CompanionGlowPolicy.startsSweep(oldAttention: 2, newAttention: 3))
    #expect(!CompanionGlowPolicy.startsSweep(oldAttention: 1, newAttention: 1))
    #expect(!CompanionGlowPolicy.startsSweep(oldAttention: 3, newAttention: 0))
}

@Test("CompanionGlowPolicy.angle: still is 0; a sweep turns once per period")
func glowAngle() {
    let start = Date(timeIntervalSinceReferenceDate: 80)
    #expect(CompanionGlowPolicy.angle(at: start, period: nil) == 0)
    #expect(CompanionGlowPolicy.angle(at: start, period: 8) == 0)
    #expect(abs(CompanionGlowPolicy.angle(at: start.addingTimeInterval(2), period: 8) - 90) < 0.001)
    #expect(abs(CompanionGlowPolicy.angle(at: start.addingTimeInterval(8), period: 8)) < 0.001)
    #expect(CompanionGlowPolicy.frameInterval == 1.0 / 30)
}

// MARK: - Outline

@Test("CompanionOutlineLimits: Cider's clamps, shoulder h/3 and radius h/2")
func outlineMetricClamps() {
    #expect(CompanionOutlineLimits.open == CompanionOutlineLimits(shoulder: 12, radius: 22))
    #expect(CompanionOutlineLimits.closed.shoulder == 0)
    #expect(CompanionOutlineLimits.closed.radius == RafuMetrics.radiusPanel)
    #expect(
        CompanionOutlineLimits.open.metrics(height: 373)
            == CompanionOutlineMetrics(shoulder: 12, radius: 22))
    #expect(
        CompanionOutlineLimits.open.metrics(height: 30)
            == CompanionOutlineMetrics(shoulder: 10, radius: 15))
    #expect(
        CompanionOutlineLimits.closed.metrics(height: 33)
            == CompanionOutlineMetrics(shoulder: 0, radius: 12))
    #expect(
        CompanionOutlineLimits.open.metrics(height: -4)
            == CompanionOutlineMetrics(shoulder: 0, radius: 0))
}

@Test("CompanionOutline: the top edge spans the width; beside a shoulder is outside")
func outlineContainsShoulders() {
    let size = CGSize(width: 464, height: 373)
    let open = CompanionOutlineLimits.open
    // Just under the top edge, out in the shoulder flare, is inside.
    #expect(CompanionOutline.contains(CGPoint(x: 6, y: 0.5), size: size, limits: open))
    #expect(CompanionOutline.contains(CGPoint(x: 458, y: 0.5), size: size, limits: open))
    // Below the shoulder curve, at the outer edge, is outside.
    #expect(!CompanionOutline.contains(CGPoint(x: 2, y: 11), size: size, limits: open))
    #expect(!CompanionOutline.contains(CGPoint(x: 462, y: 11), size: size, limits: open))
    #expect(!CompanionOutline.contains(CGPoint(x: 6, y: 200), size: size, limits: open))
    // The body between the shoulders is inside.
    #expect(CompanionOutline.contains(CGPoint(x: 13, y: 200), size: size, limits: open))
    #expect(CompanionOutline.contains(CGPoint(x: 232, y: 372), size: size, limits: open))
    // The round bottom corners cut the corner square.
    #expect(!CompanionOutline.contains(CGPoint(x: 14, y: 372), size: size, limits: open))
    #expect(!CompanionOutline.contains(CGPoint(x: 450, y: 372), size: size, limits: open))
}

@Test("CompanionOutline: closed is a bottom-rounded rectangle with a full-width body")
func outlineClosedHasNoShoulders() {
    let size = CGSize(width: 273, height: 33)
    let closed = CompanionOutlineLimits.closed
    #expect(CompanionOutline.contains(CGPoint(x: 1, y: 11), size: size, limits: closed))
    #expect(CompanionOutline.contains(CGPoint(x: 272, y: 11), size: size, limits: closed))
    #expect(!CompanionOutline.contains(CGPoint(x: 0.5, y: 32.5), size: size, limits: closed))
}

@Test("CompanionOutline: the border path leaves out the top edge")
func outlineBorderIsOpenAtTop() {
    let rect = CGRect(x: 0, y: 0, width: 464, height: 373)
    let filled = CompanionOutline.cgPath(in: rect, limits: .open)
    let border = CompanionOutline.cgPath(in: rect, limits: .open, openTop: true)
    #expect(filled.boundingBoxOfPath == rect)
    // Same corners, so the same bounds; but the border path is not closed:
    // a point on the top edge's midpoint is on the filled shape's edge only.
    #expect(border.boundingBoxOfPath == rect)
    let topMid = CGPoint(x: 232, y: 0)
    let stroke = border.copy(
        strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    let filledStroke = filled.copy(
        strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    #expect(!stroke.contains(topMid))
    #expect(filledStroke.contains(topMid))
}

// MARK: - Panel widths

@Test("Open panel width: the content width plus a shoulder each side")
func openPanelWidthAddsShoulders() {
    #expect(NotchCompanionGeometry.openPanelWidth(height: 373) == 464)
    #expect(NotchCompanionGeometry.openPanelWidth(height: 30) == 460)
}

@MainActor
@Test("NotchHUDController.panelWidth: shoulders only under a notch")
func hudPanelWidth() {
    #expect(NotchHUDController.panelWidth(bandInset: 0) == NotchHUDController.layoutWidth)
    #expect(NotchHUDController.panelWidth(bandInset: 33) == NotchHUDController.layoutWidth + 24)
}

// MARK: - Tabs

@Test("CompanionChromeMetrics: Cider's pill picker values")
func tabMetricValues() {
    #expect(CompanionChromeMetrics.tabTrackPadding == 3)
    #expect(CompanionChromeMetrics.tabOptionSpacing == 2)
    #expect(CompanionChromeMetrics.tabOptionHeight(for: .notchPanel) == 28)
    #expect(CompanionChromeMetrics.tabOptionHeight(for: .menuBar) == 32)
    #expect(CompanionChromeMetrics.tabTrackOpacity == 0.065)
    #expect(CompanionChromeMetrics.tabSelectedOpacity == 0.14)
    #expect(CompanionChromeMetrics.tabAccessorySpacing == 12)
    #expect(CompanionChromeMetrics.contentHorizontalPadding == 16)
    #expect(CompanionChromeMetrics.sectionSpacing == 10)
    #expect(CompanionChromeMetrics.cardPadding == 10)
    #expect(CompanionChromeMetrics.cardCornerRadius == 14)
    #expect(CompanionChromeMetrics.usesEqualTabWidths(tabCount: 3))
    #expect(!CompanionChromeMetrics.usesEqualTabWidths(tabCount: 4))
}

@Test("CompanionTabBar uses the shared tab tokens, the pill track, and the option style")
func tabBarSourceContract() throws {
    let source = try SidebarPanelRedesignTests.source(
        "Sources/RafuApp/Views/NotchCompanionView.swift")
    let bar = try SidebarPanelRedesignTests.section(
        of: source, from: "struct CompanionTabBar: View", to: "private struct CompanionTabShortcut")
    #expect(bar.contains(".modifier(CompanionTabTrack())"))
    #expect(bar.contains(".buttonStyle(CompanionTabOptionStyle(selected: selected))"))
    #expect(bar.contains("CompanionChromeMetrics.tabOptionSpacing"))
    #expect(bar.contains("CompanionChromeMetrics.tabOptionHeight(for: host)"))
    #expect(bar.contains("CompanionChromeMetrics.tabAccessorySpacing"))
    #expect(bar.contains("CompanionChromeMetrics.usesEqualTabWidths"))
    // Selection is a trait and a weight, never colour alone.
    #expect(bar.contains(".isSelected"))
    #expect(bar.contains("weight: selected ? .semibold : .medium"))
    // The old ad-hoc capsule fill is gone.
    #expect(!bar.contains(".fill(selected ? theme.palette.selection : Color.clear)"))
}

@Test("Shared chrome reaches the notch, the drop-down, and the menu bar card")
func chromeIsSharedSourceContract() throws {
    let notch = try SidebarPanelRedesignTests.source(
        "Sources/RafuApp/Views/NotchCompanionView.swift")
    #expect(notch.contains("CompanionOutline(limits: outlineLimits"))
    #expect(notch.contains(".companionGlowBorder("))
    #expect(notch.contains(".rafuMotionScope()"))
    let hud = try SidebarPanelRedesignTests.source("Sources/RafuApp/Views/NotchHUDView.swift")
    #expect(hud.contains("CompanionOutline(limits: outlineLimits"))
    #expect(hud.contains(".companionGlowBorder("))
    // The HUD window belongs to no scene: it needs its own motion scope so
    // the sweep pauses while hidden.
    #expect(hud.contains(".rafuMotionScope()"))
    let menu = try SidebarPanelRedesignTests.source("Sources/RafuApp/Notch/UsageMenuBarItem.swift")
    #expect(menu.contains(".companionGlowBorder("))
    #expect(menu.contains("NSPopover()"))
    let chrome = try SidebarPanelRedesignTests.source("Sources/RafuApp/Views/CompanionChrome.swift")
    // The timeline is paused whenever the border is still.
    #expect(chrome.contains("paused: state.period == nil"))
}

// MARK: - Agent card

@Test("CompanionAgentCardContent.lastSeenText: just now, minutes, hours, days")
func agentCardLastSeen() {
    #expect(
        CompanionAgentCardContent.lastSeenText(updatedAt: now, now: now) == "Last seen just now")
    #expect(
        CompanionAgentCardContent.lastSeenText(updatedAt: now.addingTimeInterval(5), now: now)
            == "Last seen just now")
    #expect(
        CompanionAgentCardContent.lastSeenText(updatedAt: now.addingTimeInterval(-245), now: now)
            == "Last seen 4m ago")
    #expect(
        CompanionAgentCardContent.lastSeenText(updatedAt: now.addingTimeInterval(-7_300), now: now)
            == "Last seen 2h ago")
    #expect(
        CompanionAgentCardContent.lastSeenText(
            updatedAt: now.addingTimeInterval(-3 * 86_400), now: now) == "Last seen 3d ago")
}

@Test("CompanionAgentCardContent: a session suffix only when two cards read the same")
func agentCardSessionSuffix() {
    let a = NotchAgentRow(
        id: UUID(), title: "rafu", cli: .claudeCode, phase: .working, sessionSuffix: "1a2b3c4d")
    let b = NotchAgentRow(
        id: UUID(), title: "rafu", cli: .claudeCode, phase: .idle, sessionSuffix: "9f8e7d6c")
    let c = NotchAgentRow(
        id: UUID(), title: "rafu", cli: .codex, phase: .idle, sessionSuffix: "00000000")
    let noSuffix = NotchAgentRow(id: UUID(), title: "rafu", cli: .claudeCode, phase: .idle)
    #expect(CompanionAgentCardContent.showsSessionSuffix(a, among: [a, b]))
    #expect(!CompanionAgentCardContent.showsSessionSuffix(a, among: [a]))
    #expect(!CompanionAgentCardContent.showsSessionSuffix(a, among: [a, c]))
    #expect(!CompanionAgentCardContent.showsSessionSuffix(noSuffix, among: [noSuffix, a]))
}

@Test("AgentTrackedPhase card details: tilde folder and an 8-character session suffix")
func agentCardDetails() {
    let home = NSHomeDirectory()
    #expect(AgentTrackedPhase.cardDetail(cwd: "") == nil)
    #expect(AgentTrackedPhase.cardDetail(cwd: home + "/code/rafu") == "~/code/rafu")
    #expect(AgentTrackedPhase.cardDetail(cwd: "/tmp/x") == "/tmp/x")
    #expect(AgentTrackedPhase.sessionSuffix("") == nil)
    #expect(AgentTrackedPhase.sessionSuffix("abcdef0123456789") == "23456789")
    #expect(AgentTrackedPhase.sessionSuffix("abc") == "abc")
}
