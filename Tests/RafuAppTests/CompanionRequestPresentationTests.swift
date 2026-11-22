import RafuCore
import Testing

@testable import RafuApp

@Test("CompanionRequestActions: primary, Deny and the menu for each kind of request")
func companionRequestActions() {
    let command = CompanionRequestActions(request: .init(kind: .command, command: "swift test"))
    #expect(command.primary?.decision == .accept)
    #expect(command.primaryLabel == "Allow")
    #expect(command.deny?.decision == .decline)
    #expect(command.overflow.map(\.decision) == [.acceptForSession, .cancel])
    #expect(command.overflow.map(\.label) == ["Allow for this session", "Deny and stop"])

    // A Claude Code request answered through its hook has no session answer.
    let claude = CompanionRequestActions(
        request: .init(kind: .command, command: "swift test", offersSessionAllow: false))
    #expect(claude.overflow.map(\.decision) == [.cancel])

    let checkpoint = CompanionRequestActions(
        request: .init(kind: .command, isHumanCheckpoint: true, command: "swift test"))
    #expect(checkpoint.primaryLabel == "Allow")
    #expect(checkpoint.overflow.map(\.decision) == [.cancel])

    let permissions = CompanionRequestActions(
        request: .init(kind: .permissions, permissions: ["Network access"]))
    #expect(permissions.primaryLabel == "Allow for this turn")
    #expect(permissions.overflow.map(\.decision) == [.acceptForSession])
    #expect(permissions.withoutAccept.primary == nil)
    #expect(permissions.withoutAccept.overflow.isEmpty)

    let change = CompanionRequestActions(request: .init(kind: .fileChange, grantRoot: "/tmp"))
    #expect(change.primary == nil && change.deny == nil && change.overflow.isEmpty)
}

@MainActor
@Test func companionRequestButtons() {
    let requests: [CanvasAgentRequest] = [
        .init(kind: .command, command: "swift test"),
        .init(kind: .command, isHumanCheckpoint: true, command: "swift test"),
        .init(kind: .permissions, permissions: ["Network access"]),
    ]
    let expected: [[CanvasAgentRequestDecision]] = [
        [.accept, .acceptForSession, .decline, .cancel], [.accept, .decline, .cancel],
        [.accept, .acceptForSession, .decline],
    ]
    for (request, decisions) in zip(requests, expected) {
        let model = CompanionRequestPresentation(request: request, decision: nil)
        guard case .options(let options) = model.controls else {
            Issue.record("Missing approval buttons")
            continue
        }
        #expect(options.map(\.decision) == decisions)
        #expect(
            CompanionRequestPresentation(request: request, decision: .accept).controls == .sending)
    }
}

@MainActor
@Test func companionRequestQuestionsAndFallback() {
    let question = CanvasAgentRequest.Question(
        id: "theme", header: "Theme", text: "Which theme?",
        choices: [.init(label: "Indigo", detail: "")])
    let request = CanvasAgentRequest(kind: .userInput, questions: [question])
    #expect(
        CompanionRequestPresentation(request: request, decision: nil).controls
            == .questions([question]))
    let restricted = CanvasAgentRequest(kind: .userInput, questions: [question], terminalOnly: true)
    // Shown, not answerable: the row says what the agent asks.
    #expect(
        CompanionRequestPresentation(request: restricted, decision: nil).controls
            == .readOnlyQuestions([question]))
    // A file change shows only "Open terminal": the row cannot show the change.
    let change = CanvasAgentRequest(kind: .fileChange, grantRoot: "/tmp/test")
    #expect(CompanionRequestPresentation(request: change, decision: nil).controls == .terminal)
    #expect(
        CompanionRequestPresentation.message(for: .stale) == "This request was already answered.")
    #expect(CompanionRequestPresentation.message(for: .alreadyChosen) == nil)
}

@MainActor
@Test func companionToolCallPresentation() {
    let request = CanvasAgentRequest(
        kind: .toolCall, command: "{}",
        reason: AgentPermissionRequestSummary.toolReason(name: "mcp__github__search"),
        offersSessionAllow: false)
    let model = CompanionRequestPresentation(request: request, decision: nil)
    #expect(model.title == "Use MCP tool")
    guard case .options(let options) = model.controls else {
        Issue.record("Missing approval buttons")
        return
    }
    #expect(options.map(\.decision) == [.accept, .decline, .cancel])
    #expect(options.map(\.label) == ["Allow", "Deny", "Deny and stop"])
    let actions = CompanionRequestActions(request: request)
    #expect(actions.primaryLabel == "Allow")
    #expect(actions.overflow.map(\.decision) == [.cancel])
    #expect(
        CompanionRequestPresentation(request: request, decision: .accept).controls == .sending)
    let restricted = CanvasAgentRequest(kind: .toolCall, command: "{}", reason: nil)
    #expect(CompanionRequestPresentation(request: restricted, decision: nil).controls == .terminal)
}

