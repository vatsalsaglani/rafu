import AppKit
import Foundation
import Testing

@testable import RafuApp

private func cardID(_ number: Int) -> CanvasCardID {
    CanvasCardID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!)
}

private func node(
    _ number: Int, _ x: Double, _ y: Double, _ width: Double = 300, _ height: Double = 200,
    members: [Int]? = nil, drawing: Bool = false
) -> CanvasClusterLayout.Node {
    CanvasClusterLayout.Node(
        id: cardID(number), rect: CanvasRect(x: x, y: y, width: width, height: height),
        frameMembers: members?.map(cardID), isDrawing: drawing)
}

private func edge(_ a: Int, _ b: Int) -> (CanvasCardID, CanvasCardID) { (cardID(a), cardID(b)) }

private func cluster(
    _ nodes: [CanvasClusterLayout.Node], edges: [(CanvasCardID, CanvasCardID)] = [],
    attention: [CanvasCardID: Double] = [:], lastFocused: [CanvasCardID: Date] = [:],
    aspect: Double = 1.6
) -> [CanvasCardID: CanvasRect] {
    CanvasClusterLayout.clustered(
        nodes: nodes, edges: edges, attention: attention, lastFocused: lastFocused,
        targetAspect: aspect)
}

private func centre(_ rect: CanvasRect) -> CGPoint {
    CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
}

private func bounds(_ rects: [CanvasRect]) -> CGRect {
    rects.dropFirst().reduce(rects[0].cgRect) { $0.union($1.cgRect) }
}

/// Counts pairs that overlap or sit closer than `margin` points.
private func crowdedPairs(_ rects: [CanvasRect], margin: Double = 0) -> Int {
    var count = 0
    for first in rects.indices {
        for second in rects.indices where second > first {
            if rects[first].cgRect.insetBy(dx: -margin / 2, dy: -margin / 2)
                .intersects(rects[second].cgRect.insetBy(dx: -margin / 2, dy: -margin / 2))
            {
                count += 1
            }
        }
    }
    return count
}

/// A fixed pseudo-random board: the same on every run.
private func mixedBoard() -> (
    nodes: [CanvasClusterLayout.Node], edges: [(CanvasCardID, CanvasCardID)]
) {
    var seed: UInt64 = 42
    func next() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 33) / Double(1 << 31)
    }
    var nodes: [CanvasClusterLayout.Node] = []
    for number in 1...30 {
        nodes.append(
            node(
                number, next() * 2_000 - 500, next() * 1_500 - 300, 200 + next() * 440,
                120 + next() * 300))
    }
    // A chain, a star and a pair; the rest stay unlinked.
    let edges = [
        edge(1, 2), edge(2, 3), edge(3, 4), edge(4, 5), edge(10, 11), edge(10, 12), edge(10, 13),
        edge(10, 14), edge(10, 15), edge(20, 21),
    ]
    return (nodes, edges)
}

@Suite("Clustering Tidy Up layout")
struct CanvasClusterLayoutTests {
    @Test("A mixed 30-card board has no overlaps, valid rects and unchanged sizes")
    func noOverlaps() {
        let board = mixedBoard()
        let result = cluster(board.nodes, edges: board.edges)
        #expect(result.count == 30)
        for source in board.nodes {
            let rect = result[source.id]
            #expect(rect != nil)
            #expect(rect?.isValid == true)
            #expect(rect?.width == source.rect.width && rect?.height == source.rect.height)
        }
        // The layout keeps a 24 pt gap; rounding may shave a point.
        #expect(crowdedPairs(Array(result.values), margin: 22) == 0)
    }

    @Test("Two separate link groups land in separate regions")
    func separateRegions() {
        let nodes = [
            node(1, 0, 0), node(2, 20, 10), node(3, 40, 20), node(4, 60, 30),
            node(5, 80, 40), node(6, 100, 50), node(7, 120, 60), node(8, 140, 70),
        ]
        let edges = [edge(1, 2), edge(1, 3), edge(1, 4), edge(5, 6), edge(5, 7), edge(5, 8)]
        let result = cluster(nodes, edges: edges)
        let first = bounds([1, 2, 3, 4].compactMap { result[cardID($0)] })
        let second = bounds([5, 6, 7, 8].compactMap { result[cardID($0)] })
        #expect(!first.intersects(second))
        // At least a cluster gap apart on one axis.
        let apartX = max(first.minX - second.maxX, second.minX - first.maxX)
        let apartY = max(first.minY - second.maxY, second.minY - first.maxY)
        #expect(max(apartX, apartY) >= 70)
    }

