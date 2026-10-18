import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas board arrangement, z-order and zoom")
@MainActor
struct CanvasBoardLayoutTests {
    private func board(_ count: Int = 4) throws -> CanvasBoardState {
        var document = CanvasDocument(title: "Layout")
        document.cards = (0..<count).map { index in
            CanvasCard(
                title: "Card \(index)",
                rect: CanvasRect(
                    x: Double(index) * 50, y: Double(index) * 30, width: 300, height: 200),
                content: .note(snapshot: ""))
        }
        return CanvasBoardState(document: document)
    }

    @Test("Bring to Front and Send to Back reorder the stack and undo restores it")
    func zOrderUndo() throws {
        let board = try board()
        let original = board.cards.map(\.id)
        board.selection = [original[0]]
        try board.bringSelectionToFront()
        #expect(board.cards.map(\.id) == [original[1], original[2], original[3], original[0]])
        #expect(board.frontmostCardID == original[0])
        board.performUndo()
        #expect(board.cards.map(\.id) == original)
        board.selection = [original[3]]
        try board.sendSelectionToBack()
        #expect(board.cards.first?.id == original[3])
        // Already at the back: nothing changes and nothing is added to undo.
        board.performUndo()
        try board.reorder([original[3]], toFront: false)
        try board.reorder([original[3]], toFront: false)
        #expect(board.cards.first?.id == original[3])
    }

    @Test("Raising a card during a drag is part of the drag's single undo step")
    func raiseDuringDrag() throws {
        let board = try board()
        let original = board.cards.map(\.id)
        let moving = original[1]
        board.beginGesture()
        board.raiseDuringGesture([moving])
        var rect = try #require(board.cards.first { $0.id == moving }?.rect)
        rect.x += 100
        board.setRect(rect, for: moving)
        board.endGesture()
        #expect(board.cards.last?.id == moving)
        board.performUndo()
        #expect(board.cards.map(\.id) == original)
        #expect(board.cards[1].rect.x == 50)
        #expect(!board.canUndo)
    }

    @Test("Align and distribute edit only the selection and are undoable")
    func alignAndDistribute() throws {
        let board = try board()
        let ids = board.cards.map(\.id)
        board.selection = [ids[0], ids[1], ids[2]]
        try board.align(.left)
        #expect(board.cards.prefix(3).map(\.rect.x) == [0, 0, 0])
        #expect(board.cards[3].rect.x == 150)
        try board.align(.bottom)
        #expect(Set(board.cards.prefix(3).map { $0.rect.y + $0.rect.height }).count == 1)
        board.performUndo()
        board.performUndo()
        #expect(board.cards.map(\.rect.x) == [0, 50, 100, 150])
        // Two cards cannot be distributed.
        board.selection = [ids[0], ids[1]]
        try board.distribute(.horizontal)
        #expect(!board.canUndo)
        // A single card cannot be aligned.
        board.selection = [ids[0]]
        try board.align(.right)
        #expect(!board.canUndo)
    }

    @Test("Tidy Up leaves no overlap and Align Left keeps its older entry point")
    func tidy() throws {
        let board = try board(6)
        try board.arrange()
        let frames = board.cards.map { $0.rect.cgRect }
        for first in frames.indices {
            for second in frames.indices where second > first {
                #expect(!frames[first].intersects(frames[second]))
            }
        }
        board.selection = Set(board.cards.map(\.id))
        try board.alignSelection(leading: true)
        #expect(Set(board.cards.map(\.rect.x)).count == 1)
    }

    @Test("Keyboard resize keeps the per-type minimum and the maximum")
    func keyboardResize() throws {
        let board = try board(2)
        let id = board.cards[0].id
        board.selection = [id]
        try board.resizeSelection(dw: 8, dh: 0)
        #expect(board.cards[0].rect.width == 308 && board.cards[0].rect.height == 200)
        try board.resizeSelection(dw: -500, dh: -500)
        // A note stops at 200 x 120.
        #expect(board.cards[0].rect.width == 200 && board.cards[0].rect.height == 120)
        try board.resizeSelection(dw: 5_000, dh: 0)
        #expect(board.cards[0].rect.width == 2_000)
        // Several selected cards: no resize.
        board.selection = Set(board.cards.map(\.id))
        let before = board.cards.map(\.rect)
        try board.resizeSelection(dw: 8, dh: 8)
        #expect(board.cards.map(\.rect) == before)
    }

