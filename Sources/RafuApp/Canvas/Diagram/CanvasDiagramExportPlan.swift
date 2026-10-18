import CoreGraphics
import Foundation

/// What to export.
nonisolated enum CanvasDiagramExportTarget: Equatable, Hashable, Sendable {
    case board
    case frame(CanvasCardID)
    case selection
}

/// How to export it.
nonisolated enum CanvasDiagramExportFormat: Equatable, Hashable, Sendable {
    case png(scale: Double)
    case pdf
    case gif(seconds: Double, fps: Int)

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .pdf: "pdf"
        case .gif: "gif"
        }
    }
}

/// Pure export geometry: which cards, which bounds, how many pixels.
nonisolated enum CanvasDiagramExportPlan {
    static let padding = 40.0
    /// 4,096 pixels per side keeps one RGBA frame at 64 MB or less.
    static let maximumPNGPixels = 4_096.0
    static let maximumGIFWidth = 1_600.0
    static let maximumGIFHeight = 1_600.0

    /// The cards a target includes: everything, one frame and its members, or
    /// the selection plus the members of selected frames.
    static func cardIDs(
        for target: CanvasDiagramExportTarget, nodes: [CanvasFrameLayout.Node],
        selection: Set<CanvasCardID>
    ) -> Set<CanvasCardID> {
        switch target {
        case .board:
            return Set(nodes.map(\.id))
        case .frame(let id):
            guard nodes.contains(where: { $0.id == id && $0.frameMembers != nil }) else {
                return []
            }
            return CanvasFrameLayout.closure(of: [id], in: nodes)
        case .selection:
            return CanvasFrameLayout.closure(of: selection, in: nodes)
        }
    }

    /// The union of `rects` grown by `padding`; nil when empty.
    static func bounds(of rects: [CanvasRect], padding: Double = Self.padding) -> CGRect? {
        guard let first = rects.first else { return nil }
        var union = first.cgRect
        for rect in rects.dropFirst() { union = union.union(rect.cgRect) }
        return union.insetBy(dx: -padding, dy: -padding).integral
    }

    /// The pixel scale for `bounds`: the requested scale, reduced so neither
    /// side exceeds the cap, including very large boards.
    static func pixelScale(
        for bounds: CGRect, requested: Double, maximumWidth: Double, maximumHeight: Double
    ) -> Double {
        let width = max(1, Double(bounds.width))
        let height = max(1, Double(bounds.height))
        let wanted = min(3, max(0.25, requested.isFinite ? requested : 1))
        return min(wanted, maximumWidth / width, maximumHeight / height)
    }

    static func pngScale(for bounds: CGRect, requested: Double) -> Double {
        pixelScale(
            for: bounds, requested: requested, maximumWidth: maximumPNGPixels,
            maximumHeight: maximumPNGPixels)
    }

    static func gifScale(for bounds: CGRect) -> Double {
        pixelScale(
            for: bounds, requested: 2, maximumWidth: maximumGIFWidth,
            maximumHeight: maximumGIFHeight)
    }

    /// "Board Name frame 2026-10-18 101500.png", without characters that
    /// are unsafe in file names.
    static func fileName(
        boardTitle: String, targetName: String, format: CanvasDiagramExportFormat, date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(
            String.UnicodeScalarView(
                "\(boardTitle) \(targetName)".unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }
            )
        )
        .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let base = cleaned.isEmpty ? "Ensemble" : String(cleaned.prefix(80))
        return "\(base) \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// True when `candidate` (after resolving symlinks) is `root` or inside it.
    static func isInside(_ candidate: URL, root: URL) -> Bool {
        guard root.isFileURL, candidate.isFileURL else { return false }
        let rootPath = resolvedForCreation(root).path
        let path = resolvedForCreation(candidate).path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path == rootPath || path.hasPrefix(prefix)
    }

    /// Foundation can preserve /private for a missing leaf but remove it for
    /// an existing parent. Resolve the existing ancestor first, then append
    /// missing components so both paths use the same macOS spelling.
    private static func resolvedForCreation(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while ancestor.path != "/",
            (try? FileManager.default.attributesOfItem(atPath: ancestor.path)) == nil
        {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved
    }
}

// MARK: GIF planning

/// Frame count and delay for an animated GIF, within the caps.
nonisolated struct CanvasGIFPlan: Equatable, Sendable {
    static let maximumFrames = 120

    let frameCount: Int
    /// Seconds per frame.
    let delay: Double

    init(seconds: Double, fps: Int) {
        let duration = min(10, max(1, seconds.isFinite ? seconds : 3))
        let rate = min(30, max(5, fps))
        let frames = min(Self.maximumFrames, max(2, Int((duration * Double(rate)).rounded())))
        frameCount = frames
        // GIF delays are stored in hundredths of a second.
        delay = max(0.02, ((duration / Double(frames)) * 100).rounded() / 100)
    }

    /// Loop progress of `frame`, in [0, 1).
    func progress(ofFrame frame: Int) -> Double {
        Double(((frame % frameCount) + frameCount) % frameCount) / Double(frameCount)
    }
}

/// A polyline measured by arc length, so a dot moves at an even speed along
/// a curve whose parameter does not.
nonisolated struct CanvasFlowPath: Equatable, Sendable {
    let points: [CGPoint]
    let cumulative: [Double]

    init(points: [CGPoint]) {
        self.points = points
        var lengths: [Double] = [0]
        for index in points.indices.dropFirst() {
            let a = points[index - 1]
            let b = points[index]
            lengths.append(lengths[index - 1] + Double(hypot(b.x - a.x, b.y - a.y)))
        }
        cumulative = lengths
    }

    init(curve: CanvasEdgeCurve, segments: Int = 48) {
        self.init(points: curve.sampled(segments: segments))
    }

    var length: Double { cumulative.last ?? 0 }

    /// The point `fraction` of the way along the path by length.
    func point(atFraction fraction: Double) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1, length > 0 else { return first }
        let target = min(1, max(0, fraction)) * length
        var low = 0
        var high = cumulative.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if cumulative[middle] < target { low = middle } else { high = middle }
        }
        let span = cumulative[high] - cumulative[low]
        let t = span > 0 ? (target - cumulative[low]) / span : 0
        let a = points[low]
        let b = points[high]
        let x = Double(a.x) + (Double(b.x) - Double(a.x)) * t
        let y = Double(a.y) + (Double(b.y) - Double(a.y)) * t
        return CGPoint(x: x, y: y)
    }
}

nonisolated enum CanvasGIFFlow {
    struct Edge: Equatable, Sendable {
        let id: UUID
        let path: CanvasFlowPath
        /// Message links carry traffic both ways.
        let bidirectional: Bool
    }

    struct Dot: Equatable, Sendable {
        let edgeID: UUID
        let point: CGPoint
        let forward: Bool
    }

    /// The dots of one GIF frame. A relationship carries one dot from its
    /// source to its target per loop, eased in and out; a message link also
    /// carries one back, half a loop later.
    static func dots(for edges: [Edge], progress: Double) -> [Dot] {
        var result: [Dot] = []
        for edge in edges where edge.path.length > 0 {
            let forward = CanvasEdgeGeometry.easeInOut(progress)
            result.append(
                Dot(edgeID: edge.id, point: edge.path.point(atFraction: forward), forward: true))
            if edge.bidirectional {
                let shifted = (progress + 0.5).truncatingRemainder(dividingBy: 1)
                let back = 1 - CanvasEdgeGeometry.easeInOut(shifted)
                result.append(
                    Dot(edgeID: edge.id, point: edge.path.point(atFraction: back), forward: false))
            }
        }
        return result
    }
}
