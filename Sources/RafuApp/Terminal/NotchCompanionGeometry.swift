import CoreGraphics

/// Which shape the companion takes on its screen
/// (`NotchCompanionGeometry.surface(for:allowsPill:)`):
///
/// - `.notch`: the strip hugs a notch from the screen top.
/// - `.island`: one capsule behind the system Dynamic Island
///   (`NotchIslandGeometry`), Usage only.
/// - `.pill`: the opt-in floating pill under the menu bar on a plain screen.
nonisolated enum NotchCompanionSurface: Equatable, Sendable {
    case notch
    case island
    case pill
}

/// Pure rect math for the notch companion's resting strip and peek panel
/// (terminal-notch-hud.md NC-A). Built entirely on the EXISTING
/// `NotchScreenMetrics` and `NotchHUDGeometry.notchRect(for:)` — this file
/// adds no new metrics type and never re-derives the notch rect itself.
nonisolated enum NotchCompanionGeometry {
    /// Each wing's width (terminal-notch-hud.md, "Resting": "~90pt each
    /// side").
    static let wingWidth: CGFloat = 90

    /// The peek panel's width before clamping to the screen frame. Matches
    /// Cider's expanded notch (440pt).
    static let panelWidth: CGFloat = 440

    /// The open panel's height BELOW the notch band: the tab row plus a fixed
    /// content area that scrolls internally. Fixed, like Cider's expanded
    /// notch (350pt), so switching tabs or a list growing never resizes the
    /// window — the old content-measured height made the panel jump on every
    /// feed card and search keystroke. Still clamped by `maxPeekHeight`.
    static let openPanelBodyHeight: CGFloat = 340

    /// A floating pill on a Mac with no notch: wide enough for the mascot, a
    /// status line and the counts; as tall as the menu bar.
    static let pillWidth: CGFloat = 220
    static let pillMinimumHeight: CGFloat = 26

    /// The pill's width while the pointer rests on it.
    static let pillExpandedWidth: CGFloat = 260

    /// The peek panel never grows past this fraction of the screen height —
    /// beyond it, `NotchCompanionView`'s internal `ScrollView` takes over.
    /// Without the cap, dozens of editor windows/feed cards marched the
    /// panel off the bottom of the screen (observed at 29 windows).
    static let maxPeekHeightFraction: CGFloat = 0.6

    /// THE one place a screen's cutout picks the companion's surface. Every
    /// frame below dispatches on this, so sending an island screen down the
    /// plain-display pill path instead is a one-line change to the
    /// `.islandCamera` case. `nil` means no companion on this screen.
    static func surface(for metrics: NotchScreenMetrics, allowsPill: Bool)
        -> NotchCompanionSurface?
    {
        switch NotchHUDGeometry.cutout(for: metrics) {
        case .notch: .notch
        case .islandCamera: .island
        case .none: allowsPill ? .pill : nil
        }
    }

    /// The open notch or pill panel's window width for a panel `height`
    /// tall: `panelWidth` plus a shoulder on each side.
    static func openPanelWidth(height: CGFloat) -> CGFloat {
        panelWidth + 2 * CompanionOutlineLimits.open.metrics(height: height).shoulder
    }

    /// The tallest frame `peekPanelFrame` will produce for `metrics`.
    static func maxPeekHeight(for metrics: NotchScreenMetrics) -> CGFloat {
        (metrics.frame.height * maxPeekHeightFraction).rounded()
    }

    /// The resting strip's single wing, LEFT of the SOFTWARE notch rect.
    /// The physical cutout is WIDER than the AppKit aux-area gap (user
    /// photos, 2026-07-22), so the inner `housingHiddenInset` of the wing
    /// hides behind the housing; the visible rest shows the mascot and the
    /// status side by side. There is no right wing at rest: on macOS 27 the
    /// menu bar's "«" overflow chevron sits immediately right of the notch
    /// (user device photos, 2026-11-17), and a right wing covered it.
    static let restingLeadingWingWidth: CGFloat = 84

    /// The part of a wing next to the software notch edge that the wider
    /// physical housing hides.
    static let housingHiddenInset: CGFloat = 16

    /// The always-present resting strip: the notch plus one
    /// `restingLeadingWingWidth` wing on its left. The right edge is the
    /// notch's right edge. Hover expands to `expandedStripFrame` for
    /// breathing room. `nil` when the screen has no notch
    /// (`NotchHUDGeometry.notchRect(for:)` is nil) — the resting strip does
    /// not exist without a notch to hug; a permanent floating bar under an
    /// external monitor's menu bar is clutter (terminal-notch-hud.md,
    /// "Resting": the Settings toggle defaults OFF on non-notch displays).
    static func restingStripFrame(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = NotchHUDGeometry.notchRect(for: metrics) else { return nil }
        return CGRect(
            x: notch.minX - restingLeadingWingWidth,
            y: metrics.frame.maxY - notch.height,
            width: notch.width + restingLeadingWingWidth,
            height: notch.height
        )
    }

    /// The wings pill the strip animates out to once it needs to show
    /// content — hover-dwell or click (coordinator decision): the notch band
    /// plus a `wingWidth` wing on each side, horizontally centered on the
    /// notch, pinned to the screen top with height equal to the notch band
    /// (`metrics.safeAreaTopInset`). `nil` when the screen has no notch,
    /// mirroring `restingStripFrame`.
    static func expandedStripFrame(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = NotchHUDGeometry.notchRect(for: metrics) else { return nil }
        let width = notch.width + wingWidth * 2
        return CGRect(
            x: notch.midX - width / 2,
            y: metrics.frame.maxY - notch.height,
            width: width,
            height: notch.height
        )
    }

    /// The floating pill used on a display with no notch, when the person
    /// asked for it: top-centre, hanging from the bottom edge of the menu bar
    /// (`visibleFrame.maxY`) so it never covers menu bar items. `nil` on a
    /// screen with any camera cutout — the strip hugs a notch, and an island
    /// screen uses `NotchIslandGeometry`.
    static func pillFrame(for metrics: NotchScreenMetrics, expanded: Bool = false) -> CGRect? {
        guard NotchHUDGeometry.cutout(for: metrics) == .none else { return nil }
        return floatingPillFrame(for: metrics, expanded: expanded)
    }

    /// The pill's rect with no cutout check — reached only through
    /// `surface(for:allowsPill:)` returning `.pill`.
    private static func floatingPillFrame(for metrics: NotchScreenMetrics, expanded: Bool)
        -> CGRect
    {
        let menuBarHeight = metrics.frame.maxY - metrics.visibleFrame.maxY
        let height = max(pillMinimumHeight, menuBarHeight)
        let width = min(expanded ? pillExpandedWidth : pillWidth, metrics.frame.width)
        let topY = metrics.visibleFrame.maxY
        let x = min(
            max(metrics.frame.midX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        let y = min(max(topY - height, metrics.frame.minY), metrics.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The resting frame: the notch strip on a notched screen, the island
    /// capsule on an island screen, else the pill when `allowsPill`, else
    /// `nil` (no companion on this display).
    static func restingFrame(for metrics: NotchScreenMetrics, allowsPill: Bool) -> CGRect? {
        switch surface(for: metrics, allowsPill: allowsPill) {
        case .notch: restingStripFrame(for: metrics)
        case .island: NotchIslandGeometry.restingFrame(for: metrics)
        case .pill: floatingPillFrame(for: metrics, expanded: false)
        case nil: nil
        }
    }

    /// The wider "peek" frame shown while attention is active or the pointer
    /// rests on the strip with hover-to-open off (on an island: hover only).
    static func expandedFrame(for metrics: NotchScreenMetrics, allowsPill: Bool) -> CGRect? {
        switch surface(for: metrics, allowsPill: allowsPill) {
        case .notch: expandedStripFrame(for: metrics)
        case .island: NotchIslandGeometry.wideFrame(for: metrics)
        case .pill: floatingPillFrame(for: metrics, expanded: true)
        case nil: nil
        }
    }

    /// The left wing's hit-test rect in screen coordinates, flush against
    /// the notch's left edge. `nil` when there is no notch.
    static func leftWingRect(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = NotchHUDGeometry.notchRect(for: metrics) else { return nil }
        return CGRect(
            x: notch.minX - wingWidth, y: notch.minY, width: wingWidth, height: notch.height)
    }

    /// The right wing's hit-test rect, flush against the notch's right
    /// edge. `nil` when there is no notch.
    static func rightWingRect(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = NotchHUDGeometry.notchRect(for: metrics) else { return nil }
        return CGRect(x: notch.maxX, y: notch.minY, width: wingWidth, height: notch.height)
    }

    /// The peek panel's frame (terminal-notch-hud.md NC-A/NC-B, "Peek":
    /// "expands the strip downward"). Pinned at the SAME top edge the
    /// resting strip already occupies — the screen top with a notch
    /// (`notch.maxY`, which equals `metrics.frame.maxY`), or
    /// `visibleFrame.maxY` (just below the menu bar) without one — and
    /// growing DOWNWARD ONLY as `contentHeight` grows, mirroring
    /// `NotchHUDGeometry.hudFrame`'s top-pin/clamp discipline exactly (same
    /// non-notch fallback branch). Horizontally centered on the notch (or
    /// the screen without one) at `panelWidth`, clamped to `metrics.frame`
    /// on every edge.
    ///
    /// On an island screen the open card keeps the capsule's top edge
    /// instead (`NotchIslandGeometry.openFrame`), so it grows out of the
    /// capsule rather than from the screen top.
    ///
    /// The window is `panelWidth` plus both concave shoulders of the open
    /// outline (`CompanionOutline`, Cider's `NotchOutline`): the shoulders
    /// sit outside the content, so the content keeps `panelWidth`.
    static func peekPanelFrame(for metrics: NotchScreenMetrics, contentHeight: CGFloat) -> CGRect {
        if surface(for: metrics, allowsPill: false) == .island,
            let open = NotchIslandGeometry.openFrame(for: metrics, contentHeight: contentHeight)
        {
            return open
        }
        let centerX: CGFloat
        let topY: CGFloat
        if let notch = NotchHUDGeometry.notchRect(for: metrics) {
            centerX = notch.midX
            topY = notch.maxY
        } else {
            centerX = metrics.frame.midX
            topY = metrics.visibleFrame.maxY
        }
        let height = min(contentHeight, maxPeekHeight(for: metrics))
        let width = min(openPanelWidth(height: height), metrics.frame.width)
        let x = min(max(centerX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        let y = min(max(topY - height, metrics.frame.minY), metrics.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
