import CoreGraphics

/// Pure rect math for the notch companion's resting strip and peek panel
/// (terminal-notch-hud.md NC-A). Built entirely on the EXISTING
/// `NotchScreenMetrics` and `NotchHUDGeometry.notchRect(for:)` — this file
/// adds no new metrics type and never re-derives the notch rect itself.
nonisolated enum NotchCompanionGeometry {
    /// Each wing's width (terminal-notch-hud.md, "Resting": "~90pt each
    /// side").
    static let wingWidth: CGFloat = 90

    /// The peek panel's width before clamping to the screen frame.
    static let panelWidth: CGFloat = 420

    /// The peek panel never grows past this fraction of the screen height —
    /// beyond it, `NotchCompanionView`'s internal `ScrollView` takes over.
    /// Without the cap, dozens of editor windows/feed cards marched the
    /// panel off the bottom of the screen (observed at 29 windows).
    static let maxPeekHeightFraction: CGFloat = 0.6

    /// The tallest frame `peekPanelFrame` will produce for `metrics`.
    static func maxPeekHeight(for metrics: NotchScreenMetrics) -> CGFloat {
        (metrics.frame.height * maxPeekHeightFraction).rounded()
    }

    /// The resting strip's compact wing on each side of the SOFTWARE notch
    /// rect. Two constraints set the size (user photos, 2026-07-22): the
    /// physical cutout is WIDER than the AppKit aux-area gap, so anything
    /// inside ~16pt of the software notch edge hides behind the housing —
    /// and the resting strip must show the glyph (left) and editor count
    /// (right) at all times, which needs visible room beyond that dead
    /// zone. 44pt ≈ 16pt hidden + content + padding.
    static let restingWingWidth: CGFloat = 44

    /// The always-present resting strip: the notch plus a compact
    /// `restingWingWidth` wing each side — snug against the housing but
    /// with enough visible lip for the always-on glyph + editor count.
    /// Hover expands to `expandedStripFrame` for breathing room. `nil`
    /// when the screen has no notch (`NotchHUDGeometry.notchRect(for:)` is
    /// nil) — the resting strip does not exist without a notch to hug; a
    /// permanent floating bar under an external monitor's menu bar is
    /// clutter (terminal-notch-hud.md, "Resting": the Settings toggle
    /// defaults OFF on non-notch displays).
    static func restingStripFrame(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let notch = NotchHUDGeometry.notchRect(for: metrics) else { return nil }
        let width = notch.width + restingWingWidth * 2
        return CGRect(
            x: notch.midX - width / 2,
            y: metrics.frame.maxY - notch.height,
            width: width,
            height: notch.height
        )
    }

    /// The wings pill the strip animates out to once it needs to show
    /// content — attention while resting, or hover-dwell/click (coordinator
    /// decision): the notch band plus a `wingWidth` wing on each side,
    /// horizontally centered on the notch, pinned to the screen top with
    /// height equal to the notch band (`metrics.safeAreaTopInset`). This is
    /// the OLD `restingStripFrame` math, now named for what it actually is —
    /// the expanded (not resting) strip. `nil` when the screen has no notch,
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
    static func peekPanelFrame(for metrics: NotchScreenMetrics, contentHeight: CGFloat) -> CGRect {
        let centerX: CGFloat
        let topY: CGFloat
        if let notch = NotchHUDGeometry.notchRect(for: metrics) {
            centerX = notch.midX
            topY = notch.maxY
        } else {
            centerX = metrics.frame.midX
            topY = metrics.visibleFrame.maxY
        }
        let width = min(panelWidth, metrics.frame.width)
        let height = min(contentHeight, maxPeekHeight(for: metrics))
        let x = min(max(centerX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        let y = min(max(topY - height, metrics.frame.minY), metrics.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
