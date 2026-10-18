import Foundation

/// Pure board geometry for the Canvas redesign (review 7.2, 7.3, 14). Nothing
/// here touches UI or document state, so every rule is unit tested.

nonisolated enum CanvasAlignment: CaseIterable, Sendable {
    case left, centre, right, top, middle, bottom

    var title: String {
        switch self {
        case .left: "Align Left"
        case .centre: "Align Centre"
        case .right: "Align Right"
        case .top: "Align Top"
        case .middle: "Align Middle"
        case .bottom: "Align Bottom"
        }
    }

    var symbol: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centre: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .middle: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }
}

nonisolated enum CanvasDistribution: CaseIterable, Sendable {
    case horizontal, vertical

    var title: String {
        switch self {
        case .horizontal: "Distribute Horizontally"
        case .vertical: "Distribute Vertically"
        }
    }

    var symbol: String {
        switch self {
        case .horizontal: "distribute.horizontal.center"
        case .vertical: "distribute.vertical.center"
        }
    }
}

/// Which edges a resize gesture moves.
nonisolated struct CanvasResizeEdges: OptionSet, Sendable {
    let rawValue: Int
    static let left = CanvasResizeEdges(rawValue: 1)
    static let right = CanvasResizeEdges(rawValue: 2)
    static let top = CanvasResizeEdges(rawValue: 4)
    static let bottom = CanvasResizeEdges(rawValue: 8)

    static let all: [CanvasResizeEdges] = [
        .left, .right, .top, .bottom,
        [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom],
    ]
}

nonisolated struct CanvasResizeOutcome: Equatable, Sendable {
    var rect: CanvasRect
    /// True when the pointer asked for less than the minimum size.
    var reachedMinimum: Bool
}

