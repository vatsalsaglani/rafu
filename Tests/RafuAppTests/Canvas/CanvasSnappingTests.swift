import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas snapping and semantic zoom")
struct CanvasSnappingTests {
    private let other = CGRect(x: 500, y: 100, width: 200, height: 100)

    @Test("A frame within 6 screen points snaps to an edge and draws one guide")
    func edgeSnap() {
        let moving = CGRect(x: 503, y: 400, width: 120, height: 80)
        let result = CanvasSnapper.snap(moving: moving, others: [other], scale: 1)
        #expect(result.dx == -3)
        #expect(result.snappedX)
        let guide = result.guides.first { $0.axis == .vertical }
        #expect(guide?.position == 500)
        #expect(guide?.kind == .edge)
        // The guide spans both cards.
        #expect(guide?.start == 100 && guide?.end == 480)
    }

    @Test("The threshold is measured in screen points, so zoom changes the board distance")
    func thresholdScales() {
        let moving = CGRect(x: 510, y: 900, width: 100, height: 50)
        #expect(CanvasSnapper.snap(moving: moving, others: [other], scale: 1).guides.isEmpty)
        // At 25% zoom, 6 screen points are 24 board units.
        let zoomedOut = CanvasSnapper.snap(moving: moving, others: [other], scale: 0.25)
        #expect(zoomedOut.dx == -10)
        #expect(CanvasSnapper.snap(moving: moving, others: [other], scale: 4).guides.isEmpty)
    }

    @Test("Centres align and a 16 pt gap is kept beside a card")
    func centreAndGap() {
        // Centre x of other is 600; a 100 wide frame at 548 has centre 598.
        let centred = CanvasSnapper.snap(
            moving: CGRect(x: 548, y: 700, width: 100, height: 50), others: [other], scale: 1)
        #expect(centred.dx == 2)
        #expect(centred.guides.first?.kind == .centre)
        // Right of other (maxX 700) plus 16 gap is 716.
        let gap = CanvasSnapper.snap(
            moving: CGRect(x: 713, y: 110, width: 100, height: 50), others: [other], scale: 1)
        #expect(gap.dx == 3)
        #expect(gap.guides.first { $0.axis == .vertical }?.kind == .gap)
        // A card far away on the other axis does not attract a gap snap.
        let far = CanvasSnapper.snap(
            moving: CGRect(x: 713, y: 900, width: 100, height: 50), others: [other], scale: 1)
        #expect(far.guides.isEmpty)
    }

    @Test("Snapping returns at most two guides and none without other cards")
    func guideLimit() {
        let result = CanvasSnapper.snap(
            moving: CGRect(x: 502, y: 103, width: 200, height: 100),
            others: [other, CGRect(x: 498, y: 98, width: 200, height: 100)], scale: 1)
        #expect(result.guides.count == 2)
        #expect(CanvasSnapper.snap(moving: other, others: [], scale: 1).guides.isEmpty)
        #expect(CanvasSnapper.snap(moving: other, others: [other], scale: 0).guides.isEmpty)
    }

    @Test("A haptic plays only when a guide is newly entered")
    func guideEntry() {
        let guide = CanvasSnapGuide(axis: .vertical, position: 500, start: 0, end: 10, kind: .edge)
        #expect(CanvasSnapGuide.hasNewEntry(previous: [], current: [guide]))
        #expect(!CanvasSnapGuide.hasNewEntry(previous: [guide.key], current: [guide]))
        #expect(!CanvasSnapGuide.hasNewEntry(previous: [guide.key], current: []))
    }

    @Test("Zoom faces switch at 75%, 50% and 25%")
    func zoomFaces() {
        #expect(CanvasZoomFace(scale: 4) == .full)
        #expect(CanvasZoomFace(scale: 0.75) == .full)
        #expect(CanvasZoomFace(scale: 0.74) == .scaledLive)
        #expect(CanvasZoomFace(scale: 0.5) == .scaledLive)
        #expect(CanvasZoomFace(scale: 0.49) == .summary)
        #expect(CanvasZoomFace(scale: 0.25) == .summary)
        #expect(CanvasZoomFace(scale: 0.24) == .silhouette)
        #expect(CanvasZoomFace(scale: 0.1) == .silhouette)
        #expect(CanvasZoomFace.scaledLive.showsLiveContent)
        #expect(!CanvasZoomFace.summary.showsLiveContent)
    }

