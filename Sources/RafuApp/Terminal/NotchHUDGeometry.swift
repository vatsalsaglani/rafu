import CoreGraphics

/// Everything the HUD layout needs from a screen, captured as plain values
/// so the math is testable without `NSScreen` (terminal-notch-hud.md N-1).
/// The ONLY place these are built from a real screen is the small
/// `@MainActor` adapter in `NotchHUDWindow.swift`; everything downstream of
/// this struct is pure.
nonisolated struct NotchScreenMetrics: Equatable, Sendable {
    /// Screen frame in global coordinates (bottom-left origin).
    let frame: CGRect
    /// `NSScreen.visibleFrame` — the frame minus the menu bar and Dock.
    /// Carried separately from `frame` because the NON-notch fallback must
    /// anchor "just below the menu bar", and the menu bar's bottom edge is
    /// only knowable as `visibleFrame.maxY` (a non-notch screen reports a
    /// zero safe-area inset, so the inset cannot stand in for it).
    let visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top` — 0 on non-notch displays.
    let safeAreaTopInset: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` — nil on non-notch displays.
    let auxiliaryTopLeft: CGRect?
    /// `NSScreen.auxiliaryTopRightArea` — nil on non-notch displays.
    let auxiliaryTopRight: CGRect?
}

/// The HUD's two presentations (terminal-notch-hud.md N-4): a compact pill
/// and an expanded card with the full bounded snippet and the reply field.
nonisolated enum NotchHUDState: Equatable, Sendable {
    case compact
    case expanded
}

/// Pure notch/HUD geometry. The platform exposes NO notch API — only
/// geometry: the notch rect is DERIVED from the two auxiliary top areas and
/// the top safe-area inset (verified on this machine: 1710×1107 screen,
/// inset 33, aux areas (0,1074,763,33) and (948,1074,762,33) → notch
/// (763,1074,185,33)).
nonisolated enum NotchHUDGeometry {
    /// The notch rect in screen coordinates, or `nil` when the screen has
    /// none (inset is 0, either auxiliary area is missing, or the derived
    /// width is non-positive).
    static func notchRect(for metrics: NotchScreenMetrics) -> CGRect? {
        guard metrics.safeAreaTopInset > 0,
            let left = metrics.auxiliaryTopLeft,
            let right = metrics.auxiliaryTopRight
        else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return CGRect(
            x: left.maxX,
            y: metrics.frame.maxY - metrics.safeAreaTopInset,
            width: width,
            height: metrics.safeAreaTopInset
        )
    }

    /// Where the HUD window goes. With a notch: hanging just below it
    /// (top edge flush with the notch's bottom), horizontally centered on
    /// it, at least as wide as the notch. Without one: top-center just
    /// below the menu bar (top edge at `visibleFrame.maxY`). The result is
    /// always fully within `frame` — clamped on every edge.
    ///
    /// Both states pin the same top edge and width, so an `.expanded`
    /// `contentSize` (taller, same width) grows the HUD DOWNWARD only, as
    /// the phase brief locks. `state` travels with the size so the call
    /// site states which presentation the size belongs to and per-state
    /// rules can be added without a signature change.
    static func hudFrame(
        for metrics: NotchScreenMetrics,
        contentSize: CGSize,
        state: NotchHUDState
    ) -> CGRect {
        _ = state
        let requestedWidth: CGFloat
        let centerX: CGFloat
        let topY: CGFloat
        if let notch = notchRect(for: metrics) {
            // SEAMLESS: the window's top edge sits at the SCREEN top (not
            // below the menu-bar band) so its black band region merges with
            // the physical notch housing — the whole reason this HUD exists
            // visually. The band height is added to the content height; the
            // view pads its content down by `bandInset(for:)` so nothing is
            // laid out beside the housing. (`.statusBar` window level is 25,
            // the menu bar is 24, so the band region genuinely covers it.)
            requestedWidth = max(contentSize.width, notch.width)
            centerX = notch.midX
            topY = notch.maxY
        } else {
            requestedWidth = contentSize.width
            centerX = metrics.frame.midX
            topY = metrics.visibleFrame.maxY
        }
        // "Always fully within frame" also covers degenerate oversized
        // content: clamp the size to the frame first, then the origin.
        let width = min(requestedWidth, metrics.frame.width)
        let bandHeight = notchRect(for: metrics) != nil ? metrics.safeAreaTopInset : 0
        let height = min(contentSize.height + bandHeight, metrics.frame.height)
        let x = min(max(centerX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        let y = min(max(topY - height, metrics.frame.minY), metrics.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension NotchHUDGeometry {
    /// Top padding the HUD content needs so it lays out BELOW the physical
    /// notch housing: the safe-area band height on a notched screen, 0 on
    /// the non-notch fallback (where the window already sits below the
    /// menu bar).
    static func bandInset(for metrics: NotchScreenMetrics) -> CGFloat {
        notchRect(for: metrics) != nil ? metrics.safeAreaTopInset : 0
    }
}
