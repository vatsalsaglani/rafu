import Foundation

/// The geometry of the summary (25–50 %) and silhouette (< 25 %) faces.
///
/// Card content is drawn in board units and scaled by the viewport, so a
/// board value of `v / scale` is `v` screen points. Every value here is a
/// constant screen size converted to board units, which keeps the glyph, the
/// status dot and the status pill readable at every zoom on those faces.
nonisolated struct CanvasCompactFaceMetrics: Equatable, Sendable {
    /// Screen points.
    static let summaryGlyph = 20.0
    static let silhouetteGlyph = 24.0
    static let statusDot = 6.0
    static let pillFont = 11.0
    static let padding = 12.0
    /// A silhouette shows its title only when the card is at least this wide
    /// on screen; a narrower card shows the glyph alone, never a clipped title.
    static let minimumTitleWidth = 60.0

    /// Board units, so each equals its screen-point constant after scaling.
    let glyph: Double
    let dot: Double
    let pillFont: Double
    let padding: Double
    let titleFont: Double

    init(face: CanvasZoomFace, scale: Double) {
        let scale = Self.usableScale(scale)
        glyph = (face == .silhouette ? Self.silhouetteGlyph : Self.summaryGlyph) / scale
        dot = Self.statusDot / scale
        pillFont = Self.pillFont / scale
        padding = Self.padding / scale
        titleFont = CanvasZoomMetrics.titleFontSize(scale: scale)
    }

    /// Only a silhouette can hide its title.
    static func showsTitle(face: CanvasZoomFace, onScreenWidth: Double) -> Bool {
        face != .silhouette || onScreenWidth >= minimumTitleWidth
    }

    /// The glyph, never more than 60 % of the card's shorter side, so a
    /// silhouette far zoomed out is not cut by its own card edge.
    static func fittedGlyph(_ glyph: Double, cardWidth: Double, cardHeight: Double) -> Double {
        let limit = min(cardWidth, cardHeight) * 0.6
        guard limit > 0 else { return glyph }
        return min(glyph, limit)
    }

    private static func usableScale(_ scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 1 }
        return max(scale, CanvasZoomMetrics.minimumScale)
    }
}
