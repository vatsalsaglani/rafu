import CoreGraphics
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Ensemble board drop preview resolver")
struct CanvasDropActionResolveTests {
    private let viewport = CanvasViewport()
    private let surface = CGSize(width: 1_000, height: 800)
    private let centre = CGPoint(x: 500, y: 400)

    private func context(
        cardCount: Int = 0, isTerminalGroupTab: Bool = false, paneCount: Int = 1,
        alreadyOnABoard: Bool = false, boardFull: Bool = false
    ) -> CanvasDropAction.Context {
        CanvasDropAction.Context(
            hasWorkspace: true, cardCount: cardCount, isTerminalGroupTab: isTerminalGroupTab,
            paneCount: paneCount, alreadyOnABoard: alreadyOnABoard, boardFull: boardFull)
    }

    @Test("No workspace resolves to no preview at all")
    func noWorkspace() {
        let preview = CanvasDropAction.resolve(
            content: .agentSession(AgentHistorySessionKey(provider: .claudeCode, sessionID: "a")),
            at: centre, surface: surface, viewport: viewport,
            context: CanvasDropAction.Context(hasWorkspace: false))
        #expect(preview == nil)
    }

    @Test("A single non-image file previews a file-sized ghost card")
    func singleFile() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .files([URL(fileURLWithPath: "/a.swift")], fromFilesTree: true),
                at: centre, surface: surface, viewport: viewport, context: context()))
        #expect(preview.label == "Open as file card")
        #expect(preview.tone == .accept)
        guard case .card(let rect) = preview.shape else {
            Issue.record("Expected a card shape")
            return
        }
        #expect(rect.width == 380)
        #expect(rect.height == 260)
    }

    @Test("A single image file previews an image card")
    func singleImage() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .files([URL(fileURLWithPath: "/a.png")], fromFilesTree: true),
                at: centre, surface: surface, viewport: viewport, context: context()))
        #expect(preview.label == "Add image card")
        #expect(preview.tone == .accept)
    }

    @Test("Multiple files preview a whole-board batch, not a precise ghost")
    func multipleFiles() throws {
        let urls = (0..<3).map { URL(fileURLWithPath: "/a\($0).swift") }
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .files(urls, fromFilesTree: false), at: centre, surface: surface,
                viewport: viewport, context: context()))
        #expect(preview.label == "Add 3 cards")
        #expect(preview.tone == .accept)
        #expect(preview.shape == .board)
    }

    @Test("A batch that would not fit previews the full-board warning")
    func filesDoNotFit() throws {
        let urls = [URL(fileURLWithPath: "/a.swift")]
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .files(urls, fromFilesTree: false), at: centre, surface: surface,
                viewport: viewport, context: context(cardCount: CanvasLimits.cards)))
        #expect(preview.label == "This Ensemble is full")
        #expect(preview.tone == .warn)
        #expect(preview.shape == .board)
    }

    @Test("An Agent History row previews resuming into a new terminal card")
    func agentSession() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .agentSession(
                    AgentHistorySessionKey(provider: .claudeCode, sessionID: "a")),
                at: centre, surface: surface, viewport: viewport, context: context()))
        #expect(preview.label == "Resume chat in a new terminal")
        #expect(preview.tone == .accept)
        guard case .card(let rect) = preview.shape else {
            Issue.record("Expected a card shape")
            return
        }
        #expect(rect.width == 640)
        #expect(rect.height == 420)
    }

    @Test("An Agent History row on a full board previews the full-board warning")
    func agentSessionBoardFull() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .agentSession(
                    AgentHistorySessionKey(provider: .claudeCode, sessionID: "a")),
                at: centre, surface: surface, viewport: viewport, context: context(boardFull: true)
            ))
        #expect(preview.label == "This Ensemble is full")
        #expect(preview.tone == .warn)
    }

    @Test("A Terminals-panel row previews the same move as a dragged terminal tab")
    func terminalGroupRow() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .terminalGroup(TerminalGroupID()), at: centre, surface: surface,
                viewport: viewport, context: context(isTerminalGroupTab: true, paneCount: 1)))
        #expect(preview.label == "Move terminal here — keeps running")
        #expect(preview.tone == .accept)
    }

    @Test("A one-pane terminal tab dropped centrally previews moving it onto the board")
    func terminalTabCentreOnePane() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .tab(UUID().uuidString), at: centre, surface: surface, viewport: viewport,
                context: context(isTerminalGroupTab: true, paneCount: 1)))
        #expect(preview.label == "Move terminal here — keeps running")
        #expect(preview.tone == .accept)
    }

    @Test("A two-pane terminal tab dropped centrally previews the pane-count refusal")
    func terminalTabCentreTwoPanes() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .tab(UUID().uuidString), at: centre, surface: surface, viewport: viewport,
                context: context(isTerminalGroupTab: true, paneCount: 2)))
        #expect(preview.label == "Needs a single-pane terminal")
        #expect(preview.tone == .warn)
        #expect(preview.shape == .board)
    }

    @Test("A terminal tab already on a board previews that refusal")
    func terminalTabAlreadyOnBoard() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .tab(UUID().uuidString), at: centre, surface: surface, viewport: viewport,
                context: context(isTerminalGroupTab: true, paneCount: 1, alreadyOnABoard: true)))
        #expect(preview.label == "Already on an Ensemble")
        #expect(preview.tone == .warn)
    }

    @Test("A terminal tab dropped at every edge previews the matching split")
    func terminalTabEdges() throws {
        let cases: [(CGPoint, String, EditorSplitEdge)] = [
            (CGPoint(x: 5, y: 400), "Split editor left", .leading),
            (CGPoint(x: 995, y: 400), "Split editor right", .trailing),
            (CGPoint(x: 500, y: 5), "Split editor up", .top),
            (CGPoint(x: 500, y: 795), "Split editor down", .bottom),
        ]
        for (point, label, edge) in cases {
            let preview = try #require(
                CanvasDropAction.resolve(
                    content: .tab(UUID().uuidString), at: point, surface: surface,
                    viewport: viewport, context: context(isTerminalGroupTab: true, paneCount: 1)))
            #expect(preview.label == label)
            #expect(preview.tone == .accept)
            #expect(preview.shape == .edge(edge))
        }
    }

    @Test("A non-terminal tab dropped centrally previews moving it into this group")
    func nonTerminalTabCentre() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .tab(UUID().uuidString), at: centre, surface: surface, viewport: viewport,
                context: context(isTerminalGroupTab: false)))
        #expect(preview.label == "Move tab to this editor group")
        #expect(preview.tone == .accept)
        #expect(preview.shape == .board)
    }

    @Test("A non-terminal tab dropped at an edge still previews the split, not a board move")
    func nonTerminalTabEdge() throws {
        let preview = try #require(
            CanvasDropAction.resolve(
                content: .tab(UUID().uuidString), at: CGPoint(x: 5, y: 400), surface: surface,
                viewport: viewport, context: context(isTerminalGroupTab: false)))
        #expect(preview.label == "Split editor left")
        #expect(preview.shape == .edge(.leading))
    }
}

