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

@Test("ApprovalPeekFit: a 10-line command fits and an 11-line command does not")
func approvalPeekFitCommandLines() {
    #expect(ApprovalPeekFit.commandFits("a\nb\nc\nd\ne\nf\ng\nh\ni\nj"))
    #expect(!ApprovalPeekFit.commandFits("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk"))
    #expect(ApprovalPeekFit.commandFits(String(repeating: "a", count: 44 * 10)))
    #expect(!ApprovalPeekFit.commandFits(String(repeating: "a", count: 44 * 10 + 1)))
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

private func lines(_ count: Int) -> String {
    (1...count).map { "echo \($0)" }.joined(separator: "\n")
}

@Test("ApprovalPeekContent: a command of ten lines fits, with Allow active")
func aCommandOfTenLinesFits() {
    let request = CanvasAgentRequest(kind: .command, command: lines(10))
    #expect(ApprovalPeekFit.fits(request))
    guard
        case .answer(let actions) = ApprovalPeekContent.resolve(
            request: request, decision: nil, oversize: false)
    else {
        Issue.record("Expected an answer card")
        return
    }
    #expect(actions.primary?.decision == .accept)
    // A command of about 190 characters wraps to 5 lines and fits.
    let chained = CanvasAgentRequest(
        kind: .command, command: String(repeating: "cat a && ", count: 20) + "echo done")
    #expect(ApprovalPeekFit.fits(chained))
}

@Test("ApprovalPeekContent: a command of eleven lines needs Show all, with no accept")
func aCommandOfElevenLinesNeedsExpand() {
    let long = CanvasAgentRequest(kind: .command, command: lines(11))
    for (request, oversize) in [
        (long, false), (CanvasAgentRequest(kind: .command, command: "ls"), true),
    ] {
        let content = ApprovalPeekContent.resolve(
            request: request, decision: nil, oversize: oversize)
        guard case .needsExpand(let actions) = content else {
            Issue.record("Expected a Show all card")
            continue
        }
        #expect(actions.primary == nil)
        #expect(actions.deny?.decision == .decline)
        #expect(!actions.overflow.contains { $0.decision == .acceptForSession })
        #expect(actions.overflow.map(\.decision) == [.cancel])
    }
}

@Test("ApprovalPeekContent: the expanded card offers Allow")
func theExpandedCardOffersAllow() {
    let long = CanvasAgentRequest(kind: .command, command: lines(11))
    guard
        case .expanded(let actions) = ApprovalPeekContent.resolve(
            request: long, decision: nil, oversize: false, isExpanded: true)
    else {
        Issue.record("Expected an expanded card")
        return
    }
    #expect(actions.primary?.decision == .accept)
    #expect(actions.deny?.decision == .decline)
    // A request that fits is never changed by the expand flag.
    let short = CanvasAgentRequest(kind: .command, command: "ls")
    guard
        case .answer = ApprovalPeekContent.resolve(
            request: short, decision: nil, oversize: false, isExpanded: true)
    else {
        Issue.record("Expected an answer card")
        return
    }
}

@Test("ApprovalPeekContent: the collapsed card blocks a right swipe")
func theCollapsedCardBlocksARightSwipe() {
    let long = CanvasAgentRequest(kind: .command, command: lines(11))
    let content = ApprovalPeekContent.resolve(request: long, decision: nil, oversize: false)
    #expect(!content.allowsSwipeRight)
}

@Test("ApprovalPeekContent: the expanded card allows a right swipe")
func theExpandedCardAllowsARightSwipe() {
    let long = CanvasAgentRequest(kind: .command, command: lines(11))
    let content = ApprovalPeekContent.resolve(
        request: long, decision: nil, oversize: false, isExpanded: true)
    #expect(content.allowsSwipeRight)
    #expect(content.allowsSwipeLeft)
}

@Test("ApprovalPeekContent: a collapsed card still allows Deny")
func aCollapsedCardStillAllowsDeny() {
    let long = CanvasAgentRequest(kind: .command, command: lines(11))
    let content = ApprovalPeekContent.resolve(request: long, decision: nil, oversize: false)
    #expect(content.allowsSwipeLeft)
}

@Test("ApprovalPeekGeometry: the height cap follows the screen")
func theHeightCapFollowsTheScreen() {
    func cap(_ height: CGFloat) -> CGFloat {
        ApprovalPeekGeometry.maxCardHeight(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: height))
    }
    #expect(cap(400) == 260)
    #expect(cap(800) == 360)
    #expect(cap(2_000) == 420)
    #expect(ApprovalPeekGeometry.defaultMaxCardHeight == 260)
    // The expanded box never passes its own bound or the screen.
    #expect(ApprovalPeekGeometry.expandedBoxHeight(lines: 100) == 220)
    #expect(ApprovalPeekGeometry.expandedBoxHeight(lines: 11) == 166)
    let small = CGRect(x: 0, y: 0, width: 1_000, height: 300)
    #expect(
        ApprovalPeekGeometry.expandedBoxHeight(lines: 100, visibleFrame: small, reserved: 150)
            == 134)
}

