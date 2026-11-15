import AppKit
import Foundation
import Testing

@testable import RafuApp

/// A click in an Ensemble card body selects and focuses the card, whatever
/// the body draws. The hit test and the decision are pure; the board's
/// AppKit monitor only feeds them the mouse-down.
@Suite("Canvas body click")
@MainActor
struct CanvasBodyClickTests {
    private static func card(
        _ content: CanvasCardContent = .note(snapshot: "Hello"),
        x: Double = 100, y: Double = 100, width: Double = 400, height: Double = 300
    ) -> CanvasCard {
        CanvasCard(
            title: "Card", rect: CanvasRect(x: x, y: y, width: width, height: height),
            content: content)
    }

    private static func hit(
        _ point: CGPoint, _ cards: [CanvasCard], viewport: CanvasViewport = CanvasViewport(),
        active: CanvasCardID? = nil, excluded: [CGRect] = []
    ) -> CanvasCardID? {
        CanvasBodyClick.card(
            at: point, cards: cards, viewport: viewport, activeCardID: active,
            excluded: excluded)
    }

    // MARK: Hit resolution

    @Test(
        "Every card kind with a header resolves a click in its body",
        arguments: [
            CanvasCardContent.note(snapshot: "Hello"),
            .file(path: "README.md"),
            .file(path: "Sources/main.swift"),
            .image(path: "logo.png"),
            .terminal(groupID: TerminalGroupID()),
            .mermaid(source: "graph TD; A-->B"),
        ])
    func bodyResolvesCard(content: CanvasCardContent) {
        let card = Self.card(content)
        #expect(Self.hit(CGPoint(x: 300, y: 250), [card]) == card.id)
    }

    @Test("The header, the edge bands and the outside are not the body")
    func headerAndEdgesAreNotBody() {
        let card = Self.card()
        // Header: 100 ..< 133.
        #expect(Self.hit(CGPoint(x: 300, y: 110), [card]) == nil)
        #expect(Self.hit(CGPoint(x: 300, y: 132), [card]) == nil)
        #expect(Self.hit(CGPoint(x: 300, y: 134), [card]) == card.id)
        // Resize and port bands on the left, right and bottom edges.
        #expect(Self.hit(CGPoint(x: 103, y: 250), [card]) == nil)
        #expect(Self.hit(CGPoint(x: 497, y: 250), [card]) == nil)
        #expect(Self.hit(CGPoint(x: 300, y: 397), [card]) == nil)
        // Outside the card.
        #expect(Self.hit(CGPoint(x: 50, y: 50), [card]) == nil)
        #expect(Self.hit(CGPoint(x: 600, y: 250), [card]) == nil)
    }

    @Test("The frontmost card under the point owns the click")
    func frontmostWins() {
        let back = Self.card(x: 100, y: 100)
        let front = Self.card(x: 300, y: 200)
        // The overlap is the front card's body.
        #expect(Self.hit(CGPoint(x: 400, y: 300), [back, front]) == front.id)
        #expect(Self.hit(CGPoint(x: 400, y: 300), [front, back]) == back.id)
        // The back card's body outside the overlap is still the back card.
        #expect(Self.hit(CGPoint(x: 200, y: 250), [back, front]) == back.id)
    }

    @Test("A header or a whiteboard item on top hides the body behind it")
    func itemsOnTopShieldTheBody() {
        let back = Self.card(x: 100, y: 100)
        // Front card's header (200 ..< 233) lies over the back card's body.
        let front = Self.card(x: 300, y: 200)
        #expect(Self.hit(CGPoint(x: 400, y: 210), [back, front]) == nil)
        let shape = Self.card(
            .shape(CanvasShape(kind: .rectangle, label: "")), x: 150, y: 200, width: 80,
            height: 80)
        #expect(Self.hit(CGPoint(x: 190, y: 240), [back, shape]) == nil)
        // A whiteboard item alone has no body.
        #expect(Self.hit(CGPoint(x: 190, y: 260), [shape]) == nil)
    }

