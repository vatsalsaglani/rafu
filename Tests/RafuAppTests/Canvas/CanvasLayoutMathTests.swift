import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas layout math")
struct CanvasLayoutMathTests {
    private func rect(_ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 80)
        -> CanvasRect
    {
        CanvasRect(x: x, y: y, width: width, height: height)
    }

    @Test("Align moves every rect to the shared edge or centre")
    func align() {
        let rects = [rect(0, 0, 100, 50), rect(40, 100, 200, 80), rect(300, 20, 60, 40)]
        #expect(CanvasLayoutMath.align(rects, .left).map(\.x) == [0, 0, 0])
        #expect(CanvasLayoutMath.align(rects, .right).map(\.x) == [260, 160, 300])
        #expect(CanvasLayoutMath.align(rects, .centre).map(\.x) == [130, 80, 150])
        #expect(CanvasLayoutMath.align(rects, .top).map(\.y) == [0, 0, 0])
        #expect(CanvasLayoutMath.align(rects, .bottom).map(\.y) == [130, 100, 140])
        #expect(CanvasLayoutMath.align(rects, .middle).map(\.y) == [65, 50, 70])
        // Alignment never changes sizes.
        #expect(CanvasLayoutMath.align(rects, .left).map(\.width) == rects.map(\.width))
        // One rect is left alone.
        #expect(CanvasLayoutMath.align([rects[0]], .right) == [rects[0]])
    }

