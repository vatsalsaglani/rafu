import Foundation

/// What a note shows at a given Canvas zoom (review 7.8, "Notes at different
/// zoom levels"). Text below 9 screen points is unreadable, so lower zooms
/// swap to progressively smaller summaries instead of scaling prose down.
nonisolated enum CanvasNoteFace: Equatable, Sendable {
    /// 75% and above.
    case full
    /// 50% to 75%: full rendering, code blocks collapsed.
    case collapsedCode
    /// 25% to 50%: title, first paragraph, task count.
    case summary
    /// Below 25%: title only.
    case titleOnly
}

nonisolated enum CanvasNoteZoom {
    static let editMinimumScale = 0.5
    static let collapsedCodeLines = 3

    static func face(forScale scale: Double) -> CanvasNoteFace {
        if scale >= 0.75 { return .full }
        if scale >= 0.5 { return .collapsedCode }
        if scale >= 0.25 { return .summary }
        return .titleOnly
    }

    static func canEdit(atScale scale: Double) -> Bool { scale >= editMinimumScale }

    /// A font size in card points that is `screenPoints` tall on screen at
    /// `scale`, never smaller than `floor` card points.
    static func fontSize(screenPoints: Double, scale: Double, floor: Double) -> Double {
        max(floor, screenPoints / max(scale, 0.05))
    }

    /// A viewport that centres `rect` in `size`, as large as fits up to 100%
    /// and never below the editing minimum.
    static func viewport(centering rect: CanvasRect, in size: CGSize) -> CanvasViewport {
        let fit = min((size.width - 80) / rect.width, (size.height - 80) / rect.height)
        let scale = min(1, max(editMinimumScale, fit.isFinite ? fit : 1))
        return CanvasViewport(
            scale: scale,
            x: size.width / 2 - (rect.x + rect.width / 2) * scale,
            y: size.height / 2 - (rect.y + rect.height / 2) * scale)
    }
}
