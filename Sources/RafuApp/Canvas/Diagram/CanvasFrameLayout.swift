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

    // MARK: Derived bounds

    /// The nodes after one board edit. This is the one rule for frame bounds:
    ///
    /// 1. Follow: a frame whose origin changed carries each of its members
    ///    (transitively) that did not change in the same edit, by the same
    ///    offset. So moving a frame on its own (keyboard, Align, an agent
    ///    `node_update`) moves its members.
    /// 2. Fit: each frame with at least one member on the board gets
    ///    `enclosingRect` of its members. Inner frames fit first. A frame with
    ///    no member on the board keeps its rect.
    /// 3. Stack: each frame goes just behind its earliest member.
    ///
    /// `previous` is the state before the edit; nil skips the follow step
    /// (a document that was just loaded).
    static func normalized(_ nodes: [Node], previous: [Node]?) -> [Node] {
        var result = nodes
        if let previous { result = followed(result, previous: previous) }
        return stackedFramesBehindMembers(fitted(result))
    }

    /// Step 1 of `normalized`: members follow a frame whose origin changed.
    /// A member that also changed in this edit (it moved with the frame, or
    /// it is new) stays where it is, so nothing moves twice.
    static func followed(_ nodes: [Node], previous: [Node]) -> [Node] {
        let old = Dictionary(
            previous.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let index = Dictionary(
            nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = nodes
        for frame in nodes where frame.frameMembers != nil {
            guard let before = old[frame.id], let position = index[frame.id] else { continue }
            let now = result[position].rect
            let dx = now.x - before.x
            let dy = now.y - before.y
            guard dx != 0 || dy != 0 else { continue }
            let members = closure(of: [frame.id], in: result).subtracting([frame.id])
            for id in members {
                guard let member = index[id], let was = old[id], result[member].rect == was
                else { continue }
                result[member].rect = moved(was, dx: dx, dy: dy)
            }
        }
        return result
    }

    /// Step 2 of `normalized`: every frame with a member on the board
    /// encloses its members. Nested frames resolve inner first; a membership
    /// cycle uses the stored rect of the frame that closes the cycle.
    static func fitted(_ nodes: [Node]) -> [Node] {
        let index = Dictionary(
            nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = nodes
        // false: being fitted (a cycle reached it); true: fitted.
        var state: [CanvasCardID: Bool] = [:]
        func fit(_ position: Int) {
            let id = result[position].id
            guard state[id] == nil else { return }
            state[id] = false
            if let members = result[position].frameMembers {
                var rects: [CanvasRect] = []
                for member in members where member != id {
                    guard let memberPosition = index[member] else { continue }
                    fit(memberPosition)
                    rects.append(result[memberPosition].rect)
                }
                if let rect = enclosingRect(rects) { result[position].rect = rect }
            }
            state[id] = true
        }
        for position in result.indices { fit(position) }
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
