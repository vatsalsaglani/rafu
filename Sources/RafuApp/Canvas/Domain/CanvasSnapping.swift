import Foundation

/// One alignment guide: a 1 pt line at a board coordinate, spanning the moving
/// card and the card it aligns with (review 7.2, 14).
nonisolated struct CanvasSnapGuide: Equatable, Hashable, Sendable {
    enum Axis: Sendable { case vertical, horizontal }
    enum Kind: Sendable { case edge, centre, gap }

    /// `.vertical` is a line at constant x; `.horizontal` at constant y.
    var axis: Axis
    var position: Double
    var start: Double
    var end: Double
    var kind: Kind

    var key: String {
        "\(axis == .vertical ? "v" : "h"):\((position * 2).rounded() / 2)"
    }

    /// True when any guide in `current` was not showing before. A haptic plays
    /// once for each such entry.
    static func hasNewEntry(previous: Set<String>, current: [CanvasSnapGuide]) -> Bool {
        current.contains { !previous.contains($0.key) }
    }
}

nonisolated struct CanvasSnapResult: Equatable, Sendable {
    /// Offset to add to the proposed frame, in board units.
    var dx = 0.0
    var dy = 0.0
    /// At most two: one vertical and one horizontal.
    var guides: [CanvasSnapGuide] = []
    var snappedX: Bool { guides.contains { $0.axis == .vertical } }
    var snappedY: Bool { guides.contains { $0.axis == .horizontal } }
}

/// Snaps a moving frame to the edges and centres of other cards, and to a
/// 16 pt gap beside them.
nonisolated enum CanvasSnapper {
    static let gap = 16.0
    static let thresholdPoints = 6.0

    private struct Candidate {
        var delta: Double
        var position: Double
        var start: Double
        var end: Double
        var kind: CanvasSnapGuide.Kind
    }

    /// `scale` is the board zoom, so the threshold stays 6 screen points.
    static func snap(
        moving: CGRect, others: [CGRect], scale: Double,
        threshold: Double = thresholdPoints
    ) -> CanvasSnapResult {
        guard scale.isFinite, scale > 0, !others.isEmpty else { return CanvasSnapResult() }
        let limit = threshold / scale
        var result = CanvasSnapResult()
        if let best = bestCandidate(
            axisVertical: true, moving: moving, others: others, limit: limit)
        {
            result.dx = best.delta
            result.guides.append(
                CanvasSnapGuide(
                    axis: .vertical, position: best.position, start: best.start, end: best.end,
                    kind: best.kind))
        }
        let shifted = moving.offsetBy(dx: result.dx, dy: 0)
        if let best = bestCandidate(
            axisVertical: false, moving: shifted, others: others, limit: limit)
        {
            result.dy = best.delta
            result.guides.append(
                CanvasSnapGuide(
                    axis: .horizontal, position: best.position, start: best.start, end: best.end,
                    kind: best.kind))
        }
        return result
    }

    private static func bestCandidate(
        axisVertical: Bool, moving: CGRect, others: [CGRect], limit: Double
    ) -> Candidate? {
        // Work on the snapping axis (a) and the other axis (b).
        func lo(_ r: CGRect) -> Double { Double(axisVertical ? r.minX : r.minY) }
        func hi(_ r: CGRect) -> Double { Double(axisVertical ? r.maxX : r.maxY) }
        func mid(_ r: CGRect) -> Double { (lo(r) + hi(r)) / 2 }
        func crossLo(_ r: CGRect) -> Double { Double(axisVertical ? r.minY : r.minX) }
        func crossHi(_ r: CGRect) -> Double { Double(axisVertical ? r.maxY : r.maxX) }

        var best: Candidate?
        func consider(
            _ delta: Double, position: Double, other: CGRect, kind: CanvasSnapGuide.Kind
        ) {
            guard abs(delta) <= limit else { return }
            if let current = best, abs(current.delta) <= abs(delta) { return }
            // The guide spans both cards on the other axis.
            let shiftedLo = crossLo(moving)
            let shiftedHi = crossHi(moving)
            best = Candidate(
                delta: delta, position: position,
                start: min(shiftedLo, crossLo(other)), end: max(shiftedHi, crossHi(other)),
                kind: kind)
        }

        for other in others {
            let movingFeatures: [(Double, CanvasSnapGuide.Kind)] = [
                (lo(moving), .edge), (mid(moving), .centre), (hi(moving), .edge),
            ]
            let targetFeatures: [(Double, CanvasSnapGuide.Kind)] = [
                (lo(other), .edge), (mid(other), .centre), (hi(other), .edge),
            ]
            for (movingValue, movingKind) in movingFeatures {
                for (targetValue, targetKind) in targetFeatures
                where movingKind == targetKind {
                    consider(
                        targetValue - movingValue, position: targetValue, other: other,
                        kind: movingKind)
                }
            }
            // The 16 pt gap applies only to cards that share the other axis.
            let overlapsCross =
                crossLo(moving) <= crossHi(other) + gap && crossHi(moving) >= crossLo(other) - gap
            if overlapsCross {
                // Moving card to the right of (or below) the other card.
                consider(
                    hi(other) + gap - lo(moving), position: hi(other) + gap, other: other,
                    kind: .gap)
                // Moving card to the left of (or above) the other card.
                consider(
                    lo(other) - gap - hi(moving), position: lo(other) - gap, other: other,
                    kind: .gap)
            }
        }
        return best
    }
}
