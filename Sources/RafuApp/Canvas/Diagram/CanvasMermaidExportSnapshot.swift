import CoreGraphics
import Foundation

/// Export does not mount SwiftUI views, so their .task renderers never run.
/// Prepare static images before ImageRenderer takes its snapshot. All retained
/// diagram thumbnails together use at most four million RGBA pixels.
nonisolated struct CanvasMermaidExportSnapshot: Sendable {
    let image: CGImage?
    let failure: String?
    static let maximumPixels = 4_000_000

    @concurrent
    static func prepare(cards: [CanvasCard], theme: MermaidThemeSpec) async throws
        -> [CanvasCardID: Self]
    {
        let diagrams = cards.filter { if case .mermaid = $0.content { true } else { false } }
        let side = min(1_024, Int(sqrt(Double(maximumPixels / max(1, diagrams.count)))))
        var snapshots: [CanvasCardID: Self] = [:]
        for card in diagrams {
            try Task.checkCancellation()
            guard case .mermaid(let source) = card.content else { continue }
            guard case .diagram(let diagram) = MarkdownParser().parseMermaid(source) else {
                snapshots[card.id] = Self(image: nil, failure: "Diagram not supported or malformed")
                continue
            }
            do {
                let raster = try await MermaidRenderService.shared.raster(
                    for: diagram, theme: theme, scale: 2)
                try Task.checkCancellation()
                let factor = min(
                    1, Double(side) / Double(max(raster.image.width, raster.image.height)))
                let width = max(1, Int(Double(raster.image.width) * factor))
                let height = max(1, Int(Double(raster.image.height) * factor))
                guard let context = CanvasRaster.context(width: width, height: height) else {
                    throw MermaidRenderService.Failure.contextCreationFailed
                }
                context.draw(raster.image, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let image = context.makeImage() else {
                    throw MermaidRenderService.Failure.contextCreationFailed
                }
                snapshots[card.id] = Self(image: image, failure: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                snapshots[card.id] = Self(image: nil, failure: "Diagram could not be rendered")
            }
        }
        return snapshots
    }
}
