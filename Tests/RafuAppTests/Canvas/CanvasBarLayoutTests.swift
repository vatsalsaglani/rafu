import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// UX Round C, B7 and W1: the 30 pt bar hosts the tool palette from 980 pt.
@Suite("Ensemble bar layout")
struct CanvasBarLayoutTests {
    @Test("The bar is 30 pt and hosts the palette from 980 pt")
    func hostThreshold() {
        #expect(CanvasBarLayout.height == 30)
        #expect(!CanvasBarLayout.hostsPalette(barWidth: 979))
        #expect(CanvasBarLayout.hostsPalette(barWidth: 980))
        #expect(CanvasBarLayout.hostsPalette(barWidth: 1_400))
        #expect(!CanvasBarLayout.hostsPalette(barWidth: 0))
    }

    @Test("Drop labels sit under the floating palette, or at the top when it is hosted")
    func belowPaletteFollowsPlacement() {
        typealias Metrics = CanvasBoardTopOverlayMetrics
        #expect(Metrics.belowPalette(hosted: true) == Metrics.topInset)
        #expect(
            Metrics.belowPalette(hosted: false)
                == Metrics.topInset + Metrics.paletteHeight + Metrics.spacing)
    }

    @Test("Recent boards leave out the shown board and stop at eight")
    func recentBoards() {
        let items = (0..<12).map {
            CanvasSummary(id: CanvasID(rawValue: UUID()), title: "Board \($0)", revision: 1)
        }
        let recents = CanvasRecentBoards.recents(items, excluding: items[0].id)
        #expect(recents.count == CanvasRecentBoards.limit)
        #expect(!recents.contains { $0.id == items[0].id })
        #expect(recents.first?.id == items[1].id)
        #expect(CanvasRecentBoards.recents([], excluding: nil).isEmpty)
    }
}
