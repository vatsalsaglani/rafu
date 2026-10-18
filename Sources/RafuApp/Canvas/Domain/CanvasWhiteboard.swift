import Foundation

// Whiteboard card kinds (X5): shapes, strokes (freehand, line, arrow) and
// free text. Every value here is pure, `Codable` and bounded, so a saved board
// can never carry more than `CanvasLimits` allows. Colours are semantic style
// names, never hex values: the view maps each name to the active theme.

/// A point in a card's own unit space. (0, 0) is the card's top-left corner
/// and (1, 1) its bottom-right corner, so a stroke scales with its card.
///
/// The value is stored as two fixed-point integers (1/10 000 of the card) in a
/// two-element JSON array. That keeps a 512-point stroke small on disk, and
/// because `init` quantizes, a value survives an encode/decode round trip
/// unchanged.
nonisolated struct CanvasUnitPoint: Codable, Hashable, Sendable {
    static let resolution = 10_000.0

    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = Self.quantized(x)
        self.y = Self.quantized(y)
    }

    private static func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(1, max(0, value)) * resolution).rounded() / resolution
    }

    init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let qx = try values.decode(Int.self)
        let qy = try values.decode(Int.self)
        let range = 0...Int(Self.resolution)
        guard values.isAtEnd, range.contains(qx), range.contains(qy) else {
            throw CanvasError.invalidDocument
        }
        x = Double(qx) / Self.resolution
        y = Double(qy) / Self.resolution
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(Int((x * Self.resolution).rounded()))
        try values.encode(Int((y * Self.resolution).rounded()))
    }
}

/// Semantic stroke and text colours. The board maps each one to a theme token
/// (`primary` is the text colour). Gold is reserved for focus, selection and
/// live state, so it is deliberately not offered here.
nonisolated enum CanvasInk: String, Codable, CaseIterable, Sendable {
    case primary, secondary, info, success, warning, danger

    var title: String {
        switch self {
        case .primary: "Ink"
        case .secondary: "Muted"
        case .info: "Blue"
        case .success: "Green"
        case .warning: "Orange"
        case .danger: "Red"
        }
    }
}

/// How a shape's interior is painted, relative to its stroke ink.
nonisolated enum CanvasFill: String, Codable, CaseIterable, Sendable {
    case none, tint, solid

    var title: String {
        switch self {
        case .none: "No Fill"
        case .tint: "Tinted"
        case .solid: "Solid"
        }
    }
}

nonisolated enum CanvasLineWeight: String, Codable, CaseIterable, Sendable {
    case thin, regular, bold

    var title: String {
        switch self {
        case .thin: "Thin"
        case .regular: "Regular"
        case .bold: "Bold"
        }
    }

    /// Line width in board points (scaled with the viewport like every card).
    var points: Double {
        switch self {
        case .thin: 1.5
        case .regular: 2.5
        case .bold: 4
        }
    }
}

nonisolated enum CanvasShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, diamond

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .diamond: "Diamond"
        }
    }
}

/// A rectangle, ellipse or diamond that fills its card, with an optional label.
nonisolated struct CanvasShape: Codable, Equatable, Sendable {
    var kind: CanvasShapeKind
    var stroke: CanvasInk = .primary
    var fill: CanvasFill = .none
    var weight: CanvasLineWeight = .regular
    var dashed = false
    var label: String?

    init(
        kind: CanvasShapeKind, stroke: CanvasInk = .primary, fill: CanvasFill = .none,
        weight: CanvasLineWeight = .regular, dashed: Bool = false, label: String? = nil
    ) {
        self.kind = kind
        self.stroke = stroke
        self.fill = fill
        self.weight = weight
        self.dashed = dashed
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case kind, stroke, fill, weight, dashed, label }

    /// Only `kind` is required. A style name this version does not know falls
    /// back to the default, so a board from a newer Rafu still opens.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(CanvasShapeKind.self, forKey: .kind)
        stroke = CanvasStyleDecoding.value(values, .stroke, default: .primary)
        fill = CanvasStyleDecoding.value(values, .fill, default: .none)
        weight = CanvasStyleDecoding.value(values, .weight, default: .regular)
        dashed = (try? values.decodeIfPresent(Bool.self, forKey: .dashed)) ?? false
        label = try values.decodeIfPresent(String.self, forKey: .label)
    }

    func validate() throws {
        if let label {
            guard CanvasStyleDecoding.validText(label, limit: CanvasLimits.shapeLabelBytes) else {
                throw CanvasError.invalidDocument
            }
        }
    }
}