@Suite("Ensemble board drop preview state reducer")
struct CanvasDropPreviewChangedTests {
    private let sample = CanvasDropPreview(label: "x", tone: .accept, shape: .board)

    @Test("Exit, perform, and conclude all clear a non-nil preview")
    func clearsFromSomething() {
        #expect(CanvasDropPreview.changed(from: sample, to: nil))
    }

    @Test("Exit, perform, and conclude are no-ops when already nil")
    func noOpWhenAlreadyNil() {
        #expect(!CanvasDropPreview.changed(from: nil, to: nil))
    }

    @Test("Hovering the exact same preview twice is a no-op")
    func noOpWhenUnchanged() {
        #expect(!CanvasDropPreview.changed(from: sample, to: sample))
    }

    @Test("A different preview at the same spot is a change")
    func changedWhenDifferent() {
        let other = CanvasDropPreview(label: "y", tone: .warn, shape: .board)
        #expect(CanvasDropPreview.changed(from: sample, to: other))
    }
}

@Suite("Ensemble board default card rect geometry")
@MainActor
struct CanvasBoardDropGeometryDefaultRectTests {
    @Test("defaultRect matches what add(center:) produces for a terminal card")
    func terminalMatchesAdd() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Geometry"))
        let center = CGPoint(x: 500, y: 400)
        let groupID = TerminalGroupID()
        try board.add(title: "T", content: .terminal(groupID: groupID), center: center)
        let card = try #require(board.cards.first)
        let rect = CanvasBoardDropGeometry.defaultRect(
            for: .terminal(groupID: groupID), centeredAt: center)
        #expect(rect == card.rect)
    }

    @Test("defaultRect matches what add(center:) produces for a file card")
    func fileMatchesAdd() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Geometry"))
        let center = CGPoint(x: 120, y: 90)
        try board.add(title: "F", content: .file(path: "a.swift"), center: center)
        let card = try #require(board.cards.first)
        let rect = CanvasBoardDropGeometry.defaultRect(
            for: .file(path: "a.swift"), centeredAt: center)
        #expect(rect == card.rect)
    }

    @Test(
        "defaultRect through a scaled, offset viewport matches add(center:) at the same board point"
    )
    func scaledOffsetViewport() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Geometry"))
        let viewport = CanvasViewport(scale: 2, x: 100, y: -50)
        let viewPoint = CGPoint(x: 300, y: 150)
        let boardPoint = CanvasBoardDropGeometry.boardPoint(viewPoint, viewport: viewport)
        try board.add(
            title: "T", content: .terminal(groupID: TerminalGroupID()), center: boardPoint)
        let card = try #require(board.cards.first)
        let rect = CanvasBoardDropGeometry.defaultRect(
            for: .terminal(groupID: TerminalGroupID()), centeredAt: boardPoint)
        #expect(rect == card.rect)
    }
}
