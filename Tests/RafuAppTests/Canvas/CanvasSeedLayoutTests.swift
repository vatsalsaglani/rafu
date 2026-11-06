import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// UX Round A, O1/S3: the seeds of an empty board.
@Suite("Ensemble empty-board seeds")
struct CanvasSeedLayoutTests {
    private func overlaps(_ a: CanvasRect, _ b: CanvasRect) -> Bool {
        a.cgRect.intersects(b.cgRect)
    }

    private func union(_ seeds: [CanvasSeed]) -> CGRect {
        seeds.dropFirst().reduce(seeds[0].rect.cgRect) { $0.union($1.rect.cgRect) }
    }

    @Test("Three seeds at the default sizes of note, terminal and file cards")
    func threeSeeds() {
        let seeds = CanvasSeedLayout.seeds(
            visible: CGSize(width: 1_800, height: 900), viewport: CanvasViewport())
        #expect(seeds.map(\.id) == [.note, .terminal, .drop])
        let sizes = seeds.map { CGSize(width: $0.rect.width, height: $0.rect.height) }
        #expect(sizes[0] == CanvasBoardDropGeometry.defaultSize(for: .note(snapshot: "")))
        #expect(
            sizes[1]
                == CanvasBoardDropGeometry.defaultSize(for: .terminal(groupID: TerminalGroupID())))
        #expect(sizes[2] == CanvasBoardDropGeometry.defaultSize(for: .file(path: "a")))
    }

    @Test("Seeds do not overlap and are centred in the visible board")
    func centredNoOverlap() {
        let viewport = CanvasViewport(scale: 0.5, x: 120, y: -80)
        let visible = CGSize(width: 1_400, height: 800)
        let seeds = CanvasSeedLayout.seeds(visible: visible, viewport: viewport)
        #expect(seeds.count == 3)
        for i in seeds.indices {
            for j in seeds.indices where j > i {
                #expect(!overlaps(seeds[i].rect, seeds[j].rect))
            }
        }
        let bounds = union(seeds)
        let centre = CGPoint(
            x: (Double(visible.width) / 2 - viewport.x) / viewport.scale,
            y: (Double(visible.height) / 2 - viewport.y) / viewport.scale)
        #expect(abs(bounds.midX - centre.x) <= 1)
        #expect(abs(bounds.midY - centre.y) <= 1)
        // One row: the visible board is 2,800 units wide.
        #expect(Set(seeds.map { $0.rect.y + $0.rect.height / 2 }).count == 1)
    }

    @Test("Two rows when the row is wider than the visible board")
    func twoRows() {
        let seeds = CanvasSeedLayout.seeds(
            visible: CGSize(width: 1_200, height: 900), viewport: CanvasViewport())
        #expect(seeds.count == 3)
        let note = seeds[0].rect
        let drop = seeds[2].rect
        #expect(drop.y > note.y + note.height)
        for i in seeds.indices {
            for j in seeds.indices where j > i {
                #expect(!overlaps(seeds[i].rect, seeds[j].rect))
            }
        }
        #expect(abs(union(seeds).midX - 600) <= 1)
    }

    @Test("An unmeasured board has no seeds")
    func unmeasured() {
        #expect(CanvasSeedLayout.seeds(visible: .zero, viewport: CanvasViewport()).isEmpty)
    }
}