private func fileChangeRequest(
    body: String = "let a = 1", kind: CanvasAgentRequest.FileChange.Kind = .overwrite,
    isDiff: Bool = false
) -> CanvasAgentRequest {
    CanvasAgentRequest(
        kind: .fileChange,
        fileChanges: [.init(path: "/repo/a.swift", kind: kind, body: body, isDiff: isDiff)],
        offersSessionAllow: false)
}

@Test("ApprovalPeekContent: a small file change shows its content and Allow")
func aSmallFileChangeIsAnswerable() {
    let request = fileChangeRequest()
    #expect(ApprovalPeekText.boxText(request) == "Write /repo/a.swift\nlet a = 1")
    guard
        case .answer(let actions) = ApprovalPeekContent.resolve(
            request: request, decision: nil, oversize: false)
    else {
        Issue.record("Expected an answer card")
        return
    }
    #expect(actions.primary?.decision == .accept)
    #expect(actions.primaryLabel == "Allow")
    // A big one needs Show all first.
    let big = fileChangeRequest(body: lines(11))
    #expect(
        {
            if case .needsExpand = ApprovalPeekContent.resolve(
                request: big, decision: nil, oversize: false)
            {
                return true
            }
            return false
        }())
}

@Test("ApprovalPeekText: the file change announcement names the path")
func theFileChangeAnnouncementNamesThePath() {
    let request = fileChangeRequest()
    let entry = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .claudeCode, request: request)
    #expect(
        ApprovalPeekText.announcement(for: entry)
            == "Claude Code needs approval: Apply file changes to /repo/a.swift")
    #expect(
        ApprovalPeekText.spokenBox(agent: "Claude Code", request: request)
            == "Claude Code asks to write /repo/a.swift. New content: let a = 1")
    let diff = fileChangeRequest(body: "- a\n+ b", kind: .edit, isDiff: true)
    #expect(
        ApprovalPeekText.spokenBox(agent: "Claude Code", request: diff)
            == "Claude Code asks to change /repo/a.swift. Diff: - a\n+ b")
}

@Test("ApprovalPeekContent: one question with 4 short choices gives choice buttons")
func approvalPeekContentChoices() {
    let short = question(choices: ["Indigo", "Khadi", "Both", "None"])
    let request = CanvasAgentRequest(kind: .userInput, questions: [short])
    #expect(
        ApprovalPeekContent.resolve(request: request, decision: nil, oversize: false)
            == .choices(short))
}

@Test("ApprovalPeekContent: 5 choices, 2 questions or long text give the collapsed question set")
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
                == .questionsCollapsed)
    }
}

@Test("ApprovalPeekContent: a multiple-choice question is never one-click buttons")
func approvalPeekContentMultipleChoiceCollapses() {
    let multi = CanvasAgentRequest.Question(
        id: "q", header: "", text: "Which?",
        choices: [.init(label: "a", detail: ""), .init(label: "b", detail: "")],
        allowsMultiple: true)
    let request = CanvasAgentRequest(kind: .userInput, questions: [multi])
    #expect(
        ApprovalPeekContent.resolve(request: request, decision: nil, oversize: false)
            == .questionsCollapsed)
}