    @Test("Titles stay at least 11 screen points at every zoom")
    func titleSize() {
        for scale in [0.1, 0.25, 0.5, 0.75, 1, 2, 4] {
            let screen = CanvasZoomMetrics.titleFontSize(scale: scale) * scale
            #expect(screen >= 11 - 0.0001)
        }
        #expect(CanvasZoomMetrics.titleFontSize(scale: 1) == 13)
        #expect(CanvasZoomMetrics.clamped(0.01) == 0.1)
        #expect(CanvasZoomMetrics.clamped(9) == 4)
    }

    @Test("The 100% detent holds within 3% and reports each crossing once")
    func detent() {
        #expect(CanvasZoomDetent.apply(1.02) == 1)
        #expect(CanvasZoomDetent.apply(0.98) == 1)
        #expect(CanvasZoomDetent.apply(1.05) == 1.05)
        #expect(CanvasZoomDetent.crossed(from: 0.9, to: 1.0))
        #expect(CanvasZoomDetent.crossed(from: 0.9, to: 1.1))
        #expect(CanvasZoomDetent.crossed(from: 1.1, to: 0.9))
        #expect(!CanvasZoomDetent.crossed(from: 1.0, to: 1.01))
        #expect(!CanvasZoomDetent.crossed(from: 0.5, to: 0.6))
    }

    @Test("Summary text helpers count tasks and bound excerpts")
    func summaryText() {
        let note = "# Plan\n- [x] one\n- [ ] two\n  * [X] three\nplain"
        #expect(CanvasCardSummaryText.taskCount(in: note) == "2/3")
        #expect(CanvasCardSummaryText.taskCount(in: "no tasks") == nil)
        #expect(CanvasCardSummaryText.firstLine(of: "\n\n## Heading\nbody") == "Heading")
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let excerpt = CanvasCardSummaryText.excerpt(of: lines)
        #expect(excerpt.split(separator: "\n").count == 40)
        #expect(excerpt.hasSuffix("line 40"))
        #expect(
            CanvasCardSummaryText.excerpt(of: String(repeating: "x", count: 100), byteLimit: 10)
                == "")
        let now = Date()
        #expect(
            CanvasCardSummaryText.libraryDetail(
                cardCount: 5, modified: now.addingTimeInterval(-7_300), now: now)
                == "5 cards · edited 2 h ago")
        #expect(CanvasCardSummaryText.libraryDetail(cardCount: 1, modified: nil) == "1 card")
    }

    @Test("Fitting centres the bounds and never zooms in past the limit")
    func fitting() {
        let bounds = CGRect(x: 100, y: 50, width: 400, height: 200)
        let fit = CanvasZoomMetrics.viewport(fitting: bounds, in: CGSize(width: 1_000, height: 700))
        #expect(fit.scale == 1)
        #expect(fit.x == 200 && fit.y == 200)
        let large = CGRect(x: 0, y: 0, width: 4_600, height: 300)
        let shrunk = CanvasZoomMetrics.viewport(
            fitting: large, in: CGSize(width: 1_000, height: 700))
        #expect(shrunk.scale == 920.0 / 4_600.0)
        let tiny = CGRect(x: 0, y: 0, width: 50_000, height: 50_000)
        #expect(
            CanvasZoomMetrics.viewport(fitting: tiny, in: CGSize(width: 1_000, height: 700)).scale
                == CanvasZoomMetrics.minimumScale)
        #expect(
            CanvasZoomMetrics.viewport(fitting: .zero, in: CGSize(width: 1_000, height: 700))
                == CanvasViewport())
    }

    @Test("Scaling about a point keeps the board point under that point")
    func anchoredScaling() {
        let start = CanvasViewport(scale: 1, x: 30, y: -20)
        let anchor = CGPoint(x: 200, y: 100)
        let boardPoint = CGPoint(x: (200 - 30) / 1.0, y: (100 + 20) / 1.0)
        let next = CanvasZoomMetrics.viewport(
            scaling: start, to: 2, in: CGSize(width: 1_000, height: 700), anchor: anchor)
        #expect(next.scale == 2)
        #expect(boardPoint.x * 2 + next.x == 200 && boardPoint.y * 2 + next.y == 100)
        let centred = CanvasZoomMetrics.viewport(
            scaling: start, to: 2, in: CGSize(width: 1_000, height: 700))
        #expect((500 - centred.x) / 2 == (500 - start.x) / 1)
    }
}