// MARK: - Titles, plans and notices

@MainActor
@Test("CompanionRequestPresentation: final titles; a plan and a notice show Open terminal")
func companionRequestTitlesAndShownOnlyKinds() {
    let one = CanvasAgentRequest.Question(
        id: "a", header: "", text: "A?", choices: [.init(label: "Yes", detail: "")])
    let two = CanvasAgentRequest.Question(
        id: "b", header: "", text: "B?", choices: [.init(label: "No", detail: "")])
    #expect(
        CompanionRequestPresentation.title(for: .init(kind: .userInput, questions: [one]))
            == "Answer a question")
    #expect(
        CompanionRequestPresentation.title(for: .init(kind: .userInput, questions: [one, two]))
            == "Answer questions")
    let plan = CanvasAgentRequest(kind: .plan, reason: "/repo/plan.md", text: "1. Do it")
    #expect(CompanionRequestPresentation(request: plan, decision: nil).title == "Plan ready")
    #expect(CompanionRequestPresentation(request: plan, decision: nil).controls == .terminal)
    let notice = CanvasAgentRequest(
        kind: .notice, reason: "Network request\nClaude Code", text: "curl example.com")
    #expect(CompanionRequestPresentation(request: notice, decision: nil).title == "Network request")
    #expect(CompanionRequestPresentation(request: notice, decision: nil).controls == .terminal)
    // Never the bare placeholder: a notice with no kind still says where to answer.
    #expect(
        CompanionRequestPresentation.title(for: .init(kind: .notice, reason: " "))
            == "Prompt in the terminal")
    #expect(CompanionRequestPresentation.noticeKind(plan) == nil)
}

@MainActor
@Test("CompanionRequestActions: a Codex tool call cancels the call, not the turn")
func companionToolCallCancelLabel() {
    let request = CanvasAgentRequest(
        kind: .toolCall, command: "{}",
        reason: AgentPermissionRequestSummary.toolReason(name: "mcp__github__search"),
        stopsTurnOnCancel: false, offersSessionAllow: false)
    let actions = CompanionRequestActions(request: request)
    #expect(actions.overflow.map(\.label) == ["Cancel tool call"])
}

@MainActor
@Test("CompanionRequestActions: remember choices show only when the policy allows them")
func companionRememberChoices() {
    let request = CanvasAgentRequest(
        kind: .toolCall, command: "{}",
        reason: AgentPermissionRequestSummary.toolReason(name: "mcp__github__search"),
        persistChoices: [
            .init(kind: .session, line: "Allow search for this session"),
            .init(kind: .always, line: "Always allow search for Codex"),
        ],
        stopsTurnOnCancel: false, offersSessionAllow: false)
    // The app's policy offers no remember choice.
    #expect(!CanvasAgentRequest.PersistPolicy.current.allowsSession)
    #expect(!CanvasAgentRequest.PersistPolicy.current.allowsLasting)
    let current = CompanionRequestActions(request: request)
    #expect(current.overflow.map(\.decision) == [.cancel])
    // With every choice on, they go to the menu, never the primary button.
    let all = CompanionRequestActions(request: request, policy: .all)
    #expect(all.primary?.decision == .accept)
    #expect(
        all.overflow.map(\.decision) == [
            .acceptAndRemember(.session), .acceptAndRemember(.always), .cancel,
        ])
    #expect(
        all.overflow.map(\.label) == [
            "Allow search for this session", "Always allow search for Codex", "Cancel tool call",
        ])
    // A card that cannot show the whole request offers no accept of any kind.
    #expect(all.withoutAccept.overflow.map(\.decision) == [.cancel])
}

// MARK: - Question set state

private func single(free: Bool = false) -> CanvasAgentRequest.Question {
    .init(
        id: "theme", header: "Theme", text: "Which theme?",
        choices: [.init(label: "Indigo", detail: "Dark"), .init(label: "Khadi", detail: "Light")],
        allowsFreeText: free)
}

private func multiple(free: Bool = false) -> CanvasAgentRequest.Question {
    .init(
        id: "parts", header: "Parts", text: "Which parts?",
        choices: [
            .init(label: "Editor", detail: ""), .init(label: "Search", detail: ""),
            .init(label: "Git", detail: ""),
        ],
        allowsMultiple: true, allowsFreeText: free)
}

