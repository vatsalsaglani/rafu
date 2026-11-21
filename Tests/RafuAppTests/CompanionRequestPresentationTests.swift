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
    #expect(CompanionRequestPresentation(request: restricted, decision: nil).controls == .terminal)
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
