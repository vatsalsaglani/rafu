import CoreGraphics
import Foundation

/// Geometry of the board overview (UX Round A, B3): a 140 × 90 pt vector
/// map drawn from card rects only. The mapped area is the union of every
/// card and the visible board, padded by 10 %, fitted into the overview with
/// its aspect kept and centred. Pure, so the view only draws.
nonisolated struct CanvasMinimapLayout: Equatable, Sendable {
    static let size = CGSize(width: 140, height: 90)
    static let inset = 6.0
    static let padding = 0.1

    /// Overview points per board unit.
    let scale: Double
    /// The overview point of board point (0, 0): overview = board × scale + origin.
    let origin: CGPoint
    /// The visible board, in board units.
    let visibleBoardRect: CGRect

    init(cards: [CanvasRect], viewport: CanvasViewport, visible: CGSize) {
        let boardScale = viewport.scale > 0 ? viewport.scale : 1
        let visibleRect = CGRect(
            x: -viewport.x / boardScale, y: -viewport.y / boardScale,
            width: Double(visible.width) / boardScale,
            height: Double(visible.height) / boardScale)
        visibleBoardRect = visibleRect
        var bounds = cards.reduce(visibleRect) { $0.union($1.cgRect) }
        bounds = bounds.insetBy(
            dx: -bounds.width * Self.padding / 2, dy: -bounds.height * Self.padding / 2)
        let available = CGSize(
            width: Self.size.width - 2 * Self.inset, height: Self.size.height - 2 * Self.inset)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else {
            scale = 1
            origin = CGPoint(x: Self.inset, y: Self.inset)
            return
        }
        let fit = min(
            Double(available.width) / Double(bounds.width),
            Double(available.height) / Double(bounds.height))
        scale = fit
        origin = CGPoint(
            x: Self.inset + (Double(available.width) - Double(bounds.width) * fit) / 2
                - Double(bounds.minX) * fit,
            y: Self.inset + (Double(available.height) - Double(bounds.height) * fit) / 2
                - Double(bounds.minY) * fit)
    }

    /// `board` (board units) in overview points.
    func rect(_ board: CanvasRect) -> CGRect {
        rect(board.cgRect)
    }

    func rect(_ board: CGRect) -> CGRect {
        CGRect(
            x: Double(board.minX) * scale + origin.x, y: Double(board.minY) * scale + origin.y,
            width: Double(board.width) * scale, height: Double(board.height) * scale)
    }

    /// The visible board, in overview points.
    var viewportRect: CGRect { rect(visibleBoardRect) }

    /// The board point under an overview point.
    func boardPoint(at overviewPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (Double(overviewPoint.x) - origin.x) / scale,
            y: (Double(overviewPoint.y) - origin.y) / scale)
    }

    /// The viewport that centres the visible board on `boardPoint` at the
    /// same `scale`, kept inside the stored viewport range.
    static func viewport(centering boardPoint: CGPoint, scale: Double, visible: CGSize)
        -> CanvasViewport
    {
        let x = Double(visible.width) / 2 - Double(boardPoint.x) * scale
        let y = Double(visible.height) / 2 - Double(boardPoint.y) * scale
        return CanvasViewport(
            scale: scale, x: min(100_000, max(-100_000, x)), y: min(100_000, max(-100_000, y)))
    }
}