    @Test("A new card is centred in the visible board and later cards step 24 pt")
    func creationPlacement() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Task"))
        board.visibleSize = CGSize(width: 1_000, height: 800)
        try board.add(title: "One", content: .note(snapshot: ""))
        let first = board.cards[0].rect
        #expect(first.x + first.width / 2 == 500 && first.y + first.height / 2 == 400)
        try board.add(title: "Two", content: .note(snapshot: ""))
        let second = board.cards[1].rect
        #expect(second.x == first.x + 24 && second.y == first.y + 24)
        // The creation point of the Add popover wins, once.
        board.creationCenter = CGPoint(x: 1_000, y: 1_000)
        try board.add(title: "Three", content: .note(snapshot: ""))
        let third = board.cards[2].rect
        #expect(third.x + third.width / 2 == 1_000 && third.y + third.height / 2 == 1_000)
        #expect(board.creationCenter == nil)
        // A panned and zoomed board centres in board space.
        let zoomed = CanvasBoardState(document: CanvasDocument(title: "Zoomed"))
        zoomed.visibleSize = CGSize(width: 1_000, height: 800)
        zoomed.setViewport(.init(scale: 2, x: -400, y: 0))
        try zoomed.add(title: "Z", content: .note(snapshot: ""))
        let rect = zoomed.cards[0].rect
        #expect(rect.x + rect.width / 2 == 450 && rect.y + rect.height / 2 == 200)
    }

    @Test("Before the board is laid out a new card keeps the older cascade")
    func cascade() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Task"))
        try board.add(title: "One", content: .note(snapshot: ""))
        try board.add(title: "Two", content: .note(snapshot: ""))
        #expect(board.cards[0].rect.x == 40 && board.cards[1].rect.x == 76)
    }

    @Test("Zoom to Card, Selection, Fit and Actual Size set exact viewports")
    func zoomCommands() throws {
        let board = try board(2)
        board.visibleSize = CGSize(width: 1_000, height: 700)
        let card = board.cards[0]
        board.zoomToCard(card.id)
        // 300 x 200 in (1000 - 80) x (700 - 100): limited by height, 3x, capped at 2.
        #expect(board.viewport.scale == 2)
        let centre = CGPoint(
            x: (card.rect.x + card.rect.width / 2) * 2 + board.viewport.x,
            y: (card.rect.y + card.rect.height / 2) * 2 + board.viewport.y)
        #expect(centre.x == 500 && centre.y == 350)
        board.actualSize()
        #expect(board.viewport.scale == 1)
        board.selection = []
        board.zoomToSelection()
        #expect(board.viewport.scale == 1)
        board.fitAll()
        #expect(board.viewport.scale == 1)
        board.zoom(toScale: 0.01)
        #expect(board.viewport.scale == CanvasZoomMetrics.minimumScale)
        board.zoom(toScale: 99)
        #expect(board.viewport.scale == CanvasZoomMetrics.maximumScale)
    }

    @Test("Revealing a card pans only as far as needed and never changes the zoom")
    func reveal() throws {
        let board = try board(1)
        board.visibleSize = CGSize(width: 1_000, height: 700)
        board.setViewport(.init(scale: 1, x: -2_000, y: 0))
        board.revealCard(board.cards[0].id)
        #expect(board.viewport.scale == 1)
        #expect(board.viewport.x == 40)
        #expect(board.cards[0].rect.x * 1 + board.viewport.x >= 40)
    }

    @Test("Stored sizes admit the per-type minimums and reject smaller ones")
    func storedSizeBounds() {
        #expect(CanvasRect(x: 0, y: 0, width: 108, height: 78).isValid)
        #expect(!CanvasRect(x: 0, y: 0, width: 90, height: 78).isValid)
        #expect(!CanvasRect(x: 0, y: 0, width: 108, height: 60).isValid)
        #expect(CanvasViewport(scale: 0.1, x: 0, y: 0).isValid)
        #expect(CanvasViewport(scale: 4, x: 0, y: 0).isValid)
        #expect(!CanvasViewport(scale: 0.09, x: 0, y: 0).isValid)
        #expect(!CanvasViewport(scale: 4.1, x: 0, y: 0).isValid)
    }

    @Test("Link visibility is board view state and defaults to all links")
    func linkVisibility() throws {
        let board = try board(1)
        #expect(board.linkVisibility == .all)
        board.linkVisibility = .messageOnly
        #expect(board.linkVisibility == .messageOnly)
        #expect(
            CanvasLinkVisibility.allCases.map(\.title) == ["All", "Message Links Only", "None"])
        #expect(!board.isDirty)
    }

    @Test("Control-Tab alone returns to the board; other Tab chords do not")
    func returnKey() {
        typealias Host = CanvasReturnKeyMonitor.Host
        #expect(Host.isReturnToBoard(keyCode: 48, flags: .control))
        #expect(!Host.isReturnToBoard(keyCode: 48, flags: [.control, .shift]))
        #expect(!Host.isReturnToBoard(keyCode: 48, flags: [.control, .command]))
        #expect(!Host.isReturnToBoard(keyCode: 48, flags: []))
        #expect(!Host.isReturnToBoard(keyCode: 49, flags: .control))
    }
}

