import BeautifulMermaid
import CoreGraphics
import Foundation

// WHY THIS FILE EXISTS (do not delete as "redundant" with `MermaidDiagramView`):
//
// BeautifulMermaid 1.0.4's `MermaidImageRenderer.renderImage(from:)` is BROKEN
// on macOS: its AppKit branch builds a raw bottom-left-origin `CGContext` and
// never flips the CTM, so every raster comes out vertically mirrored (upside-
// down text, `TB` graphs running bottom-to-top). This actor renders through
// the lower-level `MermaidParser.parse` → `GraphLayout.layout` →
// `DiagramRenderer.render` path directly, owns the `CGContext` itself, and
// applies the flip (see `raster(for:theme:scale:)` below) — see ADR 0020 and
// `docs/references/mermaid-native-preview.md`.
//
// It ALSO hijacks the ambient `NSGraphicsContext`: `LabelRenderer` draws text
// through `NSGraphicsContext.current` (with *that* context's flippedness)
// whenever one is set, ignoring the `CGContext` it was handed. Rasterising
// only into our own offscreen bitmap context (where `current` is nil) avoids
// this entirely, and forbids ever drawing straight into a live view context.

/// Off-main actor owning every BeautifulMermaid value this feature touches.
/// Confined (with `MermaidTheme.swift`) to the two files ADR 0020 permits to
/// `import BeautifulMermaid` — no package type may appear in
/// `MarkdownModels.swift`, `MermaidDiagramView.swift`, or any test signature.
///
/// Concurrency invariants (mirrors `SyntaxParsingActor`'s documented
/// contract):
///   - `BeautifulMermaid.PreparedDiagram` is a `public struct` holding a
///     `(CGContext, CGRect) -> Void` closure and is **not** `Sendable` —
///     handing one across an actor boundary is a hard compile error under
///     `swiftLanguageModes: [.v6]` (`error: non-Sendable type
///     'PreparedDiagram?' ... cannot be sent to main actor-isolated
///     context`). This actor never constructs or stores one: it calls
///     `MermaidParser.parse` → `GraphLayout.layout` directly and caches only
///     the resulting `PositionedGraph`, which the package itself declares
///     `Sendable`. Rendering (`DiagramRenderer.render(_:in:bounds:)`) always
///     runs to completion inside this actor's isolation domain; only the
///     resulting `CGImage` (verified `Sendable`) and other value types ever
///     cross back to callers.
///   - Deliberate deviation from a naive "cache `MermaidImageRenderer(theme:)
///     .prepare(from:)`'s `PreparedDiagram`, keyed by source" design: reading
///     `DiagramRenderer.render(_:in:bounds:)`, the renderer instance (and the
///     `theme` baked into it) is captured by the closure `prepare(from:)`
///     returns — a cached `PreparedDiagram` would keep rendering with
///     whatever theme was active the first time that source was seen, not
///     the theme passed on a later cache hit. Caching the theme-independent
///     `PositionedGraph` instead and constructing a fresh `DiagramRenderer`
///     per call sidesteps that staleness bug while still only re-laying-out
///     (the expensive ELK pass) on a genuine source change.
///   - `DiagramTheme` is `@unchecked Sendable` upstream and must never be
///     shared across actors; callers pass a real-`Sendable`
///     `MermaidThemeSpec` and `RafuMermaidTheme.diagramTheme(_:)` builds the
///     actual `DiagramTheme` here, inside the actor, once per render call.
actor MermaidRenderService {
    static let shared = MermaidRenderService()

    /// A rasterised diagram ready to display. `CGImage` is `Sendable`, so
    /// this is the only value that ever crosses back to the caller.
    struct Raster: Sendable {
        let image: CGImage
        let pointSize: CGSize
        let scale: CGFloat
        let accessibilityLabel: String
    }

    enum Failure: Error, Sendable, Equatable {
        /// The dependency threw while parsing or laying out `diagram.source`.
        /// Upstream's error text is never surfaced (see `reason(for:)`); the
        /// caller shows a Rafu-authored notice instead.
        case notRenderable
        /// The diagram parsed to no renderable content (zero-sized layout).
        case empty
        /// The diagram's own point-space bounds exceed `maxPointArea`.
        case tooLarge(CGSize)
        /// The offscreen bitmap `CGContext` could not be created.
        case contextCreationFailed
    }

    private struct Entry {
        let positioned: PositionedGraph
        let label: String
    }

    /// Upper bound on rasterised pixels per diagram (~16 MB at 4 bytes/px).
    /// A proposal recorded in ADR 0020 pending a measured Release idle pass —
    /// not a verified budget. Exceeding it at the requested `scale` backs the
    /// effective scale off toward 1.0 rather than refusing to render.
    static let maxRasterPixels: CGFloat = 4_000_000
    /// Upper bound on a diagram's own point-space area (~2000×2000 pt) before
    /// Rafu refuses to render it at all. Same caveat as above.
    static let maxPointArea: CGFloat = 4_000_000
    /// LRU cap on retained `PositionedGraph`/label cache entries. Same caveat.
    static let maxCacheEntries = 24

    /// Keyed by `MermaidDiagram.source` alone — layout is verified
    /// theme-independent (identical geometry across both bundled themes for
    /// all spike fixtures), so a theme or appearance switch re-rasterises
    /// without repeating the ELK layout pass.
    private var cache: [String: Entry] = [:]
    private var lru: [String] = []

    private init() {}

    /// Renders `diagram` at `scale`, backing the effective scale off toward
    /// 1.0 if the full raster would exceed `maxRasterPixels`, and refusing
    /// entirely past `maxPointArea`. `diagram.source` is normalised
    /// (`normalizeMermaid(_:)` in `MarkdownModels.swift`) before this is
    /// ever called, so upstream's header-strictness quirks never reach here.
    func raster(
        for diagram: MermaidDiagram,
        theme spec: MermaidThemeSpec,
        scale: CGFloat
    ) throws -> Raster {
        let entry = try entry(for: diagram)
        guard entry.positioned.width > 0, entry.positioned.height > 0 else {
            throw Failure.empty
        }

        let width = CGFloat(entry.positioned.width)
        let height = CGFloat(entry.positioned.height)
        guard width * height <= Self.maxPointArea else {
            throw Failure.tooLarge(CGSize(width: width, height: height))
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let effectiveScale = clampedScale(for: bounds.size, requested: scale)
        let pixelWidth = Int((width * effectiveScale).rounded(.up))
        let pixelHeight = Int((height * effectiveScale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { throw Failure.contextCreationFailed }

        let renderer = DiagramRenderer(theme: RafuMermaidTheme.diagramTheme(spec))
        context.scaleBy(x: effectiveScale, y: effectiveScale)
        // The macOS flip fix (ADR 0020, see the file-header comment above):
        // BeautifulMermaid draws for a top-left-origin coordinate space, so
        // this bottom-left-origin `CGContext` must be flipped before
        // rendering into it.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        renderer.render(entry.positioned, in: context, bounds: bounds)

        guard let image = context.makeImage() else { throw Failure.contextCreationFailed }
        return Raster(
            image: image, pointSize: bounds.size, scale: effectiveScale,
            accessibilityLabel: entry.label)
    }

    /// Maps a caught `Failure` to a Rafu-authored, user-facing reason. Never
    /// touches `String(describing:)` or `localizedDescription` on the
    /// underlying BeautifulMermaid error: `_ParserEntryError` is `private`
    /// and not `LocalizedError`, so `String(describing:)` on it yields
    /// something like `invalidHeader("gantt")` and `localizedDescription`
    /// yields an unreadable generic NSError string — neither is fit for a
    /// user-visible string (ADR 0020, "Error text"). Kept as a small pure
    /// function so it is directly unit-testable without an actor round trip.
    nonisolated static func reason(for failure: Failure) -> String {
        switch failure {
        case .notRenderable:
            return "this diagram could not be parsed"
        case .empty:
            return "diagram parsed to no visible content"
        case .tooLarge(let size):
            return "too large to render natively (\(Int(size.width))×\(Int(size.height)) pt)"
        case .contextCreationFailed:
            return "could not allocate a rendering surface"
        }
    }

    // MARK: - Cache

    private func entry(for diagram: MermaidDiagram) throws -> Entry {
        if let cached = cache[diagram.source] {
            touch(diagram.source)
            return cached
        }

        let positioned: PositionedGraph
        do {
            positioned = try MermaidRenderer.layout(diagram.source)
        } catch {
            throw Failure.notRenderable
        }

        let newEntry = Entry(
            positioned: positioned, label: accessibilityLabel(for: positioned, kind: diagram.kind))
        store(diagram.source, entry: newEntry)
        return newEntry
    }

    private func store(_ key: String, entry: Entry) {
        cache[key] = entry
        lru.removeAll { $0 == key }
        lru.append(key)
        while lru.count > Self.maxCacheEntries {
            let evicted = lru.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    /// Backs `scale` off toward (but never below) 1.0 so the raster stays
    /// under `maxRasterPixels`; a diagram already under the cap at the
    /// requested scale is returned unchanged.
    private func clampedScale(for pointSize: CGSize, requested scale: CGFloat) -> CGFloat {
        guard pointSize.width > 0, pointSize.height > 0 else { return scale }
        let pixelsAtRequested = pointSize.width * pointSize.height * scale * scale
        guard pixelsAtRequested > Self.maxRasterPixels else { return scale }
        let maxScale = (Self.maxRasterPixels / (pointSize.width * pointSize.height)).squareRoot()
        return max(1.0, min(scale, maxScale))
    }

    /// Builds a Rafu-authored accessibility label from the parsed model —
    /// never from upstream error text. Reuses the `MermaidGraph` embedded in
    /// `PositionedGraph.diagram` rather than re-parsing, so layout and the
    /// a11y label always agree and `diagram.source` is parsed exactly once
    /// per cache miss. Preserves the phrasing style of the deleted
    /// `MermaidFlowCanvas`/`MermaidSequenceCanvas` accessibility labels.
    private func accessibilityLabel(for positioned: PositionedGraph, kind: MermaidDiagramKind)
        -> String
    {
        switch positioned.diagram.typedPayload {
        case .flowchart(let model), .stateDiagram(let model):
            let labels = model.nodesInOrder.map(\.node.label)
            return "Flow diagram, \(labels.count) nodes, \(model.edges.count) edges. "
                + "Nodes: \(labels.joined(separator: ", "))."
        case .sequenceDiagram(let sequence):
            return "Sequence diagram, \(sequence.actors.count) participants, "
                + "\(sequence.messages.count) messages."
        case .classDiagram(let model):
            return "Class diagram, \(model.classes.count) classes, "
                + "\(model.relationships.count) relationships."
        case .erDiagram(let model):
            return "Entity-relationship diagram, \(model.entities.count) entities, "
                + "\(model.relationships.count) relationships."
        case .xyChart(let chart):
            return "XY chart, \(chart.series.count) series."
        case nil:
            return "\(kind.rawValue) diagram."
        }
    }
}