    @Test("The most attended card is the hub and its links sit around it")
    func hubIsCentral() throws {
        let nodes = [node(1, 0, 0), node(2, 10, 0), node(3, 20, 0), node(4, 30, 0), node(5, 40, 0)]
        let edges = [edge(1, 2), edge(1, 3), edge(1, 4), edge(1, 5)]
        // Card 3 has the most attention, so it is the hub: card 1 (linked to it)
        // is close and the cards behind card 1 sit further out.
        let star = cluster(
            nodes, edges: edges + [edge(3, 1)], attention: [cardID(3): 600, cardID(1): 5])
        let hub = try #require(star[cardID(3)])
        func distance(_ id: Int, from rect: CanvasRect) throws -> Double {
            let other = try #require(star[cardID(id)])
            return hypot(centre(other).x - centre(rect).x, centre(other).y - centre(rect).y)
        }
        let near = try distance(1, from: hub)
        for far in [2, 4, 5] { #expect(try distance(far, from: hub) > near) }
        // With links only, the card with the most links (1) is the hub, centred.
        let linksOnly = cluster(nodes, edges: edges)
        let linkHub = try #require(linksOnly[cardID(1)])
        let linkBox = bounds(Array(linksOnly.values))
        #expect(abs(centre(linkHub).x - linkBox.midX) <= 2)
        #expect(abs(centre(linkHub).y - linkBox.midY) <= 2)
        for other in 2...5 {
            let rect = try #require(linksOnly[cardID(other)])
            let distance = hypot(
                centre(rect).x - centre(linkHub).x, centre(rect).y - centre(linkHub).y)
            // Half diagonals of two 300 x 200 cards plus the gap, plus rounding.
            #expect(distance <= 360.56 + 24 + 2)
        }
    }

    @Test("The hub changes with attention: the chain bends around the card you work in")
    func attentionMovesTheHub() throws {
        let nodes = [node(1, 0, 0), node(2, 10, 0), node(3, 20, 0)]
        let chain = [edge(1, 2), edge(2, 3)]
        func gap(_ result: [CanvasCardID: CanvasRect], _ a: Int, _ b: Int) throws -> Double {
            let first = try #require(result[cardID(a)])
            let second = try #require(result[cardID(b)])
            return hypot(centre(first).x - centre(second).x, centre(first).y - centre(second).y)
        }
        // Links only: 2 is the hub, so 1 and 3 are equally far from it.
        let plain = cluster(nodes, edges: chain)
        #expect(abs(try gap(plain, 2, 1) - gap(plain, 2, 3)) < 2)
        // Attention on 3 makes it the hub: 1 is now two links away.
        let focused = cluster(nodes, edges: chain, attention: [cardID(3): 900])
        #expect(try gap(focused, 3, 1) > gap(focused, 3, 2))
    }

    @Test("Frame members keep their exact offsets and no frame rect is returned")
    func frameIsRigid() throws {
        let nodes = [
            node(100, 90, 40, 700, 500, members: [1, 2]),
            node(1, 130, 112, 300, 200), node(2, 480, 150, 260, 180),
            node(3, 2_000, 0), node(4, 0, 2_000),
        ]
        let result = cluster(nodes, edges: [edge(2, 3)])
        #expect(result[cardID(100)] == nil)
        let one = try #require(result[cardID(1)])
        let two = try #require(result[cardID(2)])
        #expect(abs((two.x - one.x) - (480 - 130)) < 1e-9)
        #expect(abs((two.y - one.y) - (150 - 112)) < 1e-9)
        #expect(result.count == 4)
    }

    @Test("A frame with no members on the board is an ordinary card")
    func emptyFrameMoves() {
        let nodes = [node(100, 0, 0, 400, 300, members: []), node(1, 50, 50)]
        let result = cluster(nodes)
        #expect(result[cardID(100)] != nil)
        #expect(result[cardID(1)] != nil)
        #expect(crowdedPairs(Array(result.values)) == 0)
    }

    @Test("Nested frames move as one rigid unit")
    func nestedFrames() throws {
        let nodes = [
            node(100, 0, 0, 900, 700, members: [101, 3]),
            node(101, 40, 80, 500, 400, members: [1, 2]),
            node(1, 70, 150, 200, 150), node(2, 300, 160, 200, 150),
            node(3, 600, 200, 220, 160), node(4, 1_500, 0),
        ]
        let result = cluster(nodes, edges: [edge(1, 4)])
        #expect(result[cardID(100)] == nil && result[cardID(101)] == nil)
        let one = try #require(result[cardID(1)])
        let three = try #require(result[cardID(3)])
        #expect(abs((three.x - one.x) - 530) < 1e-9)
        #expect(abs((three.y - one.y) - 50) < 1e-9)
    }

    @Test("Loose drawings near a card move with it; far ones come last")
    func looseDrawings() throws {
        let nodes = [
            node(1, 0, 0), node(2, 1_000, 0),
            node(10, 320, 20, 60, 60, drawing: true),  // 20 pt from card 1
            node(11, 4_000, 4_000, 80, 80, drawing: true),  // far from everything
        ]
        let result = cluster(nodes)
        let card = try #require(result[cardID(1)])
        let near = try #require(result[cardID(10)])
        #expect(abs((near.x - card.x) - 320) < 1e-9)
        #expect(abs((near.y - card.y) - 20) < 1e-9)
        let far = try #require(result[cardID(11)])
        // The far drawing joins the layout instead of staying 4,000 pt away.
        #expect(far.x < 2_000 && far.y < 2_000)
        #expect(crowdedPairs(Array(result.values)) == 0)
    }

    @Test("The result does not depend on the order of the input")
    func orderIndependent() {
        let board = mixedBoard()
        let attention = [cardID(10): 300.0, cardID(3): 120.0]
        let first = cluster(board.nodes, edges: board.edges, attention: attention)
        var shuffled = board.nodes
        shuffled.reverse()
        shuffled.swapAt(3, 17)
        let second = cluster(shuffled, edges: board.edges.reversed(), attention: attention)
        #expect(first == second)
        #expect(first == cluster(board.nodes, edges: board.edges, attention: attention))
    }

    @Test("Empty attention is links-only and still tidy")
    func emptyAttention() {
        let board = mixedBoard()
        let result = cluster(board.nodes, edges: board.edges, attention: [:], lastFocused: [:])
        #expect(result.count == 30)
        #expect(crowdedPairs(Array(result.values), margin: 22) == 0)
    }

    @Test("A wide viewport makes a wider layout than a square one")
    func aspectShapesLayout() {
        let nodes = (1...12).map { node($0, Double($0) * 10, Double($0) * 10) }
        let wide = bounds(Array(cluster(nodes, aspect: 3).values))
        let square = bounds(Array(cluster(nodes, aspect: 1).values))
        #expect(wide.width > square.width)
        #expect(wide.height < square.height)
    }

    @Test("Linked 640 x 420 terminals form a cluster, not two columns")
    func terminalsAreNotAGrid() {
        // The old Tidy Up capped rows at 1,800 pt, so every board of 640 x 420
        // terminals became exactly two columns.
        let nodes = [
            node(1, 0, 0, 640, 420), node(2, 10, 0, 640, 420), node(3, 20, 0, 640, 420),
            node(4, 30, 0, 640, 420),
        ]
        let result = cluster(nodes, edges: [edge(1, 2), edge(1, 3), edge(1, 4)], aspect: 1.6)
        let columns = Set(result.values.map { ($0.x / 10).rounded() })
        #expect(columns.count >= 3)
        #expect(crowdedPairs(Array(result.values), margin: 22) == 0)
    }

    @Test("The cluster you used most recently comes first")
    func recentClusterFirst() throws {
        let nodes = [node(1, 100, 100), node(2, 900, 900)]
        let now = Date()
        let result = cluster(
            nodes, attention: [cardID(2): 60], lastFocused: [cardID(2): now])
        let recent = try #require(result[cardID(2)])
        let other = try #require(result[cardID(1)])
        // The layout keeps the top-left of the old content: the recent card takes it.
        #expect(recent.x == 100 && recent.y == 100)
        #expect(other.x > recent.x || other.y > recent.y)
    }

    @Test("Nothing moves far from where the board was")
    func keepsOrigin() throws {
        let result = cluster([node(1, 500, 700), node(2, 900, 1_000)], edges: [edge(1, 2)])
        let box = bounds(Array(result.values))
        #expect(box.minX >= 500 - 2 && box.minY >= 700 - 2)
        #expect(box.minX <= 500 + 400 && box.minY <= 700 + 400)
    }

    @Test("Extreme coordinates stay inside the stored range")
    func clampsRange() {
        let nodes = [node(1, 49_900, 49_900), node(2, 49_800, -49_900), node(3, -49_900, 49_800)]
        let result = cluster(nodes, edges: [edge(1, 2), edge(2, 3)])
        let valid = result.values.allSatisfy { $0.isValid }
        #expect(valid)
    }
}

@Suite("Tidy Up on a board")
@MainActor
struct CanvasTidyBoardTests {
    @Test("Tidy Up keeps a frame around its members only and undo restores one step")
    func frameAfterTidy() throws {
        var document = CanvasDocument(title: "Tidy")
        let members = (0..<2).map {
            CanvasCard(
                title: "Member \($0)",
                rect: CanvasRect(x: 100 + Double($0) * 350, y: 130, width: 300, height: 200),
                content: .note(snapshot: ""))
        }
        let others = (0..<4).map {
            CanvasCard(
                title: "Other \($0)",
                rect: CanvasRect(
                    x: 60 + Double($0) * 40, y: 400 + Double($0) * 30, width: 300, height: 200),
                content: .note(snapshot: ""))
        }
        let frame = CanvasCard(
            title: "Group", rect: CanvasRect(x: 68, y: 62, width: 704, height: 300),
            content: .frame(CanvasFrame(title: "Group", memberIDs: members.map(\.id))))
        document.cards = [frame] + members + others
        document.connections = [
            CanvasConnection(from: members[1].id, to: others[0].id, label: "Related to")
        ]
        let board = CanvasBoardState(document: document)
        board.visibleSize = CGSize(width: 1_200, height: 800)
        let before = board.cards.map(\.rect)
        let viewportBefore = board.viewport
        try board.arrange()

        let byID = Dictionary(uniqueKeysWithValues: board.cards.map { ($0.id, $0.rect) })
        let memberBox = bounds(members.compactMap { byID[$0.id] })
        let frameRect = try #require(byID[frame.id])
        #expect(frameRect.cgRect.contains(memberBox))
        // The frame encloses its members and nothing else.
        let enclosing = memberBox.insetBy(dx: -40, dy: -80)
        #expect(frameRect.cgRect.minX >= enclosing.minX - 1)
        #expect(frameRect.cgRect.minY >= enclosing.minY - 1)
        for card in board.cards where card.id != frame.id && !members.map(\.id).contains(card.id) {
            #expect(!frameRect.cgRect.intersects(card.rect.cgRect))
        }
        let rects = board.cards.filter { $0.id != frame.id }.map(\.rect)
        #expect(crowdedPairs(rects) == 0)
        // Sizes are never written.
        #expect(Set(board.cards.map(\.rect.width)) == Set(before.map(\.width)))
        // Zoom to fit follows: the viewport changed.
        #expect(board.viewport != viewportBefore)

        // One undo restores every position at once.
        board.performUndo()
        #expect(board.cards.map(\.rect) == before)
        #expect(!board.canUndo)
    }

    @Test("Tidy Up puts the card you worked in first")
    func attentionOrdersClusters() throws {
        var document = CanvasDocument(title: "Attention")
        document.cards = (0..<3).map {
            CanvasCard(
                title: "Card \($0)",
                rect: CanvasRect(x: 100 + Double($0) * 40, y: 100, width: 300, height: 200),
                content: .note(snapshot: ""))
        }
        let board = CanvasBoardState(document: document)
        let worked = board.cards[2].id
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        board.resumeAttention(now: start)
        board.focusedCardID = worked
        board.contentIsActive = true
        board.attentionFocusChanged(now: start)
        board.suspendAttention(now: start.addingTimeInterval(120))
        try board.arrange(now: start.addingTimeInterval(130))
        let rect = try #require(board.cards.first { $0.id == worked }?.rect)
        #expect(rect.x == 100 && rect.y == 100)
    }
}
