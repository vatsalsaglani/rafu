import CoreGraphics
import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// The approval peek's pure parts: the deck, the fit rule, the card content,
/// the swipe policy, the geometry and the announcement. No window, no store.

private func entry(
    _ command: String = "npm test", at seconds: TimeInterval = 0, cli: ConductorCLIID = .codex,
    key: UUID = UUID()
) -> ApprovalPeekEntry {
    ApprovalPeekEntry(
        controllerID: UUID(), title: "agent", cli: cli,
        request: CanvasAgentRequest(
            key: key, kind: .command, command: command,
            receivedAt: Date(timeIntervalSinceReferenceDate: seconds)))
}

private func question(choices: [String], text: String = "Which theme?")
    -> CanvasAgentRequest.Question
{
    CanvasAgentRequest.Question(
        id: "q", header: "Theme", text: text,
        choices: choices.map { .init(label: $0, detail: "") })
}

// MARK: - Deck

@Test("ApprovalPeekDeck: entries sort by arrival time, then by key")
func approvalPeekDeckOrder() {
    let early = entry(at: 1)
    let late = entry(at: 5)
    let tieA = entry(at: 3, key: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    let tieB = entry(at: 3, key: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
    var deck = ApprovalPeekDeck()
    deck.update([late, tieB, early, tieA])
    #expect(deck.visible.map(\.key) == [early.key, tieA.key, tieB.key, late.key])
    #expect(deck.shown?.key == early.key)
}

@Test("ApprovalPeekDeck: position, and next and previous clamp at the ends")
func approvalPeekDeckPosition() {
    let entries = [entry(at: 1), entry(at: 2), entry(at: 3)]
    var deck = ApprovalPeekDeck()
    deck.update(entries)
    #expect(deck.positionText == "1 of 3")
    #expect(!deck.hasPrevious && deck.hasNext)
    deck.previous()
    #expect(deck.shown?.key == entries[0].key)
    deck.next()
    deck.next()
    deck.next()
    #expect(deck.shown?.key == entries[2].key)
    #expect(deck.positionText == "3 of 3")
    #expect(deck.hasPrevious && !deck.hasNext)
    deck.previous()
    #expect(deck.positionText == "2 of 3")

    var single = ApprovalPeekDeck()
    single.update([entries[0]])
    #expect(single.positionText == nil)
}

@Test("ApprovalPeekDeck: the shown card falls back to the oldest when the selected one closes")
func approvalPeekDeckSelectedCloses() {
    let entries = [entry(at: 1), entry(at: 2), entry(at: 3)]
    var deck = ApprovalPeekDeck()
    deck.update(entries)
    deck.next()
    deck.next()
    #expect(deck.shown?.key == entries[2].key)
    deck.update(Array(entries.prefix(2)))
    #expect(deck.selectedKey == nil)
    #expect(deck.shown?.key == entries[0].key)
}

@Test("ApprovalPeekDeck: hideAll hides the stack; a new request shows the peek again")
func approvalPeekDeckHideAll() {
    let first = entry(at: 1)
    let second = entry(at: 2)
    var deck = ApprovalPeekDeck()
    deck.update([first, second])
    deck.hideAll()
    #expect(deck.visible.isEmpty)
    #expect(deck.shown == nil)
    let third = entry(at: 3)
    deck.update([first, second, third])
    #expect(deck.visible.map(\.key) == [third.key])
    // A closed request that leaves the store is forgotten.
    deck.update([third])
    #expect(deck.hiddenKeys.isEmpty)
}

@Test("ApprovalPeekDeck: an answered card leaves; a choice from any surface does too")
func approvalPeekDeckAnswered() {
    let first = entry(at: 1)
    let second = entry(at: 2)
    let third = entry(at: 3)
    var deck = ApprovalPeekDeck()
    deck.update([first, second, third])
    deck.markAnswered(first.key)
    #expect(deck.shown?.key == second.key)
    deck.update([first, second, third], chosenKeys: [second.key])
    #expect(deck.visible.map(\.key) == [third.key])
    deck.update([third])
    #expect(deck.answeredKeys.isEmpty)
}

@Test("ApprovalPeekDeck: at most two blank cards show behind the top card")
func approvalPeekDeckStackDepth() {
    var deck = ApprovalPeekDeck()
    #expect(deck.stackDepth == 0)
    deck.update([entry(at: 1)])
    #expect(deck.stackDepth == 0)
    deck.update([entry(at: 1), entry(at: 2)])
    #expect(deck.stackDepth == 1)
    deck.update((1...5).map { entry(at: TimeInterval($0)) })
    #expect(deck.stackDepth == 2)
}

// MARK: - Fit

@Test("ApprovalPeekFit: columns count ASCII 1, a tab 8, any other scalar 2")
func approvalPeekFitColumns() {
    #expect(ApprovalPeekFit.columns("abc") == 3)
    #expect(ApprovalPeekFit.columns("\t") == 8)
    #expect(ApprovalPeekFit.columns("日本") == 4)
    #expect(ApprovalPeekFit.wrappedLines(String(repeating: "a", count: 44)) == 1)
    #expect(ApprovalPeekFit.wrappedLines(String(repeating: "a", count: 45)) == 2)
    #expect(ApprovalPeekFit.wrappedLines(String(repeating: "日", count: 22)) == 1)
    #expect(ApprovalPeekFit.wrappedLines(String(repeating: "日", count: 23)) == 2)
    #expect(ApprovalPeekFit.wrappedLines("") == 1)
    #expect(ApprovalPeekFit.wrappedLines("a\nb") == 2)
    #expect(ApprovalPeekFit.wrappedLines("a\r\nb") == 2)
}

@Test("ApprovalPeekFit: a 4-line command fits and a 5-line command does not")
func approvalPeekFitCommandLines() {
    #expect(ApprovalPeekFit.commandFits("a\nb\nc\nd"))
    #expect(!ApprovalPeekFit.commandFits("a\nb\nc\nd\ne"))
    #expect(ApprovalPeekFit.commandFits(String(repeating: "a", count: 44 * 4)))
    #expect(!ApprovalPeekFit.commandFits(String(repeating: "a", count: 44 * 4 + 1)))
}

@Test("ApprovalPeekFit: the folder limit is 88 columns; permission lines total 4")
func approvalPeekFitFolderAndPermissions() {
    #expect(ApprovalPeekFit.folderFits(String(repeating: "a", count: 88)))
    #expect(!ApprovalPeekFit.folderFits(String(repeating: "a", count: 89)))
    #expect(ApprovalPeekFit.permissionsFit(["a", "b", "c", "d"]))
    #expect(!ApprovalPeekFit.permissionsFit(["a", "b", "c", "d", "e"]))
    #expect(!ApprovalPeekFit.permissionsFit([String(repeating: "a", count: 45), "b", "c", "d"]))
    let long = CanvasAgentRequest(
        kind: .command, command: "ls", cwd: "/" + String(repeating: "a", count: 90))
    #expect(!ApprovalPeekFit.fits(long))
    #expect(ApprovalPeekFit.fits(CanvasAgentRequest(kind: .command, command: "ls", cwd: "/tmp")))
}

// MARK: - Content

@Test("ApprovalPeekContent: a short command gives Allow, Deny and the menu")
func approvalPeekContentAnswer() {
    let request = CanvasAgentRequest(kind: .command, command: "npm test", cwd: "/tmp")
    let content = ApprovalPeekContent.resolve(request: request, decision: nil, oversize: false)
    guard case .answer(let actions) = content else {
        Issue.record("Expected an answer card")
        return
    }
    #expect(actions.primary?.decision == .accept)
    #expect(actions.deny?.decision == .decline)
    #expect(content.allowsSwipeRight && content.allowsSwipeLeft)
}

@Test("ApprovalPeekContent: a terminal-only request shows Open terminal only")
func approvalPeekContentTerminalOnly() {
    let change = CanvasAgentRequest(kind: .fileChange, grantRoot: "/tmp")
    let content = ApprovalPeekContent.resolve(request: change, decision: nil, oversize: false)
    #expect(content == .terminalOnly)
    #expect(!content.allowsSwipeRight && !content.allowsSwipeLeft)
}

@Test("ApprovalPeekContent: a long command or an oversize card gives Review, with no accept")
func approvalPeekContentReview() {
    let long = CanvasAgentRequest(
        kind: .command, command: (1...6).map { "echo \($0)" }.joined(separator: "\n"))
    for (request, oversize) in [
        (long, false), (CanvasAgentRequest(kind: .command, command: "ls"), true),
    ] {
        let content = ApprovalPeekContent.resolve(
            request: request, decision: nil, oversize: oversize)
        guard case .review(let actions) = content else {
            Issue.record("Expected a review card")
            continue
        }
        #expect(actions.primary == nil)
        #expect(actions.deny?.decision == .decline)
        #expect(!actions.overflow.contains { $0.decision == .acceptForSession })
        #expect(actions.overflow.map(\.decision) == [.cancel])
        #expect(!content.allowsSwipeRight)
        #expect(content.allowsSwipeLeft)
    }
}

@Test("ApprovalPeekContent: one question with 4 short choices gives choice buttons")
func approvalPeekContentChoices() {
    let short = question(choices: ["Indigo", "Khadi", "Both", "None"])
    let request = CanvasAgentRequest(kind: .userInput, questions: [short])
    #expect(
        ApprovalPeekContent.resolve(request: request, decision: nil, oversize: false)
            == .choices(short))
}

@Test("ApprovalPeekContent: 5 choices, 2 questions or long text give Answer in Up next")
func approvalPeekContentAnswerInUpNext() {
    let five = question(choices: ["a", "b", "c", "d", "e"])
    let wide = question(choices: [
        String(repeating: "a", count: 30), String(repeating: "b", count: 15),
    ])
    let long = question(choices: ["a"], text: String(repeating: "x", count: 121))
    let second = CanvasAgentRequest.Question(
        id: "q2", header: "", text: "Sure?", choices: [.init(label: "Yes", detail: "")])
    let requests = [
        CanvasAgentRequest(kind: .userInput, questions: [five]),
        CanvasAgentRequest(kind: .userInput, questions: [wide]),
        CanvasAgentRequest(kind: .userInput, questions: [long]),
        CanvasAgentRequest(kind: .userInput, questions: [question(choices: ["a"]), second]),
    ]
    for request in requests {
        #expect(
            ApprovalPeekContent.resolve(request: request, decision: nil, oversize: false)
                == .answerInUpNext)
    }
}