nonisolated enum CanvasStrokeKind: String, Codable, CaseIterable, Sendable {
    case freehand, line, arrow

    var title: String {
        switch self {
        case .freehand: "Drawing"
        case .line: "Line"
        case .arrow: "Arrow"
        }
    }
}

nonisolated enum CanvasArrowhead: String, Codable, CaseIterable, Sendable {
    case none, arrow
}

/// A freehand stroke, or a straight line/arrow from `start` to `end`.
///
/// Points are in the card's unit space (`CanvasUnitPoint`). A freehand stroke
/// keeps 2...`CanvasLimits.strokePoints` simplified points; a line or arrow
/// keeps exactly two. Arrowheads are drawn at either end.
nonisolated struct CanvasStroke: Codable, Equatable, Sendable {
    var kind: CanvasStrokeKind
    var points: [CanvasUnitPoint]
    var ink: CanvasInk = .primary
    var weight: CanvasLineWeight = .regular
    var dashed = false
    var startArrowhead: CanvasArrowhead = .none
    var endArrowhead: CanvasArrowhead = .none

    init(
        kind: CanvasStrokeKind, points: [CanvasUnitPoint], ink: CanvasInk = .primary,
        weight: CanvasLineWeight = .regular, dashed: Bool = false,
        startArrowhead: CanvasArrowhead = .none, endArrowhead: CanvasArrowhead? = nil
    ) {
        self.kind = kind
        self.points = points
        self.ink = ink
        self.weight = weight
        self.dashed = dashed
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead ?? (kind == .arrow ? .arrow : .none)
    }

    var start: CanvasUnitPoint? { points.first }
    var end: CanvasUnitPoint? { points.last }

    private enum CodingKeys: String, CodingKey {
        case kind, points, ink, weight, dashed, startArrowhead, endArrowhead
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(CanvasStrokeKind.self, forKey: .kind)
        var list = try values.nestedUnkeyedContainer(forKey: .points)
        guard (list.count ?? Int.max) <= CanvasLimits.strokePoints else {
            throw CanvasError.invalidDocument
        }
        var decoded: [CanvasUnitPoint] = []
        while !list.isAtEnd {
            guard decoded.count < CanvasLimits.strokePoints else {
                throw CanvasError.invalidDocument
            }
            decoded.append(try list.decode(CanvasUnitPoint.self))
        }
        points = decoded
        ink = CanvasStyleDecoding.value(values, .ink, default: .primary)
        weight = CanvasStyleDecoding.value(values, .weight, default: .regular)
        dashed = (try? values.decodeIfPresent(Bool.self, forKey: .dashed)) ?? false
        startArrowhead = CanvasStyleDecoding.value(values, .startArrowhead, default: .none)
        endArrowhead = CanvasStyleDecoding.value(
            values, .endArrowhead, default: kind == .arrow ? .arrow : .none)
    }

    func validate() throws {
        switch kind {
        case .freehand:
            guard (2...CanvasLimits.strokePoints).contains(points.count) else {
                throw CanvasError.invalidDocument
            }
        case .line, .arrow:
            guard points.count == 2 else { throw CanvasError.invalidDocument }
        }
    }
}

nonisolated enum CanvasTextSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large, heading

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .heading: "Heading"
        }
    }

    /// Font size in board points.
    var points: Double {
        switch self {
        case .small: 13
        case .medium: 16
        case .large: 22
        case .heading: 30
        }
    }
}

/// Free text on the board. The text is "Markdown-lite": inline emphasis,
/// code and links only, rendered with Foundation's inline Markdown parser.
nonisolated struct CanvasText: Codable, Equatable, Sendable {
    var text: String
    var size: CanvasTextSize = .medium
    var ink: CanvasInk = .primary

    init(text: String, size: CanvasTextSize = .medium, ink: CanvasInk = .primary) {
        self.text = text
        self.size = size
        self.ink = ink
    }

    private enum CodingKeys: String, CodingKey { case text, size, ink }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        size = CanvasStyleDecoding.value(values, .size, default: .medium)
        ink = CanvasStyleDecoding.value(values, .ink, default: .primary)
    }

    func validate() throws {
        guard CanvasStyleDecoding.validText(text, limit: CanvasLimits.whiteboardTextBytes) else {
            throw CanvasError.invalidDocument
        }
    }
}

