import CoreGraphics
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Ensemble board drop placement avoids existing cards")
struct CanvasDropPlacementTests {
    private let gap = CanvasBoardDropGeometry.placementGap
    private let content = CanvasCardContent.file(path: "a.swift")

    private func overlaps(_ a: CanvasRect, _ b: CanvasRect) -> Bool {
        a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap
            && b.y < a.y + a.height + gap
    }

    @Test("An empty board keeps the centred default rect")
    func emptyBoard() {
        let centre = CGPoint(x: 500, y: 400)
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [])
        #expect(rect == CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre))
    }

    @Test("A free drop point keeps the centred default rect")
    func freeSpot() {
        let centre = CGPoint(x: 500, y: 400)
        let far = CanvasRect(x: 5_000, y: 5_000, width: 380, height: 260)
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [far])
        #expect(rect == CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre))
    }

    @Test("A drop on a card moves to the nearest free position")
    func coveredDrop() {
        let centre = CGPoint(x: 500, y: 400)
        let desired = CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre)
        let card = desired
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [card])
        #expect(rect != desired)
        #expect(!overlaps(rect, card))
        // Nearest ring first: one card width plus the gap is far enough.
        let step = CanvasBoardDropGeometry.placementStep
        let reach = (max(desired.width, desired.height) + gap) / step + 1
        #expect(abs(rect.x - desired.x) <= reach * step)
        #expect(abs(rect.y - desired.y) <= reach * step)
    }

    @Test("A drop that only touches a card inside the gap still moves")
    func gapIsKept() {
        let centre = CGPoint(x: 500, y: 400)
        let desired = CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre)
        let neighbour = CanvasRect(
            x: desired.x + desired.width + gap / 2, y: desired.y, width: 380, height: 260)
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [neighbour])
        #expect(!overlaps(rect, neighbour))
    }

    @Test("A crowded board still yields a rect that clears every card")
    func crowdedBoard() {
        let centre = CGPoint(x: 0, y: 0)
        let desired = CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre)
        var cards: [CanvasRect] = []
        for column in -1...1 {
            for row in -1...1 {
                cards.append(
                    CanvasRect(
                        x: desired.x + Double(column) * (desired.width + gap),
                        y: desired.y + Double(row) * (desired.height + gap),
                        width: desired.width, height: desired.height))
            }
        }
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: cards)
        #expect(cards.allSatisfy { !overlaps(rect, $0) })
    }

    @Test("No free spot inside the search range falls back to the original position")
    func noRoomFallsBack() {
        let centre = CGPoint(x: 0, y: 0)
        let desired = CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre)
        let huge = CanvasRect(x: -20_000, y: -20_000, width: 40_000, height: 40_000)
        let rect = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [huge])
        #expect(rect == desired)
    }

    @Test("The result is deterministic")
    func deterministic() {
        let centre = CGPoint(x: 300, y: 300)
        let desired = CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: centre)
        let first = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [desired])
        let second = CanvasBoardDropGeometry.freeRect(
            for: content, centeredAt: centre, avoiding: [desired])
        #expect(first == second)
    }

    @Test("Frames, shapes, and strokes are not obstacles; other cards are")
    func obstacleKinds() {
        let rect = CanvasRect(x: 0, y: 0, width: 200, height: 100)
        let file = CanvasCard(title: "f", rect: rect, content: .file(path: "a.swift"))
        let note = CanvasCard(title: "n", rect: rect, content: .note(snapshot: ""))
        let terminal = CanvasCard(
            title: "t", rect: rect, content: .terminal(groupID: TerminalGroupID()))
        let obstacles = CanvasBoardDropGeometry.obstacles(in: [file, note, terminal])
        #expect(obstacles.count == 3)
    }

    @Test("The ghost and the added card use the same rect")
    @MainActor
    func ghostMatchesAdd() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Placement"))
        let centre = CGPoint(x: 500, y: 400)
        try board.add(title: "First", content: content, center: centre)
        let ghost = CanvasBoardDropGeometry.freeRect(
            for: .terminal(groupID: TerminalGroupID()), centeredAt: centre,
            avoiding: CanvasBoardDropGeometry.obstacles(in: board.cards))
        try board.add(
            title: "Second", content: .terminal(groupID: TerminalGroupID()), center: centre)
        let second = try #require(board.cards.last)
        #expect(second.rect == ghost)
        #expect(!overlaps(second.rect, board.cards[0].rect))
    }

    @Test("The drop preview resolver draws the ghost on the free position")
    func resolverUsesOccupied() throws {
        let centre = CGPoint(x: 500, y: 400)
        let covered = CanvasBoardDropGeometry.defaultRect(
            for: .terminal(groupID: TerminalGroupID()), centeredAt: centre)
        let context = CanvasDropAction.Context(hasWorkspace: true, occupied: [covered])
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .agentSession(
                    AgentHistorySessionKey(provider: .claudeCode, sessionID: "a")),
                at: centre, surface: CGSize(width: 1_000, height: 800),
                viewport: CanvasViewport(), context: context))
        guard case .card(let ghost) = preview.shape else {
            Issue.record("Expected a card ghost")
            return
        }
        #expect(
            !overlaps(
                CanvasRect(x: ghost.minX, y: ghost.minY, width: ghost.width, height: ghost.height),
                covered))
    }
}
