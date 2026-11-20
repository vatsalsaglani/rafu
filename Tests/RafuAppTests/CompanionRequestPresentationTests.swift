import RafuCore
import Testing

@testable import RafuApp

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