@Test("ApprovalPeekContent: only a click on Answer or Other expands the question set")
func approvalPeekContentQuestionSetNeedsAClick() {
    let short = question(choices: ["Indigo", "Khadi"])
    let second = CanvasAgentRequest.Question(
        id: "q2", header: "", text: "Sure?", choices: [.init(label: "Yes", detail: "")])
    for request in [
        CanvasAgentRequest(kind: .userInput, questions: [short]),
        CanvasAgentRequest(kind: .userInput, questions: [short, second]),
    ] {
        #expect(
            ApprovalPeekContent.resolve(
                request: request, decision: nil, oversize: false, isExpanded: true)
                == .questionSet)
        // A question set offers no swipe: the answer is the choice.
        #expect(!ApprovalPeekContent.questionSet.allowsSwipeRight)
        #expect(!ApprovalPeekContent.questionSet.allowsSwipeLeft)
        #expect(
            ApprovalPeekContent.resolve(
                request: request, decision: .answers(labels: ["q": "Indigo"]), oversize: false,
                isExpanded: true) == .sending)
    }
}

@Test("ApprovalPeekContent: a plan, a notice and a terminal-only question show Open terminal")
func approvalPeekContentShownOnlyKinds() {
    let requests = [
        CanvasAgentRequest(kind: .plan, reason: "/repo/plan.md", text: "1. Do it"),
        CanvasAgentRequest(kind: .notice, reason: "Network request", text: "curl example.com"),
        CanvasAgentRequest(
            kind: .userInput, questions: [question(choices: ["a"])], terminalOnly: true),
    ]
    for request in requests {
        #expect(
            ApprovalPeekContent.resolve(
                request: request, decision: nil, oversize: false, isExpanded: true)
                == .terminalOnly)
    }
}

@Test("ApprovalPeekGeometry: the question choice list caps at 220 pt and follows the screen")
func questionChoicesHeightFollowsTheScreen() {
    #expect(ApprovalPeekGeometry.questionChoicesHeight(visibleFrame: nil) == 220)
    #expect(
        ApprovalPeekGeometry.questionChoicesHeight(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)) == 220)
    // 400 - 16 - 230 = 154.
    #expect(
        ApprovalPeekGeometry.questionChoicesHeight(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 400)) == 154)
    #expect(
        ApprovalPeekGeometry.questionChoicesHeight(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 200)) == 80)
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
    let set = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .claudeCode,
        request: CanvasAgentRequest(
            kind: .userInput,
            questions: [
                question(choices: ["a"]),
                .init(
                    id: "q2", header: "", text: "Sure?", choices: [.init(label: "Yes", detail: "")]
                ),
            ]))
    #expect(ApprovalPeekText.announcement(for: set) == "Claude Code asks 2 questions: Which theme?")
    let plan = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .claudeCode,
        request: CanvasAgentRequest(kind: .plan, reason: "/repo/plan.md", text: "1. Do it"))
    #expect(
        ApprovalPeekText.announcement(for: plan)
            == "Claude Code has a plan ready. Open the terminal to answer.")
    let notice = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(kind: .notice, reason: "Network request\nmore", text: "x"))
    #expect(
        ApprovalPeekText.announcement(for: notice)
            == "Codex needs you: Network request. Open the terminal to answer.")
    // A Codex notice reason already says where to answer: not said twice.
    let codexNotice = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(
            kind: .notice,
            reason: "Codex asks you to sign in with a browser. Open the terminal to answer.",
            text: "Sign in to GitHub"))
    #expect(
        ApprovalPeekText.announcement(for: codexNotice)
            == "Codex needs you: Codex asks you to sign in with a browser. "
            + "Open the terminal to answer.")
    // A network command approval speaks its target.
    let network = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(
            kind: .command, command: "curl https://example.com",
            permissions: ["Network: https example.com"]))
    #expect(network.request.permissions == ["Network: https example.com"])
    #expect(
        ApprovalPeekText.announcement(for: network)
            == "Codex needs approval: curl https://example.com. Network: https example.com")
    #expect(
        ApprovalPeekText.spokenBox(agent: "Codex", request: network.request)
            == "Codex asks to run curl https://example.com. Network: https example.com")
    let bare = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .codex,
        request: CanvasAgentRequest(kind: .notice))
    #expect(
        ApprovalPeekText.announcement(for: bare)
            == "Codex needs you. Open the terminal to answer.")
}