@Test("ApprovalPeekContent: a chosen answer shows the sending state")
func approvalPeekContentSending() {
    let request = CanvasAgentRequest(kind: .command, command: "ls")
    #expect(
        ApprovalPeekContent.resolve(request: request, decision: .accept, oversize: false)
            == .sending)
}

// MARK: - Swipe

@Test("ApprovalSwipePolicy: 119 pt cancels, 120 pt commits, blocked directions cancel")
func approvalSwipeOutcome() {
    #expect(
        ApprovalSwipePolicy.outcome(translation: 119, allowsRight: true, allowsLeft: true)
            == .cancel)
    #expect(
        ApprovalSwipePolicy.outcome(translation: 120, allowsRight: true, allowsLeft: true)
            == .allow)
    #expect(
        ApprovalSwipePolicy.outcome(translation: -120, allowsRight: true, allowsLeft: true)
            == .deny)
    #expect(
        ApprovalSwipePolicy.outcome(translation: -119.5, allowsRight: true, allowsLeft: true)
            == .cancel)
    #expect(
        ApprovalSwipePolicy.outcome(translation: 400, allowsRight: false, allowsLeft: true)
            == .cancel)
    #expect(
        ApprovalSwipePolicy.outcome(translation: -400, allowsRight: true, allowsLeft: false)
            == .cancel)
}

