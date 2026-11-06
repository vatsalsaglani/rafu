import CoreGraphics
import Foundation

/// A small vector outline of a board for the Open Ensemble rows (UX Round C,
/// P1): one rect per card, no content. Frames, shapes and strokes count,
/// because they are visible on the board. Pure, so it is unit-tested.
nonisolated struct CanvasBoardSilhouette: Equatable, Sendable, Codable {
    static let size = CGSize(width: 56, height: 36)
    static let inset = 3.0
    /// Larger boards draw their first `maxRects` cards only.
    static let maxRects = 64
    static let empty = CanvasBoardSilhouette(cards: [])

    /// Card rects relative to the cards' bounds: each axis runs 0…1.
    let unitRects: [CGRect]
    /// Width over height of the cards' bounds; 1 for an empty board.
    let aspect: Double

    init(cards: [CanvasRect]) {
        let rects = cards.prefix(Self.maxRects)
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            .filter { $0.minX.isFinite && $0.minY.isFinite && $0.width > 0 && $0.height > 0 }
        guard let first = rects.first else {
            unitRects = []
            aspect = 1
            return
        }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        unitRects = rects.map { rect in
            CGRect(
                x: (rect.minX - bounds.minX) / bounds.width,
                y: (rect.minY - bounds.minY) / bounds.height,
                width: rect.width / bounds.width,
                height: rect.height / bounds.height)
        }
        aspect = bounds.width / bounds.height
    }

    /// The rects in a `size` box with `inset` on each side: the bounds are
    /// fitted with their aspect kept, and centred.
    func rects(in size: CGSize = Self.size, inset: Double = Self.inset) -> [CGRect] {
        let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard !unitRects.isEmpty, box.width > 0, box.height > 0, aspect > 0 else { return [] }
        let fitted: CGSize =
            aspect > box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        let origin = CGPoint(
            x: box.minX + (box.width - fitted.width) / 2,
            y: box.minY + (box.height - fitted.height) / 2)
        return unitRects.map { unit in
            CGRect(
                x: origin.x + unit.minX * fitted.width,
                y: origin.y + unit.minY * fitted.height,
                width: unit.width * fitted.width,
                height: unit.height * fitted.height)
        }
    }
}