    @Test("Compact faces have no body; an active terminal stays live down to 25 %")
    func compactFacesHaveNoBody() {
        let note = Self.card()
        let terminal = Self.card(.terminal(groupID: TerminalGroupID()))
        let zoomedOut = CanvasViewport(scale: 0.3, x: 0, y: 0)
        // Card at 30 %: 30 ..< 150 wide, 30 ..< 120 high; header ends at 39.9.
        let point = CGPoint(x: 90, y: 80)
        #expect(Self.hit(point, [note], viewport: zoomedOut) == nil)
        #expect(Self.hit(point, [terminal], viewport: zoomedOut) == nil)
        #expect(
            Self.hit(point, [terminal], viewport: zoomedOut, active: terminal.id) == terminal.id)
    }

    @Test("The hit follows the viewport's scale and offset")
    func viewportProjection() {
        let card = Self.card(x: 0, y: 0, width: 400, height: 300)
        let viewport = CanvasViewport(scale: 2, x: -100, y: 50)
        // Screen frame: x -100 ..< 700, y 50 ..< 650; header ends at 116.
        #expect(Self.hit(CGPoint(x: 300, y: 100), [card], viewport: viewport) == nil)
        #expect(Self.hit(CGPoint(x: 300, y: 120), [card], viewport: viewport) == card.id)
        #expect(Self.hit(CGPoint(x: 750, y: 300), [card], viewport: viewport) == nil)
    }

    @Test("A click on an overlay above the cards is not a body click")
    func overlaysAreExcluded() {
        let card = Self.card()
        let palette = CGRect(x: 250, y: 200, width: 100, height: 40)
        #expect(Self.hit(CGPoint(x: 300, y: 220), [card], excluded: [palette]) == nil)
        #expect(Self.hit(CGPoint(x: 300, y: 300), [card], excluded: [palette]) == card.id)
        let exclusions = CanvasBodyClickExclusions()
        exclusions.set("top", palette)
        #expect(exclusions.rects == [palette])
        exclusions.set("top", nil)
        #expect(exclusions.rects.isEmpty)
    }

    // MARK: Decision

    @Test("A plain click activates the card unless its content already has focus")
    func plainClick() {
        let id = CanvasCardID()
        let other = CanvasCardID()
        func decide(focused: CanvasCardID?, active: Bool) -> CanvasBodyClick.Decision {
            CanvasBodyClick.decision(
                card: id, modifiers: [], selection: [other], focusedCardID: focused,
                contentIsActive: active, cardsTakeClicks: true)
        }
        #expect(decide(focused: nil, active: false) == .activate(id))
        #expect(decide(focused: other, active: true) == .activate(id))
        // Selected or focused, but the board has the keys: enter the content.
        #expect(decide(focused: id, active: false) == .activate(id))
        #expect(decide(focused: id, active: true) == .none)
        // ⌥ alone does not change a plain click.
        #expect(
            CanvasBodyClick.decision(
                card: id, modifiers: .option, selection: [], focusedCardID: nil,
                contentIsActive: false, cardsTakeClicks: true) == .activate(id))
    }

    @Test("⌘- and ⇧-click toggle the card in the selection from before the click")
    func modifierClickToggles() {
        let id = CanvasCardID()
        let other = CanvasCardID()
        for modifiers: CanvasBodyClick.Modifiers in [.command, .shift, [.command, .shift]] {
            #expect(
                CanvasBodyClick.decision(
                    card: id, modifiers: modifiers, selection: [other], focusedCardID: nil,
                    contentIsActive: false, cardsTakeClicks: true) == .select([other, id]))
            #expect(
                CanvasBodyClick.decision(
                    card: id, modifiers: modifiers, selection: [other, id], focusedCardID: id,
                    contentIsActive: true, cardsTakeClicks: true) == .select([other]))
        }
    }

    @Test("⌃-click, a board mode, or no card under the pointer changes nothing")
    func nothingHappens() {
        let id = CanvasCardID()
        #expect(
            CanvasBodyClick.decision(
                card: id, modifiers: .control, selection: [], focusedCardID: nil,
                contentIsActive: false, cardsTakeClicks: true) == .none)
        #expect(
            CanvasBodyClick.decision(
                card: id, modifiers: [], selection: [], focusedCardID: nil,
                contentIsActive: false, cardsTakeClicks: false) == .none)
        #expect(
            CanvasBodyClick.decision(
                card: id, modifiers: .command, selection: [], focusedCardID: nil,
                contentIsActive: false, cardsTakeClicks: false) == .none)
        #expect(
            CanvasBodyClick.decision(
                card: nil, modifiers: [], selection: [id], focusedCardID: id,
                contentIsActive: true, cardsTakeClicks: true) == .none)
    }

    @Test("The monitor maps AppKit modifier flags")
    func modifierMapping() {
        let map = CanvasBodyClickMonitor.Host.modifiers
        #expect(map([]) == [])
        #expect(map([.command, .capsLock]) == .command)
        #expect(map([.shift, .option]) == [.shift, .option])
        #expect(map(.control) == .control)
    }

    // MARK: Focus

    @Test("A click never gives a stopped terminal or another board's terminal the keys")
    func terminalFocusRespectsTheLease() throws {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-body-click-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(
                    directory: FileManager.default.temporaryDirectory.appending(
                        path: UUID().uuidString))))
        let group = TerminalGroupID()
        let board = CanvasID()
        let before = session.terminalGroupFocusRequest
        // No lease, no group: nothing.
        session.focusCanvasTerminalContent(group, board: board)
        #expect(session.terminalGroupFocusRequest == before)
        // Leased to another board: nothing, and the lease stays there.
        let elsewhere = CanvasID()
        session.canvasTerminalOwners[group] = elsewhere
        session.focusCanvasTerminalContent(group, board: board)
        #expect(session.terminalGroupFocusRequest == before)
        #expect(session.canvasTerminalOwners[group] == elsewhere)
        // Leased here but no running terminal: nothing is started.
        session.canvasTerminalOwners[group] = board
        session.focusCanvasTerminalContent(group, board: board)
        #expect(session.terminalGroupFocusRequest == before)
        #expect(session.terminal.terminalGroup(group) == nil)
    }
}
