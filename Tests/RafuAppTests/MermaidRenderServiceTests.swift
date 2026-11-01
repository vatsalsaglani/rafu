import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

// No `import BeautifulMermaid` here (ADR 0020's two-file confinement rule):
// every assertion below goes through `MermaidRenderService`'s `Sendable`
// surface (`Raster`, `Failure`, `reason(for:)`) only.

// `RafuThemeCatalog` is MainActor-isolated, so these cannot be file-scope
// `let`s (a nonisolated global's default value may not touch MainActor state).
// Reading them on the MainActor per call is cheap and keeps the tests
// nonisolated, which is what lets them await the render actor directly.
@MainActor private func indigoSpec() -> MermaidThemeSpec {
    MermaidThemeSpec(theme: RafuThemeCatalog.indigo)
}

@MainActor private func khadiSpec() -> MermaidThemeSpec {
    MermaidThemeSpec(theme: RafuThemeCatalog.khadi)
}

/// A minimal, verified-parseable source for each of the six BeautifulMermaid
/// diagram types, trimmed from the fixtures a spike confirmed render
/// correctly (see `docs/references/mermaid-native-preview.md`).
private func fixture(for kind: MermaidDiagramKind) -> String {
    switch kind {
    case .flowchart:
        return "flowchart TD\n  A --> B\n  B --> C"
    case .stateDiagram:
        return "stateDiagram-v2\n  [*] --> A\n  A --> [*]"
    case .sequenceDiagram:
        return "sequenceDiagram\n  A->>B: hi"
    case .classDiagram:
        return "classDiagram\n  class Animal\n  class Dog\n  Animal <|-- Dog"
    case .erDiagram:
        return "erDiagram\n  RUN ||--o{ STEP : contains"
    case .xyChart:
        return "xychart-beta\n  title \"t\"\n  x-axis [a, b]\n  y-axis \"v\" 0 --> 10\n  bar [3, 7]"
    }
}

private func diagram(kind: MermaidDiagramKind, source: String) -> MermaidDiagram {
    MermaidDiagram(kind: kind, declaredType: kind.rawValue, raw: source, source: source)
}

/// A wide fan-out (`S --> N1`, `S --> N2`, …) so the perpendicular layout
/// axis grows roughly linearly with `nodeCount`, giving predictable control
/// over the diagram's point-space area for the cap tests below.
private func fanOutFlowchart(nodeCount: Int) -> String {
    var lines = ["flowchart LR"]
    for index in 1...nodeCount {
        lines.append("  S --> N\(index)")
    }
    return lines.joined(separator: "\n")
}

@Test(
    "Every BeautifulMermaid-backed diagram kind rasterises to a positive point size",
    arguments: [
        MermaidDiagramKind.flowchart, .stateDiagram, .sequenceDiagram, .classDiagram, .erDiagram,
        .xyChart,
    ])
func everySupportedKindRasterises(kind: MermaidDiagramKind) async throws {
    let source = fixture(for: kind)
    let raster = try await MermaidRenderService.shared.raster(
        for: diagram(kind: kind, source: source), theme: await indigoSpec(), scale: 2.0)
    #expect(raster.pointSize.width > 0)
    #expect(raster.pointSize.height > 0)
    #expect(!raster.accessibilityLabel.isEmpty)
}

@Test(
    "Diagram types outside the native six throw .notRenderable, never a partial raster",
    arguments: [
        "gantt\n  title x\n  dateFormat YYYY-MM-DD\n  section A\n  Task1 :a1, 2020-01-01, 3d",
        "pie\n  title x\n  \"A\" : 10\n  \"B\" : 20",
    ])
func unsupportedSourcesThrowNotRenderable(source: String) async {
    let target = diagram(kind: .flowchart, source: source)
    do {
        _ = try await MermaidRenderService.shared.raster(
            for: target, theme: await indigoSpec(), scale: 2.0)
        Issue.record("Expected raster(for:) to throw for source: \(source)")
    } catch let failure as MermaidRenderService.Failure {
        #expect(failure == .notRenderable)
    } catch {
        Issue.record("Expected a MermaidRenderService.Failure, got \(error)")
    }
}

@Test("Layout is theme-independent: the same source yields identical point sizes across themes")
func layoutIsThemeIndependent() async throws {
    let source = fixture(for: .flowchart)
    let target = diagram(kind: .flowchart, source: source)
    let indigoRaster = try await MermaidRenderService.shared.raster(
        for: target, theme: await indigoSpec(), scale: 1.0)
    let khadiRaster = try await MermaidRenderService.shared.raster(
        for: target, theme: await khadiSpec(), scale: 1.0)
    #expect(indigoRaster.pointSize == khadiRaster.pointSize)
}

@Test("An oversized diagram is refused before rasterisation")
func oversizedDiagramThrowsTooLarge() async {
    let source = fanOutFlowchart(nodeCount: 400)
    let target = diagram(kind: .flowchart, source: source)
    do {
        _ = try await MermaidRenderService.shared.raster(
            for: target, theme: await indigoSpec(), scale: 2.0)
        Issue.record("Expected .tooLarge for a 400-node fan-out")
    } catch let failure as MermaidRenderService.Failure {
        guard case .tooLarge(let size) = failure else {
            Issue.record("Expected .tooLarge, got \(failure)")
            return
        }
        #expect(size.width * size.height > MermaidRenderService.maxPointArea)
        let reason = MermaidRenderService.reason(for: failure)
        #expect(reason.contains("\(Int(size.width))×\(Int(size.height)) pt"))
        #expect(reason.contains("8000×8000 pt"))
        #expect(reason.contains("Split"))
    } catch {
        Issue.record("Expected a MermaidRenderService.Failure, got \(error)")
    }
}