/// Lenient decoding for style names and shared text bounds.
nonisolated enum CanvasStyleDecoding {
    static func value<Key: CodingKey, Value: RawRepresentable>(
        _ values: KeyedDecodingContainer<Key>, _ key: Key, default fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = try? values.decodeIfPresent(String.self, forKey: key) else {
            return fallback
        }
        return Value(rawValue: raw) ?? fallback
    }

    /// At most `limit` UTF-8 bytes and no NUL characters.
    static func validText(_ text: String, limit: Int) -> Bool {
        text.utf8.count <= limit && !text.utf8.contains(0)
    }

    /// The Mermaid source bound: non-empty after trimming, within the limit.
    static func validMermaidSource(_ source: String) -> Bool {
        validText(source, limit: CanvasLimits.mermaidSourceBytes)
            && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: Geometry

/// Pure geometry for creating whiteboard cards from a pointer gesture. Input
/// points are in board units; output rects always satisfy `CanvasRect.isValid`.
nonisolated enum CanvasWhiteboardGeometry {
    /// Raw pointer samples kept while a freehand gesture is in progress.
    static let maximumRawPoints = 8_192
    /// Default size of a shape made by a click rather than a drag.
    static let defaultShapeSize = (width: 160.0, height: 100.0)
    /// Default length of a line or arrow made by a click.
    static let defaultLineLength = 120.0
    /// Space between a stroke's bounds and its card edge, before line width.
    static let strokePadding = 12.0
    /// The largest card side (`CanvasRect.isValid`).
    static let maximumSide = 2_000.0

    /// Ramer–Douglas–Peucker simplification with `tolerance` in board points.
    /// Iterative, so a long stroke cannot exhaust the stack. The first and
    /// last points are always kept.
    static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            var worst = 0.0
            var index = first
            for candidate in (first + 1)..<last {
                let distance = Self.distance(
                    points[candidate], toSegment: points[first], points[last])
                if distance > worst {
                    worst = distance
                    index = candidate
                }
            }
            if worst > tolerance {
                keep[index] = true
                ranges.append((first, index))
                ranges.append((index, last))
            }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }

    /// Simplifies until at most `maximum` points remain: the tolerance doubles
    /// up to four times, then the remainder is decimated evenly (keeping both ends).
    static func bounded(_ points: [CGPoint], maximum: Int = CanvasLimits.strokePoints)
        -> [CGPoint]
    {
        let maximum = max(2, maximum)
        // RDP is quadratic in the worst case (a zigzag peels one point per
        // split), so very long input is first thinned evenly to 4x the limit.
        let input = decimated(points, to: maximum * 4)
        var tolerance = 0.75
        var result = simplify(input, tolerance: tolerance)
        var attempts = 0
        while result.count > maximum, attempts < 4 {
            tolerance *= 2
            result = simplify(input, tolerance: tolerance)
            attempts += 1
        }
        return decimated(result, to: maximum)
    }

    /// At most `maximum` evenly spaced points, keeping both ends.
    static func decimated(_ points: [CGPoint], to maximum: Int) -> [CGPoint] {
        let maximum = max(2, maximum)
        guard points.count > maximum else { return points }
        let step = Double(points.count - 1) / Double(maximum - 1)
        return (0..<maximum).map { points[Int((Double($0) * step).rounded())] }
    }

    /// A shape card's rect from a drag. A click (or a tiny drag) makes a
    /// default-sized shape centred on the start point. `square` forces equal
    /// sides (Shift). The rect is clamped to the stored card bounds.
    static func shapeRect(from start: CGPoint, to end: CGPoint, square: Bool) -> CanvasRect {
        let sx = Double(start.x)
        let sy = Double(start.y)
        var dx = Double(end.x) - sx
        var dy = Double(end.y) - sy
        if abs(dx) < 6 && abs(dy) < 6 {
            return clamped(
                x: sx - defaultShapeSize.width / 2, y: sy - defaultShapeSize.height / 2,
                width: defaultShapeSize.width, height: defaultShapeSize.height)
        }
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return clamped(x: min(sx, sx + dx), y: min(sy, sy + dy), width: abs(dx), height: abs(dy))
    }

    /// A stroke card from board-space samples, or nil when the samples do not
    /// make a visible stroke. Freehand samples are simplified and bounded; a
    /// line or arrow keeps only the first and last sample (a click makes a
    /// default-length horizontal line). A drawing larger than the biggest card
    /// is scaled down uniformly about its centre so it never distorts.
    static func strokeCard(
        kind: CanvasStrokeKind, samples: [CGPoint], style: CanvasStroke
    ) -> (rect: CanvasRect, stroke: CanvasStroke)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        var points: [CGPoint]
        switch kind {
        case .freehand:
            points = bounded(Array(samples.prefix(maximumRawPoints)))
            guard points.count >= 2 else { return nil }
        case .line, .arrow:
            if hypot(Double(last.x - first.x), Double(last.y - first.y)) < 6 {
                points = [
                    first, CGPoint(x: Double(first.x) + defaultLineLength, y: Double(first.y)),
                ]
            } else {
                points = [first, last]
            }
        }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for point in points {
            minX = min(minX, Double(point.x))
            minY = min(minY, Double(point.y))
            maxX = max(maxX, Double(point.x))
            maxY = max(maxY, Double(point.y))
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
        // A freehand "stroke" that never moved is not visible.
        if kind == .freehand && maxX - minX < 1 && maxY - minY < 1 { return nil }
        let padding = strokePadding + style.weight.points
        let usable = maximumSide - 2 * padding
        let spanX = maxX - minX
        let spanY = maxY - minY
        let fit = min(1, usable / max(spanX, 1), usable / max(spanY, 1))
        if fit < 1 {
            let cx = (minX + maxX) / 2
            let cy = (minY + maxY) / 2
            points = points.map { point in
                CGPoint(
                    x: cx + (Double(point.x) - cx) * fit, y: cy + (Double(point.y) - cy) * fit)
            }
            minX = cx - spanX * fit / 2
            maxX = cx + spanX * fit / 2
            minY = cy - spanY * fit / 2
            maxY = cy + spanY * fit / 2
        }
        let rect = clamped(
            x: minX - padding, y: minY - padding,
            width: maxX - minX + 2 * padding, height: maxY - minY + 2 * padding,
            centred: true)
        var stroke = style
        stroke.kind = kind
        stroke.points = points.map { point in
            CanvasUnitPoint(
                x: (Double(point.x) - rect.x) / rect.width,
                y: (Double(point.y) - rect.y) / rect.height)
        }
        if kind != .freehand, stroke.points.count == 2, stroke.points[0] == stroke.points[1] {
            return nil
        }
        return (rect, stroke)
    }

    /// A card rect that `CanvasRect.isValid` accepts. A side below the stored
    /// minimum grows (about its centre when `centred`), a side above the
    /// maximum shrinks, and the origin stays within the board bounds.
    static func clamped(
        x: Double, y: Double, width: Double, height: Double, centred: Bool = false
    ) -> CanvasRect {
        let w = min(maximumSide, max(CanvasRect.absoluteMinimumWidth, width.rounded()))
        let h = min(maximumSide, max(CanvasRect.absoluteMinimumHeight, height.rounded()))
        var ox = x
        var oy = y
        if centred {
            ox = x + (width - w) / 2
            oy = y + (height - h) / 2
        }
        return CanvasRect(
            x: min(50_000, max(-50_000, ox.rounded())), y: min(50_000, max(-50_000, oy.rounded())),
            width: w, height: h)
    }

    /// A text card's size for `text` at `size`: a fixed 280 pt column and a
    /// height from a line estimate. The face grows no further; the user can
    /// resize the card.
    static func textCardSize(for text: String, size: CanvasTextSize) -> (Double, Double) {
        let width = 280.0
        let charactersPerLine = max(8, Int(width / (size.points * 0.55)))
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (line.count + charactersPerLine - 1) / charactersPerLine)
        }
        let height = Double(max(1, min(lines, 60))) * size.points * 1.35 + 16
        return (width, min(maximumSide, max(CanvasRect.absoluteMinimumHeight, height)))
    }

    private static func distance(_ point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let px = Double(point.x)
        let py = Double(point.y)
        let ax = Double(a.x)
        let ay = Double(a.y)
        let dx = Double(b.x) - ax
        let dy = Double(b.y) - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(px - ax, py - ay) }
        let t = min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }
}