// MARK: - MCP tool call

private let atlassianName = "mcp__claude_ai_Atlassian_MCP__atlassianUserInfo"

private func toolCallRequest(
    arguments: String = "{}", name: String = atlassianName, terminalOnly: Bool = false
) -> CanvasAgentRequest {
    CanvasAgentRequest(
        kind: .toolCall, command: arguments, cwd: "/repo",
        reason: AgentPermissionRequestSummary.toolReason(name: name), terminalOnly: terminalOnly,
        offersSessionAllow: false)
}

@Test("ApprovalPeekContent: a tool call shows its arguments and Allow, Deny and the menu")
func aToolCallIsAnswerable() {
    let request = toolCallRequest()
    #expect(ApprovalPeekText.boxText(request) == "{}")
    guard
        case .answer(let actions) = ApprovalPeekContent.resolve(
            request: request, decision: nil, oversize: false)
    else {
        Issue.record("Expected an answer card")
        return
    }
    #expect(actions.primary?.decision == .accept)
    #expect(actions.primaryLabel == "Allow")
    #expect(actions.deny?.decision == .decline)
    #expect(actions.overflow.map(\.label) == ["Deny and stop"])
}

@Test("ApprovalPeekContent: tool call arguments of eleven lines need Show all, then Allow")
func longToolCallArgumentsNeedExpand() {
    let long = toolCallRequest(arguments: lines(11))
    #expect(!ApprovalPeekFit.fits(long))
    guard
        case .needsExpand(let collapsed) = ApprovalPeekContent.resolve(
            request: long, decision: nil, oversize: false)
    else {
        Issue.record("Expected a Show all card")
        return
    }
    #expect(collapsed.primary == nil)
    guard
        case .expanded(let expanded) = ApprovalPeekContent.resolve(
            request: long, decision: nil, oversize: false, isExpanded: true)
    else {
        Issue.record("Expected an expanded card")
        return
    }
    #expect(expanded.primary?.decision == .accept)
}

@Test("ApprovalPeekContent: a long tool identity needs Show all")
func aLongToolIdentityNeedsExpand() {
    let name =
        "mcp__" + String(repeating: "s", count: 80) + "__" + String(repeating: "t", count: 110)
    let request = toolCallRequest(name: name)
    #expect(!request.terminalOnly)
    #expect(!ApprovalPeekFit.fits(request))
    #expect(ApprovalPeekFit.fits(toolCallRequest()))
}

@Test("ApprovalPeekContent: a tool call with too long arguments shows Open terminal only")
func aTerminalOnlyToolCallShowsOpenTerminal() {
    let request = toolCallRequest(
        arguments: String(repeating: "a", count: CanvasAgentRequest.Limits.commandBytes + 1))
    #expect(request.terminalOnly)
    let content = ApprovalPeekContent.resolve(request: request, decision: nil, oversize: false)
    #expect(content == .terminalOnly)
    #expect(!content.allowsSwipeRight && !content.allowsSwipeLeft)
}

@Test("ApprovalPeekText: the tool call announcement names the tool and the server")
func theToolCallAnnouncementNamesTheTool() {
    let entry = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .claudeCode, request: toolCallRequest())
    #expect(
        ApprovalPeekText.announcement(for: entry)
            == "Claude Code needs approval: Use tool atlassianUserInfo of Atlassian MCP (claude.ai)"
    )
    let terminal = ApprovalPeekEntry(
        controllerID: UUID(), title: "t", cli: .claudeCode,
        request: toolCallRequest(terminalOnly: true))
    #expect(
        ApprovalPeekText.announcement(for: terminal)
            == "Claude Code needs approval: Use MCP tool. Open the terminal to answer.")
    // It never says that it runs a command.
    let spoken = ApprovalPeekText.spokenBox(
        agent: "Claude Code", request: toolCallRequest(arguments: "{\n  \"a\" : 1\n}"))
    #expect(
        spoken
            == "Claude Code asks to use tool atlassianUserInfo of Atlassian MCP (claude.ai), "
            + "named \(atlassianName), with arguments {\n  \"a\" : 1\n}")
    #expect(spoken?.contains("run") == false)
}