@Test("ApprovalSwipePolicy: the tilt clamps at 8 degrees and the tint grows to 0.35")
func approvalSwipeTiltAndTint() {
    #expect(ApprovalSwipePolicy.tilt(60) == 4)
    #expect(ApprovalSwipePolicy.tilt(300) == 8)
    #expect(ApprovalSwipePolicy.tilt(-300) == -8)
    #expect(ApprovalSwipePolicy.tintOpacity(0) == 0)
    #expect(ApprovalSwipePolicy.tintOpacity(60) == 0.175)
    #expect(ApprovalSwipePolicy.tintOpacity(-500) == 0.35)
}

@Test("ApprovalSwipePolicy: a blocked direction rubber-bands below 24 pt and shows no label")
func approvalSwipeRubberBand() {
    let blocked = ApprovalSwipePolicy.offset(translation: 500, allowsRight: false, allowsLeft: true)
    #expect(blocked > 0 && blocked < ApprovalSwipePolicy.blockedDirectionLimit)
    #expect(
        ApprovalSwipePolicy.offset(translation: -80, allowsRight: false, allowsLeft: true) == -80)
    #expect(
        !ApprovalSwipePolicy.showsLabel(offset: blocked, allowsRight: false, allowsLeft: true))
    #expect(ApprovalSwipePolicy.showsLabel(offset: -24, allowsRight: false, allowsLeft: true))
    #expect(!ApprovalSwipePolicy.showsLabel(offset: -23, allowsRight: true, allowsLeft: true))
}