@Test("CompanionQuestionSetState: a single-choice question keeps one label")
func questionSetSingleChoice() {
    let question = single()
    let request = CanvasAgentRequest(kind: .userInput, questions: [question])
    var state = CompanionQuestionSetState()
    #expect(state.answer(for: question) == nil)
    #expect(!state.canAnswer(request))
    state.toggle("Indigo", in: question)
    state.toggle("Khadi", in: question)
    #expect(state.answer(for: question) == QuestionAnswer(labels: ["Khadi"]))
    #expect(state.isChosen("Khadi", in: question) && !state.isChosen("Indigo", in: question))
    #expect(state.canAnswer(request))
    #expect(state.decision(for: request) == .answers(["theme": "Khadi"]))
    // A label that is not a choice changes nothing.
    state.toggle("Other", in: question)
    #expect(state.answer(for: question) == QuestionAnswer(labels: ["Khadi"]))
    // No free text: typing is ignored.
    state.setText("mine", for: question)
    #expect(state.text(for: question).isEmpty)
}

@Test("CompanionQuestionSetState: typed text replaces the label of a single-choice question")
func questionSetSingleChoiceFreeText() {
    let question = single(free: true)
    let request = CanvasAgentRequest(kind: .userInput, questions: [question])
    var state = CompanionQuestionSetState()
    state.toggle("Indigo", in: question)
    state.setText("  Solarized ", for: question)
    #expect(state.isOtherChosen(question))
    #expect(!state.isChosen("Indigo", in: question))
    // Leading and trailing spaces do not go out.
    #expect(state.answer(for: question) == QuestionAnswer(text: "Solarized"))
    #expect(state.canAnswer(request))
    // Choosing a label again drops the text from the answer; the field keeps it.
    state.toggle("Khadi", in: question)
    #expect(state.answer(for: question) == QuestionAnswer(labels: ["Khadi"]))
    #expect(state.text(for: question) == "  Solarized ")
    state.toggleOther(in: question)
    #expect(state.answer(for: question) == QuestionAnswer(text: "Solarized"))
    // Blank text is no answer.
    state.setText("   ", for: question)
    #expect(state.answer(for: question) == nil)
    #expect(!state.canAnswer(request))
}

@Test("CompanionQuestionSetState: a multiple-choice question takes labels, text, or both")
func questionSetMultipleChoice() {
    let question = multiple(free: true)
    let request = CanvasAgentRequest(kind: .userInput, questions: [question])
    var state = CompanionQuestionSetState()
    state.toggle("Git", in: question)
    state.toggle("Editor", in: question)
    // Labels go out in choice order, not click order.
    #expect(state.answer(for: question) == QuestionAnswer(labels: ["Editor", "Git"]))
    state.setText("Terminal", for: question)
    #expect(
        state.answer(for: question) == QuestionAnswer(labels: ["Editor", "Git"], text: "Terminal"))
    #expect(state.canAnswer(request))
    state.toggle("Git", in: question)
    state.toggle("Editor", in: question)
    #expect(state.answer(for: question) == QuestionAnswer(text: "Terminal"))
    state.toggleOther(in: question)
    #expect(state.answer(for: question) == nil)
    #expect(!state.canAnswer(request))
}

@Test("CompanionQuestionSetState: Answer needs every question; pages clamp")
func questionSetPages() {
    let first = single()
    let second = multiple()
    let request = CanvasAgentRequest(kind: .userInput, questions: [first, second])
    var state = CompanionQuestionSetState()
    #expect(state.pageTitle(count: 2) == "Question 1 of 2")
    #expect(state.pageTitle(count: 1) == nil)
    #expect(!state.isLastPage(count: 2))
    state.back()
    #expect(state.page == 0)
    state.toggle("Indigo", in: first)
    #expect(state.isAnswered(first) && !state.isAnswered(second))
    #expect(!state.canAnswer(request))
    state.next(count: 2)
    state.next(count: 2)
    #expect(state.page == 1 && state.isLastPage(count: 2))
    #expect(state.pageTitle(count: 2) == "Question 2 of 2")
    state.toggle("Search", in: second)
    #expect(state.canAnswer(request))
    #expect(
        state.decision(for: request)
            == .answers(["theme": "Indigo", "parts": QuestionAnswer(labels: ["Search"])]))
    // A terminal-only request is never answerable from the set.
    let restricted = CanvasAgentRequest(
        kind: .userInput, questions: [first, second], terminalOnly: true)
    #expect(!state.canAnswer(restricted))
}

@Test("CompanionQuestionSetState: the field keeps only text that can be sent")
func questionSetSendableText() {
    #expect(CompanionQuestionSetState.sendableText("a\u{1B}b\u{200B}c\nd\u{2028}e") == "abcde")
    let long = String(repeating: "é", count: 600)  // 1,200 bytes
    let kept = CompanionQuestionSetState.sendableText(long)
    #expect(kept.utf8.count == 1_024)
    #expect(kept == String(repeating: "é", count: 512))
    // What the field keeps passes the request's own check.
    #expect(single(free: true).accepts(QuestionAnswer(text: kept)))
}
