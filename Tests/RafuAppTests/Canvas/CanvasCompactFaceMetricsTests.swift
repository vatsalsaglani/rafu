import Testing

@testable import RafuApp

@Suite("Canvas compact face metrics")
struct CanvasCompactFaceMetricsTests {
    private func close(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.0001
    }

    @Test("Summary sizes are constant screen points at 40 %")
    func summaryAtFortyPercent() {
        let metrics = CanvasCompactFaceMetrics(face: .summary, scale: 0.4)
        #expect(close(metrics.glyph, 50))
        #expect(close(metrics.glyph * 0.4, CanvasCompactFaceMetrics.summaryGlyph))
        #expect(close(metrics.dot, 15))
        #expect(close(metrics.pillFont * 0.4, 11))
        #expect(close(metrics.padding * 0.4, 12))
        #expect(metrics.titleFont == CanvasZoomMetrics.titleFontSize(scale: 0.4))
    }

    @Test("The silhouette glyph is 24 screen points at 20 %")
    func silhouetteAtTwentyPercent() {
        let metrics = CanvasCompactFaceMetrics(face: .silhouette, scale: 0.2)
        #expect(close(metrics.glyph, 120))
        #expect(close(metrics.dot, 30))
    }

    @Test("A silhouette hides its title on a card under 60 screen points wide")
    func silhouetteTitle() {
        #expect(!CanvasCompactFaceMetrics.showsTitle(face: .silhouette, onScreenWidth: 50))
        #expect(CanvasCompactFaceMetrics.showsTitle(face: .silhouette, onScreenWidth: 60))
        #expect(CanvasCompactFaceMetrics.showsTitle(face: .summary, onScreenWidth: 10))
    }

    @Test("A broken scale falls back instead of dividing by zero")
    func brokenScale() {
        let metrics = CanvasCompactFaceMetrics(face: .summary, scale: 0)
        #expect(metrics.glyph.isFinite)
        #expect(close(metrics.glyph, CanvasCompactFaceMetrics.summaryGlyph))
    }

    @Test("The silhouette glyph fits inside a small card")
    func fittedGlyph() {
        #expect(CanvasCompactFaceMetrics.fittedGlyph(240, cardWidth: 380, cardHeight: 260) == 156)
        #expect(CanvasCompactFaceMetrics.fittedGlyph(120, cardWidth: 380, cardHeight: 260) == 120)
        #expect(CanvasCompactFaceMetrics.fittedGlyph(120, cardWidth: 0, cardHeight: 0) == 120)
    }
}