// MARK: - Geometry

@Test("ApprovalPeekGeometry: the card hangs 6 pt below a notch, an island pill and a status item")
func approvalPeekGeometryAnchors() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 953)
    let size = CGSize(width: 360, height: 150)
    let anchors = [
        CGRect(x: 663.5, y: 953, width: 185, height: 33),  // notch
        CGRect(x: 696, y: 920, width: 120, height: 26),  // island pill
        CGRect(x: 1440, y: 953, width: 40, height: 24),  // status item near the right edge
    ]
    for anchor in anchors {
        let card = ApprovalPeekGeometry.cardFrame(
            anchor: anchor, cardSize: size, visibleFrame: visible)
        #expect(card.maxY == anchor.minY - 6)
        #expect(card.size == size)
        #expect(card.minX >= visible.minX + 8 && card.maxX <= visible.maxX - 8)
    }
    let centred = ApprovalPeekGeometry.cardFrame(
        anchor: anchors[0], cardSize: size, visibleFrame: visible)
    #expect(centred.midX == anchors[0].midX)
    let clamped = ApprovalPeekGeometry.cardFrame(
        anchor: anchors[2], cardSize: size, visibleFrame: visible)
    #expect(clamped.maxX == visible.maxX - 8)
    let fallback = ApprovalPeekGeometry.fallbackAnchor(visibleFrame: visible)
    #expect(fallback.midX == visible.midX && fallback.minY == visible.maxY)
}

@Test("ApprovalPeekGeometry: the window adds side gutters, which pass clicks through")
func approvalPeekGeometryPanel() {
    let card = CGRect(x: 500, y: 700, width: 360, height: 150)
    let panel = ApprovalPeekGeometry.panelFrame(card: card)
    #expect(panel == CGRect(x: 360, y: 684, width: 640, height: 166))
    let regions = ApprovalPeekGeometry.clickThroughRegions(panel: panel, card: card)
    #expect(regions.contains(CGRect(x: 360, y: 684, width: 140, height: 166)))
    #expect(regions.contains(CGRect(x: 860, y: 684, width: 140, height: 166)))
    #expect(!regions.contains { $0.contains(CGPoint(x: card.midX, y: card.midY)) })
}

// MARK: - Text

@Test("ApprovalPeekText: the announcement names the agent and the request")
func approvalPeekAnnouncement() {
    #expect(
        ApprovalPeekText.announcement(for: entry("npm test")) == "Codex needs approval: npm test")
    let permissions = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(kind: .permissions, permissions: ["Network access"]))
    #expect(
        ApprovalPeekText.announcement(for: permissions)
            == "Codex needs approval: Grant permissions")
    let change = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(kind: .fileChange, grantRoot: "/tmp"))
    #expect(
        ApprovalPeekText.announcement(for: change)
            == "Codex needs approval: Apply file changes. Open the terminal to answer.")
    let ask = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(kind: .userInput, questions: [question(choices: ["a"])]))
    #expect(ApprovalPeekText.announcement(for: ask) == "Codex asks: Which theme?")
}
