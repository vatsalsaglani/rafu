import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// UX Round C, P1: the Open Ensemble row's board outline.
@Suite("Board silhouette")
struct CanvasBoardSilhouetteTests {
    @Test("Unit rects stay inside 0…1 and cover the bounds")
    func unitRects() {
        let silhouette = CanvasBoardSilhouette(cards: [
            CanvasRect(x: -200, y: 100, width: 400, height: 200),
            CanvasRect(x: 600, y: 500, width: 200, height: 300),
        ])
        #expect(silhouette.unitRects.count == 2)
        for rect in silhouette.unitRects {
            #expect(rect.minX >= 0 && rect.minY >= 0)
            #expect(rect.maxX <= 1 + 1e-9 && rect.maxY <= 1 + 1e-9)
        }
        #expect(silhouette.unitRects[0].origin == .zero)
        #expect(abs(silhouette.unitRects[1].maxX - 1) < 1e-9)
        #expect(abs(silhouette.unitRects[1].maxY - 1) < 1e-9)
        // Bounds 1000 × 700.
        #expect(abs(silhouette.aspect - 1_000.0 / 700.0) < 1e-9)
    }

    @Test("The drawing keeps the aspect, is centred, and stays inside the inset box")
    func fittedRects() throws {
        let wide = CanvasBoardSilhouette(cards: [CanvasRect(x: 0, y: 0, width: 400, height: 100)])
        let rect = try #require(wide.rects().first)
        #expect(abs(rect.width / rect.height - 4) < 1e-9)
        let size = CanvasBoardSilhouette.size
        let inset = CanvasBoardSilhouette.inset
        #expect(abs(rect.width - (size.width - 2 * inset)) < 1e-9)
        #expect(abs(rect.midY - size.height / 2) < 1e-9)

        let tall = CanvasBoardSilhouette(cards: [CanvasRect(x: 0, y: 0, width: 100, height: 400)])
        let tallRect = try #require(tall.rects().first)
        #expect(abs(tallRect.height - (size.height - 2 * inset)) < 1e-9)
        #expect(abs(tallRect.midX - size.width / 2) < 1e-9)

        let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let many = CanvasBoardSilhouette(
            cards: (0..<20).map {
                CanvasRect(x: Double($0 * 90), y: Double(($0 % 4) * 70), width: 80, height: 60)
            })
        for rect in many.rects() {
            #expect(box.insetBy(dx: -1e-9, dy: -1e-9).contains(rect))
        }
    }

    @Test("At most maxRects cards draw, and an empty board is an empty frame")
    func capAndEmpty() {
        let cards = (0..<100).map {
            CanvasRect(x: Double($0 * 10), y: 0, width: 80, height: 60)
        }
        #expect(
            CanvasBoardSilhouette(cards: cards).unitRects.count == CanvasBoardSilhouette.maxRects)
        #expect(CanvasBoardSilhouette.empty.unitRects.isEmpty)
        #expect(CanvasBoardSilhouette.empty.rects().isEmpty)
        #expect(CanvasBoardSilhouette(cards: []) == .empty)
    }

    @Test("A listed board's summary carries its silhouette")
    func summaryCarriesSilhouette() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let store = CanvasPersistenceStore(directory: root)
        var document = CanvasDocument(title: "Outline")
        document.cards = [.init(title: "Note", content: .note(snapshot: "a"))]
        _ = try await store.save(document, expectedRevision: 0, workspace: key)
        _ = try await store.save(
            CanvasDocument(title: "Empty"), expectedRevision: 0, workspace: key)
        let library = try await store.list(workspace: key)
        let outline = try #require(library.boards.first { $0.title == "Outline" })
        #expect(outline.silhouette.unitRects.count == 1)
        let empty = try #require(library.boards.first { $0.title == "Empty" })
        #expect(empty.silhouette == .empty)
    }
}