@Test("A large-but-legal diagram backs its effective scale off, never below the minimum")
func largeLegalDiagramBacksScaleOff() async throws {
    let source = fanOutFlowchart(nodeCount: 60)
    let target = diagram(kind: .flowchart, source: source)
    let requestedScale: CGFloat = 2.0
    let raster = try await MermaidRenderService.shared.raster(
        for: target, theme: await indigoSpec(), scale: requestedScale)

    let pointArea = raster.pointSize.width * raster.pointSize.height
    #expect(pointArea <= MermaidRenderService.maxPointArea)
    if pointArea * requestedScale * requestedScale > MermaidRenderService.maxRasterPixels {
        #expect(raster.scale < requestedScale)
    } else {
        #expect(raster.scale == requestedScale)
    }
    #expect(raster.scale >= MermaidRenderService.minimumScale)
}

/// Regression: a 2534×1910 pt erDiagram (4.84 M pt², over the old 4 M pt²
/// cap) fell back to raw source. A diagram between the old and the new cap
/// now renders at a scale below 1.0 that keeps the raster inside the pixel cap.
@Test("A diagram past the old point-area cap renders below scale 1.0")
func diagramPastTheOldCapRendersScaledDown() async throws {
    let oldCap: CGFloat = 4_000_000
    // A 100-node fan-out lays out at about 6 M pt², between the old and new cap.
    let target = diagram(kind: .flowchart, source: fanOutFlowchart(nodeCount: 100))
    let rendered = try await MermaidRenderService.shared.raster(
        for: target, theme: await indigoSpec(), scale: 1.0)
    #expect(rendered.pointSize.width * rendered.pointSize.height > oldCap)
    let area = rendered.pointSize.width * rendered.pointSize.height
    #expect(area <= MermaidRenderService.maxPointArea)
    #expect(rendered.scale < 1.0)
    #expect(rendered.scale >= MermaidRenderService.minimumScale)
    #expect(area * rendered.scale * rendered.scale <= MermaidRenderService.maxRasterPixels * 1.01)
    #expect(rendered.image.width > 0)
}

@Test("The scale floor and the point-area ceiling agree on the raster pixel cap")
func pointAreaCeilingMatchesTheMinimumScale() {
    let floor = MermaidRenderService.minimumScale
    #expect(
        MermaidRenderService.maxPointArea * floor * floor == MermaidRenderService.maxRasterPixels)
}

@Test(
    "The failure-to-reason mapping never leaks upstream error text",
    arguments: [
        MermaidRenderService.Failure.notRenderable, .empty,
        .tooLarge(CGSize(width: 9000, height: 9000)), .contextCreationFailed,
    ])
func failureReasonNeverLeaksUpstreamText(failure: MermaidRenderService.Failure) {
    let reason = MermaidRenderService.reason(for: failure)
    #expect(!reason.isEmpty)
    let lowered = reason.lowercased()
    #expect(!lowered.contains("parsererror"))
    #expect(!lowered.contains("beautifulmermaid"))
    #expect(!lowered.contains("nserror"))
    #expect(!lowered.contains("couldn't be completed"))
}

/// The count of non-transparent (alpha != 0) pixels in each row of `image`,
/// top row first — used to locate rendered content without depending on
/// exact colors.
private func nonTransparentRowCounts(_ image: CGImage) -> [Int] {
    guard let data = image.dataProvider?.data else { return [] }
    let bytesPerRow = image.bytesPerRow
    let height = image.height
    let width = image.width
    let bytesPerPixel = max(1, image.bitsPerPixel / 8)
    var counts = [Int](repeating: 0, count: height)
    let length = CFDataGetLength(data)
    guard let base = CFDataGetBytePtr(data), length > 0 else { return counts }
    for row in 0..<height {
        var count = 0
        let rowStart = row * bytesPerRow
        for col in 0..<width {
            let alphaOffset = rowStart + col * bytesPerPixel + (bytesPerPixel - 1)
            guard alphaOffset < length else { continue }
            if base[alphaOffset] != 0 { count += 1 }
        }
        counts[row] = count
    }
    return counts
}

@Test(
    "The macOS flip fix (ADR 0020) places the widest-label node in the upper half of the raster"
)
func flipPlacesContentInUpperHalf() async throws {
    let source = """
        flowchart TD
          A[a very very very very very very very very long top label] --> B[x]
          B --> C[y]
        """
    let target = diagram(kind: .flowchart, source: source)
    let raster = try await MermaidRenderService.shared.raster(
        for: target, theme: await indigoSpec(), scale: 1.0)

    let counts = nonTransparentRowCounts(raster.image)
    guard let maxRow = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[maxRow] > 0
    else {
        Issue.record("Expected at least one non-transparent row in the raster")
        return
    }
    #expect(maxRow < raster.image.height / 2)
}
