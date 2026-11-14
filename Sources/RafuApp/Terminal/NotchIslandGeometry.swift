import CoreGraphics

/// Pure rect math for the companion on a Mac with a hole-punch camera and a
/// system Dynamic Island (`NotchCutout.islandCamera`). Public API only: the
/// system island belongs to MenuBarAgent and is drawn ABOVE every app
/// window, so Rafu cannot cover or join it. Rafu's black pill hangs just
/// BELOW the menu bar, centred under the island (ADR 0037, device check
/// 2026-11-15): a first "shared island" capsule beside the island in the
/// menu-bar band got no hover or tap (MenuBarAgent gives them to the system
/// island) and collided with menu titles, which flow right up to the island.
///
/// Reference values were measured from screenshots of Mac17,13 (1512×993 pt
/// screen, 40 pt top inset, 59 pt camera housing): the system capsule with
/// music playing spans x 688.7–819.5 (131–133 pt), 6.5–7 pt below the screen
/// top, 33 pt tall; on click it grows to a 285 pt card. Vertical values and
/// lobe widths scale with the top inset (`scale(for:)`), and every frame
/// snaps to the device pixel grid.
///
/// Every member returns `nil` unless the screen is `.islandCamera`, so a
/// notched or plain screen can never take this path by accident.
nonisolated enum NotchIslandGeometry {
    /// The top inset the reference values were measured against.
    static let referenceInset: CGFloat = 40
    /// Gap between the screen top and the SYSTEM island's top (6.5–7 pt).
    /// Used only for the system island's own zone (`systemZone(for:)`).
    static let capsuleTopGap: CGFloat = 6.5
    /// Height of the system activity capsule (33 pt) and of Rafu's pill.
    static let capsuleHeight: CGFloat = 33
    /// Gap between the menu bar's bottom edge and Rafu's pill. Rafu's pill
    /// hangs BELOW the menu bar (device check, Mac17,13, macOS 27.2): in the
    /// menu-bar band around the island, MenuBarAgent takes every hover and
    /// tap for the system island, and menu titles flow right up to it, so a
    /// Rafu capsule there could neither be used nor fit.
    static let pillGapBelowMenuBar: CGFloat = 4
    /// Half-width the system capsule needs beyond the camera housing's own
    /// half-width while it shows music (65.5 pt) or a hover (69.4 pt) —
    /// Rafu draws no content inside `housing/2 + systemReserve`.
    static let systemReserve: CGFloat = 40.5
    /// Half the resting pill's extra width beyond the camera housing:
    /// housing + 2 × 25 = 109 pt on Mac17,13 — room for the 20 pt mark and
    /// the 16 pt ring with the normal padding, and about the width of the
    /// gap the menu bar keeps around the island, so the pill reads as part
    /// of it.
    static let restingLobeWidth: CGFloat = 25
    /// Each lobe's width while the pointer rests on the capsule — wide
    /// enough for the percent text beside the ring.
    static let wideLobeWidth: CGFloat = 71
    /// The open card's corner radius.
    static let openCornerRadius: CGFloat = 28

    /// Scale from the reference inset, clamped so an odd inset can never
    /// produce an absurd capsule.
    static func scale(for metrics: NotchScreenMetrics) -> CGFloat {
        min(max(metrics.safeAreaTopInset / referenceInset, 0.75), 1.5)
    }

    /// The island camera housing, or `nil` on any other screen.
    private static func islandHousing(for metrics: NotchScreenMetrics) -> CGRect? {
        guard NotchHUDGeometry.cutout(for: metrics) == .islandCamera else { return nil }
        return NotchHUDGeometry.housingRect(for: metrics)
    }

    /// Distance from the island centre to the inner edge of each Rafu lobe.
    /// The system capsule owns everything inside it.
    static func systemReserveHalfWidth(for metrics: NotchScreenMetrics) -> CGFloat? {
        guard let housing = islandHousing(for: metrics) else { return nil }
        return housing.width / 2 + systemReserve * scale(for: metrics)
    }

    /// The capsule at rest: the camera housing plus a `restingLobeWidth`
    /// lobe each side, inside the menu bar's gap around the island.
    static func restingFrame(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let housing = islandHousing(for: metrics) else { return nil }
        return capsuleFrame(
            for: metrics, halfWidth: housing.width / 2 + restingLobeWidth * scale(for: metrics))
    }

    /// The capsule while the pointer rests on it: the system reserve plus a
    /// `wideLobeWidth` lobe each side. The panel is at `.statusBar` then, so
    /// it covers menu titles for as long as the hover lasts, like the
    /// system island's own hover and card.
    static func wideFrame(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let reserve = systemReserveHalfWidth(for: metrics) else { return nil }
        return capsuleFrame(
            for: metrics, halfWidth: reserve + wideLobeWidth * scale(for: metrics))
    }

    /// The open card: the panel width, the capsule's top edge, growing down
    /// to `contentHeight` (capped like the notch panel), clamped to the
    /// screen.
    static func openFrame(for metrics: NotchScreenMetrics, contentHeight: CGFloat) -> CGRect? {
        guard let housing = islandHousing(for: metrics) else { return nil }
        let pixel = metrics.backingScaleFactor
        let frame = metrics.frame
        let top = pillTopEdge(for: metrics)
        let width = min(NotchCompanionGeometry.panelWidth, frame.width)
        let height = NotchHUDGeometry.pixelAligned(
            min(contentHeight, NotchCompanionGeometry.maxPeekHeight(for: metrics)), scale: pixel)
        let x = NotchHUDGeometry.pixelAligned(
            min(max(housing.midX - width / 2, frame.minX), frame.maxX - width), scale: pixel)
        let y = min(max(top - height, frame.minY), frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The system island's own zone: the reserve width, from the capsule's
    /// bottom edge to the screen top. While Rafu's card is open, a click
    /// here belongs to the system island, so Rafu closes its card.
    static func systemZone(for metrics: NotchScreenMetrics) -> CGRect? {
        guard let housing = islandHousing(for: metrics),
            let reserve = systemReserveHalfWidth(for: metrics)
        else { return nil }
        let pixel = metrics.backingScaleFactor
        let minX = NotchHUDGeometry.pixelAligned(housing.midX - reserve, scale: pixel)
        let maxX = NotchHUDGeometry.pixelAligned(housing.midX + reserve, scale: pixel)
        let bottom = systemIslandTopEdge(for: metrics) - scaledCapsuleHeight(for: metrics)
        return CGRect(x: minX, y: bottom, width: maxX - minX, height: metrics.frame.maxY - bottom)
    }

    /// The open card's corner radius for this screen.
    static func openCornerRadius(for metrics: NotchScreenMetrics) -> CGFloat {
        NotchHUDGeometry.pixelAligned(
            openCornerRadius * scale(for: metrics), scale: metrics.backingScaleFactor)
    }

    // MARK: - Helpers

    /// The system island's top edge (6.5 pt below the screen top).
    private static func systemIslandTopEdge(for metrics: NotchScreenMetrics) -> CGFloat {
        NotchHUDGeometry.pixelAligned(
            metrics.frame.maxY - capsuleTopGap * scale(for: metrics),
            scale: metrics.backingScaleFactor)
    }

    /// Rafu's pill top edge: just below the menu bar (`visibleFrame.maxY`).
    private static func pillTopEdge(for metrics: NotchScreenMetrics) -> CGFloat {
        NotchHUDGeometry.pixelAligned(
            metrics.visibleFrame.maxY - pillGapBelowMenuBar * scale(for: metrics),
            scale: metrics.backingScaleFactor)
    }

    private static func scaledCapsuleHeight(for metrics: NotchScreenMetrics) -> CGFloat {
        NotchHUDGeometry.pixelAligned(
            capsuleHeight * scale(for: metrics), scale: metrics.backingScaleFactor)
    }

    private static func capsuleFrame(for metrics: NotchScreenMetrics, halfWidth: CGFloat)
        -> CGRect?
    {
        guard let housing = islandHousing(for: metrics) else { return nil }
        let pixel = metrics.backingScaleFactor
        let frame = metrics.frame
        let width = NotchHUDGeometry.pixelAligned(min(halfWidth * 2, frame.width), scale: pixel)
        let x = NotchHUDGeometry.pixelAligned(
            min(max(housing.midX - width / 2, frame.minX), frame.maxX - width), scale: pixel)
        let height = scaledCapsuleHeight(for: metrics)
        return CGRect(x: x, y: pillTopEdge(for: metrics) - height, width: width, height: height)
    }
}