@Suite("Canvas card presentation")
struct CanvasCardPresentationTests {
    @Test("Terminal state words follow the glossary")
    func terminalWords() {
        #expect(CanvasCardPresentation.terminalState(status: .live, exitCode: nil) == "Running")
        #expect(
            CanvasCardPresentation.terminalState(status: .stopped, exitCode: nil) == "Not running")
        #expect(CanvasCardPresentation.terminalState(status: .exited, exitCode: 1) == "Exited (1)")
        #expect(CanvasCardPresentation.terminalState(status: .exited, exitCode: nil) == "Exited")
        #expect(
            CanvasCardPresentation.terminalState(status: .unavailable, exitCode: nil)
                == "Unavailable")
    }

    @Test("A web card shows host and port, not the full address")
    func webTitle() throws {
        let destination = try CanvasWebDestination("http://localhost:3000/app")
        let content = CanvasCardContent.web(destination: destination)
        #expect(
            CanvasCardPresentation.displayTitle(title: destination.address, content: content)
                == "localhost:3000")
        #expect(
            CanvasCardPresentation.displayTitle(title: "My app", content: content) == "My app")
        #expect(
            CanvasCardPresentation.displayTitle(
                title: "x", content: .note(snapshot: "")) == "x")
    }

    @Test("Shell and folder names read plainly")
    func bodyWords() {
        #expect(CanvasCardPresentation.shellName(.preferredShell) == "Default shell")
        #expect(CanvasCardPresentation.shellName(.approvedShellPath("/bin/zsh")) == "zsh")
        #expect(CanvasCardPresentation.folderName("") == "Workspace folder")
        #expect(CanvasCardPresentation.folderName("Sources/App") == "Sources/App")
    }

    @Test("The summary line is one short, useful line per card type")
    func summaryLine() {
        #expect(
            CanvasCardPresentation.summaryLine(
                for: .note(snapshot: "# Plan\n- [x] a\n- [ ] b"), terminalTitle: nil)
                == "1/2 tasks · Plan")
        #expect(
            CanvasCardPresentation.summaryLine(
                for: .file(path: "Sources/App/main.swift"), terminalTitle: nil) == "main.swift")
        #expect(
            CanvasCardPresentation.summaryLine(
                for: .terminal(groupID: TerminalGroupID()), terminalTitle: "swift test")
                == "swift test")
    }
}