    @Test("Distribute equalises the gaps and keeps the outer rects and the input order")
    func distribute() {
        // Input order differs from position order on purpose.
        let rects = [rect(500, 0, 100), rect(0, 0, 100), rect(150, 0, 50)]
        let result = CanvasLayoutMath.distribute(rects, .horizontal)
        #expect(result[0].x == 500)
        #expect(result[1].x == 0)
        // Span 600, widths 250, two gaps of 175.
        #expect(result[2].x == 275)
        let vertical = CanvasLayoutMath.distribute(
            [rect(0, 0, 10, 100), rect(0, 120, 10, 100), rect(0, 600, 10, 100)], .vertical)
        #expect(vertical.map(\.y) == [0, 300, 600])
        // Two rects have nothing to distribute.
        #expect(
            CanvasLayoutMath.distribute([rects[0], rects[1]], .horizontal) == [rects[0], rects[1]])
    }

    @Test("Tidy Up removes every overlap and wraps rows")
    func tidy() {
        let rects = (0..<7).map { index in rect(Double(index % 2) * 10, Double(index) * 5, 380, 260)
        }
        let tidy = CanvasLayoutMath.tidy(rects, maximumRowWidth: 1_200)
        for first in tidy.indices {
            for second in tidy.indices where second > first {
                let a = CGRect(
                    x: tidy[first].x, y: tidy[first].y, width: tidy[first].width,
                    height: tidy[first].height)
                let b = CGRect(
                    x: tidy[second].x, y: tidy[second].y, width: tidy[second].width,
                    height: tidy[second].height)
                #expect(!a.intersects(b))
            }
        }
        // Three 380 pt rects and two 16 pt gaps fit in 1200; the fourth wraps.
        let ys = Set(tidy.map(\.y))
        #expect(ys.count == 3)
    }

    @Test("Reading order is top-left to bottom-right with row banding")
    func readingOrder() {
        let items: [(String, CanvasRect)] = [
            ("d", rect(0, 300)), ("b", rect(300, 10)), ("a", rect(0, 0)),
            ("c", rect(150, 20)),
        ]
        #expect(CanvasLayoutMath.readingOrder(of: items) == ["a", "c", "b", "d"])
    }

    @Test("Tab navigation walks reading order and wraps in both directions")
    func neighbour() {
        let cards = [
            CanvasCard(title: "Right", rect: rect(300, 0), content: .note(snapshot: "")),
            CanvasCard(title: "Below", rect: rect(0, 300), content: .note(snapshot: "")),
            CanvasCard(title: "Left", rect: rect(0, 0), content: .note(snapshot: "")),
        ]
        let left = cards[2].id
        let right = cards[0].id
        let below = cards[1].id
        #expect(CanvasLayoutMath.neighbour(of: nil, in: cards, forward: true) == left)
        #expect(CanvasLayoutMath.neighbour(of: nil, in: cards, forward: false) == below)
        #expect(CanvasLayoutMath.neighbour(of: left, in: cards, forward: true) == right)
        #expect(CanvasLayoutMath.neighbour(of: right, in: cards, forward: true) == below)
        #expect(CanvasLayoutMath.neighbour(of: below, in: cards, forward: true) == left)
        #expect(CanvasLayoutMath.neighbour(of: left, in: cards, forward: false) == below)
        #expect(CanvasLayoutMath.neighbour(of: left, in: [], forward: true) == nil)
    }

    @Test("Bring to Front and Send to Back keep relative order")
    func zOrder() {
        let cards = (0..<4).map {
            CanvasCard(title: "Card \($0)", content: .note(snapshot: ""))
        }
        let ids = Set([cards[0].id, cards[2].id])
        let front = CanvasLayoutMath.reordered(cards, moving: ids, toFront: true)
        #expect(front.map(\.title) == ["Card 1", "Card 3", "Card 0", "Card 2"])
        let back = CanvasLayoutMath.reordered(cards, moving: Set([cards[3].id]), toFront: false)
        #expect(back.map(\.title) == ["Card 3", "Card 0", "Card 1", "Card 2"])
        #expect(CanvasLayoutMath.reordered(cards, moving: [], toFront: true) == cards)
    }

    @Test("Resize resists past the minimum by 30% of the excess, at most 12 pt")
    func resistance() {
        #expect(CanvasLayoutMath.resisted(300, minimum: 200) == 300)
        #expect(CanvasLayoutMath.resisted(190, minimum: 200) == 197)
        #expect(CanvasLayoutMath.resisted(0, minimum: 200) == 188)
        let start = rect(100, 100, 320, 180)
        let minimum = CGSize(width: 320, height: 180)
        let pushed = CanvasLayoutMath.resize(
            start, edges: .right, dx: -50, dy: 0, minimum: minimum)
        #expect(pushed.reachedMinimum)
        #expect(pushed.rect.width == 320 - 12)
        let hard = CanvasLayoutMath.resize(
            start, edges: .right, dx: -50, dy: 0, minimum: minimum, allowsResistance: false)
        #expect(hard.rect.width == 320)
        #expect(hard.reachedMinimum)
        let normal = CanvasLayoutMath.resize(
            start, edges: .right, dx: 40, dy: 0, minimum: minimum)
        #expect(!normal.reachedMinimum && normal.rect.width == 360 && normal.rect.x == 100)
        #expect(CanvasLayoutMath.clampedToMinimum(pushed.rect, minimum: minimum).width == 320)
    }

    @Test("Resizing a left or top edge keeps the opposite edge fixed")
    func anchoredEdges() {
        let start = rect(100, 100, 400, 300)
        let minimum = CGSize(width: 200, height: 120)
        let left = CanvasLayoutMath.resize(start, edges: .left, dx: 50, dy: 0, minimum: minimum)
        #expect(left.rect.x == 150 && left.rect.width == 350)
        let corner = CanvasLayoutMath.resize(
            start, edges: [.left, .top], dx: -20, dy: -30, minimum: minimum)
        #expect(corner.rect.x == 80 && corner.rect.y == 70)
        #expect(corner.rect.width == 420 && corner.rect.height == 330)
        let capped = CanvasLayoutMath.resize(
            start, edges: .right, dx: 5_000, dy: 0, minimum: minimum)
        #expect(capped.rect.width == 2_000)
    }

    @Test("Image resize keeps its aspect ratio")
    func aspect() {
        let start = rect(0, 0, 400, 200)
        let minimum = CGSize(width: 120, height: 90)
        let wider = CanvasLayoutMath.resize(
            start, edges: .right, dx: 100, dy: 0, minimum: minimum, aspect: 2)
        #expect(wider.rect.width == 500 && wider.rect.height == 250)
        let taller = CanvasLayoutMath.resize(
            start, edges: .bottom, dx: 0, dy: 50, minimum: minimum, aspect: 2)
        #expect(taller.rect.width == 500 && taller.rect.height == 250)
    }

    @Test("Minimum sizes follow review section 7.3")
    func minimumSizes() throws {
        #expect(CanvasCardContent.note(snapshot: "").minimumSize == CGSize(width: 200, height: 120))
        #expect(CanvasCardContent.file(path: "a").minimumSize == CGSize(width: 220, height: 140))
        #expect(CanvasCardContent.image(path: "a").minimumSize == CGSize(width: 120, height: 90))
        #expect(
            CanvasCardContent.terminal(groupID: TerminalGroupID()).minimumSize
                == CGSize(width: 320, height: 180))
        #expect(
            CanvasCardContent.web(destination: try CanvasWebDestination("http://localhost:3000"))
                .minimumSize == CGSize(width: 320, height: 220))
        #expect(
            CanvasCardContent.nativeApp(bundleID: "com.apple.finder").minimumSize
                == CGSize(width: 220, height: 160))
    }
}
