import Foundation

/// Pure frame geometry and stacking. Works on `Node` values so the rules do
/// not depend on any view or on the card-content enum.
nonisolated enum CanvasFrameLayout {
    struct Node: Equatable, Sendable {
        let id: CanvasCardID
        var rect: CanvasRect
        /// The members of a frame; nil for every other card.
        var frameMembers: [CanvasCardID]?

        init(id: CanvasCardID, rect: CanvasRect, frameMembers: [CanvasCardID]? = nil) {
            self.id = id
            self.rect = rect
            self.frameMembers = frameMembers
        }
    }

    /// Space between the members and the frame edge.
    static let padding = 32.0
    /// Extra space above the members for the frame title.
    static let titleBand = 36.0

    static func nodes(_ cards: [CanvasCard]) -> [Node] {
        cards.map {
            Node(id: $0.id, rect: $0.rect, frameMembers: $0.content.diagramFrame?.memberIDs)
        }
    }

    // MARK: Geometry

    /// A frame rect around `rects` with padding and a title band, clamped to
    /// the stored limits (at most 2,000 pt per side).
    static func enclosingRect(_ rects: [CanvasRect]) -> CanvasRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x)
            minY = min(minY, rect.y)
            maxX = max(maxX, rect.x + rect.width)
            maxY = max(maxY, rect.y + rect.height)
        }
        let x = minX - padding
        let y = minY - padding - titleBand
        let width = min(CanvasLayoutMath.maximumDimension, maxX - minX + 2 * padding)
        let height = min(CanvasLayoutMath.maximumDimension, maxY - minY + 2 * padding + titleBand)
        return CanvasRect(
            x: clampCoordinate(x.rounded()), y: clampCoordinate(y.rounded()),
            width: max(CanvasRect.absoluteMinimumWidth, width.rounded()),
            height: max(CanvasRect.absoluteMinimumHeight, height.rounded()))
    }

    static func clampCoordinate(_ value: Double) -> Double { min(50_000, max(-50_000, value)) }

    static func moved(_ rect: CanvasRect, dx: Double, dy: Double) -> CanvasRect {
        var result = rect
        result.x = clampCoordinate(rect.x + dx)
        result.y = clampCoordinate(rect.y + dy)
        return result
    }

    // MARK: Membership

    /// `ids` plus every member of every frame among them, transitively.
    /// Members that are not on the board are ignored; cycles end.
    static func closure(of ids: Set<CanvasCardID>, in nodes: [Node]) -> Set<CanvasCardID> {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = ids.filter { byID[$0] != nil }
        var queue = Array(result)
        while let next = queue.popLast() {
            for member in byID[next]?.frameMembers ?? [] where byID[member] != nil {
                if result.insert(member).inserted { queue.append(member) }
            }
        }
        return result
    }

    /// New rects for a frame and all its members moved by (dx, dy).
    static func frameMove(
        _ frameID: CanvasCardID, dx: Double, dy: Double, in nodes: [Node]
    ) -> [CanvasCardID: CanvasRect] {
        let moving = closure(of: [frameID], in: nodes)
        var result: [CanvasCardID: CanvasRect] = [:]
        for node in nodes where moving.contains(node.id) {
            result[node.id] = moved(node.rect, dx: dx, dy: dy)
        }
        return result
    }

    // MARK: Following

    /// What one frame observes: its rect and the rects of its members.
    struct FollowState: Equatable, Sendable {
        var frame: CanvasRect
        var memberIDs: [CanvasCardID]
        var memberRects: [CanvasRect]
    }

    static func followState(frameID: CanvasCardID, in nodes: [Node]) -> FollowState? {
        guard let frame = nodes.first(where: { $0.id == frameID }) else { return nil }
        let members = closure(of: [frameID], in: nodes).subtracting([frameID])
        let ordered = nodes.filter { members.contains($0.id) }
        return FollowState(
            frame: frame.rect, memberIDs: ordered.map(\.id), memberRects: ordered.map(\.rect))
    }

    /// The member moves that make members follow a frame that was moved on its
    /// own. A resize (size changed) moves nothing. A member that also changed
    /// in the same step (it moved with the frame, or an undo restored it)
    /// stays where it is, so nothing moves twice.
    static func followMoves(from old: FollowState, to new: FollowState) -> [CanvasCardID:
        CanvasRect]
    {
        guard old.frame.width == new.frame.width, old.frame.height == new.frame.height,
            old.memberIDs == new.memberIDs, old.memberRects.count == new.memberRects.count
        else { return [:] }
        let dx = new.frame.x - old.frame.x
        let dy = new.frame.y - old.frame.y
        guard dx != 0 || dy != 0 else { return [:] }
        var result: [CanvasCardID: CanvasRect] = [:]
        for (index, id) in new.memberIDs.enumerated()
        where old.memberRects[index] == new.memberRects[index] {
            result[id] = moved(new.memberRects[index], dx: dx, dy: dy)
        }
        return result
    }

    // MARK: Stacking

    /// The z-order (array order) with each frame just behind its earliest
    /// member. Frames already behind all their members keep their place, so
    /// a correct order is returned unchanged.
    static func stackedFramesBehindMembers(_ order: [Node]) -> [Node] {
        var result = order
        // Each pass moves at most one frame; nested frames need a few passes.
        for _ in 0...(order.count) {
            var changed = false
            for frameIndex in result.indices {
                guard let members = result[frameIndex].frameMembers, !members.isEmpty else {
                    continue
                }
                let memberSet = Set(members)
                guard
                    let firstMember = result.firstIndex(where: {
                        memberSet.contains($0.id) && $0.id != result[frameIndex].id
                    }), firstMember < frameIndex
                else { continue }
                let frame = result.remove(at: frameIndex)
                result.insert(frame, at: firstMember)
                changed = true
                break
            }
            if !changed { break }
        }
        return result
    }
}
