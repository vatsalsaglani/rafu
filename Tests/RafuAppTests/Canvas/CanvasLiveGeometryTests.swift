import Foundation
import Testing

@testable import RafuApp

/// A card drag or resize shows live rects and commits once on release: one
/// undo step, one dirty mark, one save request, and no document change (so
/// no re-render of unrelated cards) while the pointer is down.
@Suite("Canvas live drag geometry")
@MainActor
struct CanvasLiveGeometryTests {
    private func rect(_ x: Double, _ y: Double) -> CanvasRect {
        CanvasRect(x: x, y: y, width: 240, height: 160)
    }

    private func makeBoard() -> (CanvasBoardState, [CanvasCard]) {
        var document = CanvasDocument(title: "Drag")
        document.cards = (0..<3).map { index in
            CanvasCard(
                title: "Card \(index)", rect: rect(Double(index) * 400, 40),
                content: .file(path: "file-\(index).swift"))
        }
        return (CanvasBoardState(document: document), document.cards)
    }

    @Test("Drag frames change no stored state; the release is one step, one mark, one save")
    func dragCommitsOnce() throws {
        let (board, cards) = makeBoard()
        var saves = 0
        board.requestSave = { saves += 1 }
        let stamp = board.changeStamp
        let moving = cards[0].id

        board.beginGesture()
        for step in 1...30 {
            var next = cards[0].rect
            next.x += Double(step) * 4
            next.y += Double(step) * 2
            board.showLiveRects([moving: next])
        }
        // Nothing stored moved: no stamp bump (so no view that reads cards,
        // viewport or changeStamp re-runs), not dirty, no save, no undo.
        #expect(board.changeStamp == stamp)
        #expect(!board.isDirty)
        #expect(saves == 0)
        #expect(!board.canUndo)
        #expect(board.cards.map(\.rect) == cards.map(\.rect))
        #expect(board.liveGeometry.rect(for: moving)?.x == cards[0].rect.x + 120)
        #expect(board.liveGeometry.rect(for: cards[1].id) == nil)
        #expect(board.shownRect(of: moving)?.x == cards[0].rect.x + 120)
        #expect(board.shownRect(of: cards[1].id) == cards[1].rect)

        let final = try #require(board.liveGeometry.rect(for: moving))
        board.commitLiveRects([moving: final])
        board.endGesture()
        #expect(board.liveGeometry.rects.isEmpty)
        #expect(board.changeStamp == stamp &+ 1)
        #expect(board.isDirty)
        #expect(saves == 1)
        #expect(board.cards.first { $0.id == moving }?.rect == final)

        board.performUndo()
        #expect(board.cards.map(\.rect) == cards.map(\.rect))
        #expect(!board.canUndo)
    }

    @Test("A live rect equal to the stored rect is not live; an invalid rect keeps the last one")
    func liveRectEdgeCases() {
        let (board, cards) = makeBoard()
        let id = cards[1].id
        var moved = cards[1].rect
        moved.x += 16
        board.showLiveRects([id: moved])
        #expect(board.liveGeometry.rect(for: id) == moved)
        var invalid = moved
        invalid.width = -1
        board.showLiveRects([id: invalid])
        #expect(board.liveGeometry.rect(for: id) == moved)
        board.showLiveRects([id: cards[1].rect])
        #expect(board.liveGeometry.rects.isEmpty)
    }

    @Test("Ending a gesture never leaves live rects behind")
    func endGestureClearsLiveRects() {
        let (board, cards) = makeBoard()
        board.beginGesture()
        var moved = cards[2].rect
        moved.y += 80
        board.showLiveRects([cards[2].id: moved])
        board.endGesture()
        #expect(board.liveGeometry.rects.isEmpty)
        #expect(!board.canUndo)
        #expect(board.cards.map(\.rect) == cards.map(\.rect))
    }

    @Test("A raise plus a live drag is still one undo step")
    func raiseAndDragIsOneStep() throws {
        let (board, cards) = makeBoard()
        let moving = cards[0].id
        board.raiseDuringGesture([moving])
        board.beginGesture()
        var next = cards[0].rect
        next.x = 1_000
        board.showLiveRects([moving: next])
        board.commitLiveRects([moving: next])
        board.endGesture()
        #expect(board.cards.last?.id == moving)
        board.performUndo()
        #expect(board.cards.map(\.id) == cards.map(\.id))
        #expect(board.cards.map(\.rect) == cards.map(\.rect))
        #expect(!board.canUndo)
    }

    @Test("A frame refits live around a dragged member, as the commit will")
    func frameFollowsLive() throws {
        var document = CanvasDocument(title: "Diagram")
        let a = CanvasCard(
            title: "A", rect: CanvasRect(x: 0, y: 0, width: 160, height: 128),
            content: .text(CanvasText(text: "A")))
        let b = CanvasCard(
            title: "B", rect: CanvasRect(x: 400, y: 0, width: 160, height: 128),
            content: .text(CanvasText(text: "B")))
        document.cards = [a, b]
        let board = CanvasBoardState(document: document)
        let frame = try #require(try board.createFrame(title: "Group", memberIDs: [a.id, b.id]))
        let storedFrame = try #require(board.cards.first { $0.id == frame }?.rect)
        let stamp = board.changeStamp

        board.beginGesture()
        var moved = b.rect
        moved.y = 300
        board.showLiveRects([b.id: moved])
        let liveFrame = try #require(board.liveGeometry.rect(for: frame))
        #expect(liveFrame != storedFrame)
        #expect(liveFrame == CanvasFrameLayout.enclosingRect([a.rect, moved]))
        #expect(board.changeStamp == stamp)

        board.commitLiveRects([b.id: moved])
        board.endGesture()
        #expect(board.cards.first { $0.id == frame }?.rect == liveFrame)
        board.performUndo()
        #expect(board.cards.first { $0.id == frame }?.rect == storedFrame)
    }
}