nonisolated enum CanvasLayoutMath {
    static let maximumDimension = 2_000.0
    static let tidyGap = 16.0
    /// Resistance past the minimum: 30% of the excess, at most 12 pt.
    static let resistanceFactor = 0.3
    static let resistanceLimit = 12.0

    // MARK: Align and distribute

    /// Returns one rect per input rect, in input order.
    static func align(_ rects: [CanvasRect], _ alignment: CanvasAlignment) -> [CanvasRect] {
        guard rects.count > 1 else { return rects }
        let minX = rects.map(\.x).min() ?? 0
        let maxX = rects.map { $0.x + $0.width }.max() ?? 0
        let minY = rects.map(\.y).min() ?? 0
        let maxY = rects.map { $0.y + $0.height }.max() ?? 0
        return rects.map { rect in
            var next = rect
            switch alignment {
            case .left: next.x = minX
            case .right: next.x = maxX - rect.width
            case .centre: next.x = (minX + maxX) / 2 - rect.width / 2
            case .top: next.y = minY
            case .bottom: next.y = maxY - rect.height
            case .middle: next.y = (minY + maxY) / 2 - rect.height / 2
            }
            return next
        }
    }

    /// Equalises the gaps between three or more rects. The first and the last
    /// rect along the axis stay where they are. Returns rects in input order.
    static func distribute(_ rects: [CanvasRect], _ distribution: CanvasDistribution)
        -> [CanvasRect]
    {
        guard rects.count > 2 else { return rects }
        let horizontal = distribution == .horizontal
        func start(_ rect: CanvasRect) -> Double { horizontal ? rect.x : rect.y }
        func length(_ rect: CanvasRect) -> Double { horizontal ? rect.width : rect.height }
        let order = rects.indices.sorted { start(rects[$0]) < start(rects[$1]) }
        guard let first = order.first, let last = order.last else { return rects }
        let span = start(rects[last]) + length(rects[last]) - start(rects[first])
        let total = order.reduce(0) { $0 + length(rects[$1]) }
        let gap = (span - total) / Double(order.count - 1)
        var result = rects
        var cursor = start(rects[first]) + length(rects[first]) + gap
        for index in order.dropFirst().dropLast() {
            if horizontal {
                result[index].x = cursor
            } else {
                result[index].y = cursor
            }
            cursor += length(rects[index]) + gap
        }
        return result
    }

    /// Flows the rects in reading order into rows separated by `tidyGap`, so
    /// no two rects overlap. Returns rects in input order.
    static func tidy(_ rects: [CanvasRect], maximumRowWidth: Double = 1_800) -> [CanvasRect] {
        guard !rects.isEmpty else { return rects }
        let order = readingOrder(of: rects.enumerated().map { ($0.offset, $0.element) })
        let originX = rects.map(\.x).min() ?? 0
        let originY = rects.map(\.y).min() ?? 0
        var result = rects
        var x = originX
        var y = originY
        var rowHeight = 0.0
        for index in order {
            let rect = rects[index]
            if x > originX, x + rect.width > originX + maximumRowWidth {
                x = originX
                y += rowHeight + tidyGap
                rowHeight = 0
            }
            result[index].x = x
            result[index].y = y
            x += rect.width + tidyGap
            rowHeight = max(rowHeight, rect.height)
        }
        return result
    }

    // MARK: Reading order

    /// Top-left to bottom-right. Rects whose tops are within half of the
    /// shorter height of the first rect in a row share that row.
    static func readingOrder<ID: Hashable>(of items: [(ID, CanvasRect)]) -> [ID] {
        let sorted = items.sorted {
            if $0.1.y != $1.1.y { return $0.1.y < $1.1.y }
            return $0.1.x < $1.1.x
        }
        var rows: [[(ID, CanvasRect)]] = []
        var anchor: CanvasRect?
        for item in sorted {
            if let anchorRect = anchor,
                item.1.y - anchorRect.y < min(anchorRect.height, item.1.height) / 2
            {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
                anchor = item.1
            }
        }
        return rows.flatMap { row in row.sorted { $0.1.x < $1.1.x }.map(\.0) }
    }

    /// The card after (or before) `current` in reading order, wrapping around.
    /// With no current card, forward starts at the first and backward at the last.
    static func neighbour(
        of current: CanvasCardID?, in cards: [CanvasCard], forward: Bool
    ) -> CanvasCardID? {
        let order = readingOrder(of: cards.map { ($0.id, $0.rect) })
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return forward ? order.first : order.last
        }
        let next = forward ? index + 1 : index - 1
        return order[(next + order.count) % order.count]
    }

    // MARK: Z-order

    /// Moves the cards in `ids` to the end (front) or the start (back) of the
    /// array, keeping the relative order of both groups.
    static func reordered(_ cards: [CanvasCard], moving ids: Set<CanvasCardID>, toFront: Bool)
        -> [CanvasCard]
    {
        let moving = cards.filter { ids.contains($0.id) }
        let staying = cards.filter { !ids.contains($0.id) }
        return toFront ? staying + moving : moving + staying
    }

    // MARK: Resize

    /// Past the minimum the size resists: it follows 30% of the excess, to at
    /// most 12 pt below the minimum.
    static func resisted(_ proposed: Double, minimum: Double) -> Double {
        guard proposed < minimum else { return proposed }
        return minimum - min(resistanceLimit, (minimum - proposed) * resistanceFactor)
    }

    /// Resizes `start` by a pointer translation in board units. `aspect`
    /// (width divided by height) keeps the shape of image cards. With
    /// `allowsResistance` false (Reduce Motion) the size stops at the minimum.
    static func resize(
        _ start: CanvasRect, edges: CanvasResizeEdges, dx: Double, dy: Double,
        minimum: CGSize, aspect: Double? = nil, allowsResistance: Bool = true
    ) -> CanvasResizeOutcome {
        var rawWidth = start.width
        var rawHeight = start.height
        if edges.contains(.right) { rawWidth += dx }
        if edges.contains(.left) { rawWidth -= dx }
        if edges.contains(.bottom) { rawHeight += dy }
        if edges.contains(.top) { rawHeight -= dy }
        let changesWidth = edges.contains(.left) || edges.contains(.right)
        let changesHeight = edges.contains(.top) || edges.contains(.bottom)
        if let aspect, aspect > 0 {
            if changesWidth {
                rawHeight = rawWidth / aspect
            } else if changesHeight {
                rawWidth = rawHeight * aspect
            }
        }
        let reached = rawWidth < minimum.width || rawHeight < minimum.height
        func finish(_ raw: Double, minimum: Double) -> Double {
            let limited = allowsResistance ? resisted(raw, minimum: minimum) : max(raw, minimum)
            return min(maximumDimension, limited)
        }
        let width = finish(rawWidth, minimum: Double(minimum.width))
        let height = finish(rawHeight, minimum: Double(minimum.height))
        var rect = start
        rect.width = width
        rect.height = height
        if edges.contains(.left) { rect.x = start.x + start.width - width }
        if edges.contains(.top) { rect.y = start.y + start.height - height }
        return CanvasResizeOutcome(rect: rect, reachedMinimum: reached)
    }

    /// The nearest in-range size for a rect that was resisted below its minimum.
    static func clampedToMinimum(_ rect: CanvasRect, minimum: CGSize) -> CanvasRect {
        var next = rect
        let belowWidth = rect.width < minimum.width
        let belowHeight = rect.height < minimum.height
        guard belowWidth || belowHeight else { return rect }
        next.width = max(rect.width, Double(minimum.width))
        next.height = max(rect.height, Double(minimum.height))
        return next
    }
}

extension CanvasCardContent {
    /// Minimum card sizes from review 7.3.
    nonisolated var minimumSize: CGSize {
        switch self {
        case .note: CGSize(width: 200, height: 120)
        case .file: CGSize(width: 220, height: 140)
        case .image: CGSize(width: 120, height: 90)
        case .terminal: CGSize(width: 320, height: 180)
        case .web: CGSize(width: 320, height: 220)
        case .nativeApp: CGSize(width: 220, height: 160)
        }
    }

    /// Image cards keep their shape when they are resized.
    nonisolated var keepsAspect: Bool {
        if case .image = self { return true }
        return false
    }
}
