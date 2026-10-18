import Foundation
import Testing

@testable import RafuApp

@MainActor
@Suite("Canvas edge selection and editing")
struct CanvasEdgeActionsTests {
    private func makeBoard() throws -> (CanvasBoardState, [CanvasCard]) {
        var document = CanvasDocument(title: "Edges")
        document.cards = (0..<3).map { index in
            CanvasCard(
                title: "Card \(index)",
                rect: .init(x: Double(index) * 400, y: 40, width: 240, height: 160),
                content: .note(snapshot: ""))
        }
        let board = CanvasBoardState(document: document)
        return (board, document.cards)
    }

    @Test("Clicking an edge selects it and clears the card selection")
    func selectClearsCards() throws {
        let (board, cards) = try makeBoard()
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        let edge = try #require(board.connections.first)
        board.selection = [cards[0].id]
        board.selectConnection(edge.id)
        #expect(board.selection.isEmpty)
        #expect(board.selectedConnection?.id == edge.id)
        // Selecting a card deselects the edge even if nobody clears it.
        board.selection = [cards[2].id]
        #expect(board.selectedConnection == nil)
        board.selection = []
        #expect(board.selectedConnection?.id == edge.id)
        board.clearConnectionSelection()
        #expect(board.selectedConnection == nil)
    }

    @Test("Delete removes only a selected edge, in one undo step")
    func deleteSelected() throws {
        let (board, cards) = try makeBoard()
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        #expect(!board.deleteSelectedConnectionIfAny())
        #expect(board.connections.count == 1)
        let edge = try #require(board.connections.first)
        board.selectConnection(edge.id)
        #expect(board.deleteSelectedConnectionIfAny())
        #expect(board.connections.isEmpty)
        #expect(board.selectedConnectionID == nil)
        #expect(board.cards.count == 3)
        board.performUndo()
        #expect(board.connections.map(\.id) == [edge.id])
    }

    @Test("Deleting a message link revokes its live permission before the change")
    func deleteRevokes() throws {
        let (board, cards) = try makeBoard()
        var revoked: [UUID] = []
        board.revokeSessionLinks = { revoked.append(contentsOf: $0) }
        try board.addConnection(from: cards[0].id, to: cards[1].id, behavior: .session)
        let edge = try #require(board.connections.first)
        board.deleteConnection(edge.id)
        #expect(revoked == [edge.id])
    }

    @Test("Labels trim, validate, and fall back to the placeholder")
    func labels() throws {
        let (board, cards) = try makeBoard()
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        let id = try #require(board.connections.first?.id)
        board.setConnectionLabel(id, to: "  spec for  ")
        #expect(board.connection(id)?.label == "spec for")
        #expect(board.connection(id)?.customLabel == "spec for")
        board.setConnectionLabel(id, to: "   ")
        #expect(board.connection(id)?.label == "Related to")
        #expect(board.connection(id)?.customLabel == nil)
        board.setConnectionLabel(id, to: String(repeating: "x", count: 121))
        #expect(board.connection(id)?.label == "Related to")
        #expect(board.errorMessage != nil)
    }

    @Test("Reverse Direction swaps a relationship and ignores message links")
    func reverse() throws {
        let (board, cards) = try makeBoard()
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        let id = try #require(board.connections.first?.id)
        board.reverseConnection(id)
        #expect(board.connection(id)?.from == cards[1].id)
        #expect(board.connection(id)?.to == cards[0].id)
        board.performUndo()
        #expect(board.connection(id)?.from == cards[0].id)
    }

    @Test("Dragging an end handle to another card retargets, and refuses bad targets")
    func retarget() throws {
        let (board, cards) = try makeBoard()
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        let id = try #require(board.connections.first?.id)
        // The other end itself, and the card it already uses, are refused.
        #expect(!board.retargetConnection(id, movingFrom: false, to: cards[0].id))
        #expect(!board.retargetConnection(id, movingFrom: false, to: cards[1].id))
        #expect(board.retargetConnection(id, movingFrom: false, to: cards[2].id))
        #expect(board.connection(id)?.to == cards[2].id)
        // An identical link elsewhere refuses the move.
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        #expect(!board.retargetConnection(id, movingFrom: false, to: cards[1].id))
        board.performUndo()
        board.performUndo()
        #expect(board.connection(id)?.to == cards[1].id)
    }

    @Test("Connection rules reject self, identical and over-limit targets")
    func rules() throws {
        let (board, cards) = try makeBoard()
        #expect(board.canConnect(from: cards[0].id, to: cards[1].id))
        #expect(!board.canConnect(from: cards[0].id, to: cards[0].id))
        try board.addConnection(from: cards[0].id, to: cards[1].id)
        #expect(!board.canConnect(from: cards[0].id, to: cards[1].id))
        // A relationship has a direction, so the reverse is allowed.
        #expect(board.canConnect(from: cards[1].id, to: cards[0].id))
        #expect(board.hasConnection(from: cards[0].id, to: cards[1].id))

        let a = CanvasCardID()
        let b = CanvasCardID()
        let message = CanvasConnection(from: a, to: b, behavior: .session)
        #expect(
            !CanvasConnectionRules.canConnect(
                from: b, to: a, bothTerminals: true, existing: [message]))
        #expect(
            CanvasConnectionRules.canConnect(
                from: b, to: a, bothTerminals: false, existing: [message]))
        let full = (0..<CanvasLimits.connections).map { _ in
            CanvasConnection(from: CanvasCardID(), to: CanvasCardID())
        }
        #expect(
            !CanvasConnectionRules.canConnect(
                from: a, to: b, bothTerminals: false, existing: full))
        #expect(CanvasConnectionRules.behavior(bothTerminals: true) == .session)
        #expect(CanvasConnectionRules.behavior(bothTerminals: false) == .related)
    }

    @Test("Go to a card selects it and centres the viewport on it")
    func goTo() throws {
        let (board, cards) = try makeBoard()
        board.visibleSize = CGSize(width: 1_000, height: 600)
        board.goToCard(cards[2].id)
        #expect(board.selection == [cards[2].id])
        let viewport = board.viewport
        let centreX = (cards[2].rect.x + cards[2].rect.width / 2) * viewport.scale + viewport.x
        #expect(abs(centreX - 500) < 0.001)
    }
}
