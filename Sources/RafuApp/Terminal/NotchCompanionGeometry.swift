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

    /// The always-present resting strip: the notch band plus a `wingWidth`
    /// wing on each side, horizontally centered on the notch, pinned to the
    /// screen top with height equal to the notch band
    /// (`metrics.safeAreaTopInset`). `nil` when the screen has no notch
    /// (`NotchHUDGeometry.notchRect(for:)` is nil) — the resting strip does
    /// not exist without a notch to hug; a permanent floating bar under an
    /// external monitor's menu bar is clutter (terminal-notch-hud.md,
    /// "Resting": the Settings toggle defaults OFF on non-notch displays).
    static func restingStripFrame(for metrics: NotchScreenMetrics) -> CGRect? {
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

    /// Regions of the resting strip that must stay click-through so the
    /// strip never blocks a menu-bar click (terminal-notch-hud.md,
    /// "Resting": "click-through everywhere except the wings"). The strip
    /// is built EXACTLY as `leftWing ∪ notch ∪ rightWing` with no other
    /// gap — `restingStripFrame`'s x/width are derived from `notch` and
    /// `wingWidth` so the three rects always tile precisely — so the only
    /// non-wing region is the physical notch itself, sitting between the
    /// two wings. Hit-testing must return `nil` over every rect in this
    /// list. Empty when there is no notch (no strip exists to click
    /// through).
    static func clickThroughRegions(for metrics: NotchScreenMetrics) -> [CGRect] {
        guard let notch = NotchHUDGeometry.notchRect(for: metrics) else { return [] }
        return [notch]
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
        let height = min(contentHeight, metrics.frame.height)
        let x = min(max(centerX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        let y = min(max(topY - height, metrics.frame.minY), metrics.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
