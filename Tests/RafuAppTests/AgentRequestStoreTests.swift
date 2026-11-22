import Foundation
import RafuCore
import Testing

@testable import RafuApp

private func command(_ text: String = "ls") -> CanvasAgentRequest {
    CanvasAgentRequest(kind: .command, command: text)
}

@MainActor
@Suite("Agent request store")
struct AgentRequestStoreTests {
    @Test("Requests wait per terminal in arrival order")
    func arrivalOrder() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let other = UUID()
        let first = command("one")
        let second = command("two")
        #expect(store.open(first, controllerID: terminal) == .opened)
        #expect(store.open(second, controllerID: terminal) == .opened)
        #expect(store.current(for: terminal) == first)
        #expect(store.requests(for: terminal) == [first, second])
        #expect(store.current(for: other) == nil)
    }

    @Test("A terminal holds at most eight requests")
    func perTerminalBound() {
        let store = AgentRequestStore()
        let terminal = UUID()
        for _ in 0..<AgentRequestStore.perTerminalLimit {
            #expect(store.open(command(), controllerID: terminal) == .opened)
        }
        #expect(store.open(command(), controllerID: terminal) == .full)
        #expect(store.requests(for: terminal).count == AgentRequestStore.perTerminalLimit)
        // Another terminal has its own bound.
        #expect(store.open(command(), controllerID: UUID()) == .opened)
    }

    @Test("A retried open is idempotent; a reused key is refused")
    func duplicateKeys() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let request = command()
        #expect(store.open(request, controllerID: terminal) == .opened)
        #expect(store.open(request, controllerID: terminal) == .alreadyOpen)
        #expect(store.requests(for: terminal).count == 1)
        let impostor = CanvasAgentRequest(key: request.key, kind: .command, command: "rm -rf /")
        #expect(store.open(impostor, controllerID: terminal) == .conflict)
        #expect(store.open(request, controllerID: UUID()) == .conflict)
        #expect(store.current(for: terminal)?.command == "ls")
    }

    @Test("A chosen answer is polled until the supervisor closes the request")
    func chooseThenPollThenClose() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let first = command("one")
        let second = command("two")
        _ = store.open(first, controllerID: terminal)
        _ = store.open(second, controllerID: terminal)
        #expect(store.pendingDecision(for: terminal) == nil)
        #expect(
            store.choose(controllerID: terminal, key: second.key, decision: .decline) == .chosen)
        #expect(
            store.pendingDecision(for: terminal)
                == CanvasAgentRequestAnswer(key: second.key, decision: .decline))
        // A lost IPC reply loses nothing: the next poll returns it again.
        #expect(store.pendingDecision(for: terminal)?.key == second.key)
        #expect(store.decision(for: terminal, key: second.key) == .decline)
        #expect(
            store.choose(controllerID: terminal, key: second.key, decision: .accept)
                == .alreadyChosen)
        #expect(store.close(controllerID: terminal, key: second.key))
        #expect(store.pendingDecision(for: terminal) == nil)
        #expect(store.requests(for: terminal) == [first])
        #expect(store.decision(for: terminal, key: second.key) == nil)
    }

    @Test("The oldest chosen answer is polled first")
    func pollOrder() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let first = command("one")
        let second = command("two")
        _ = store.open(first, controllerID: terminal)
        _ = store.open(second, controllerID: terminal)
        _ = store.choose(controllerID: terminal, key: second.key, decision: .accept)
        _ = store.choose(controllerID: terminal, key: first.key, decision: .cancel)
        #expect(store.pendingDecision(for: terminal)?.key == first.key)
    }

    @Test("Stale and unknown keys are refused or ignored")
    func staleKeys() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let request = command()
        _ = store.open(request, controllerID: terminal)
        #expect(!store.close(controllerID: terminal, key: UUID()))
        #expect(!store.close(controllerID: UUID(), key: request.key))
        #expect(store.current(for: terminal) == request)
        #expect(store.close(controllerID: terminal, key: request.key))
        // Closed before the click: the answer cannot go.
        #expect(store.choose(controllerID: terminal, key: request.key, decision: .accept) == .stale)
        #expect(!store.close(controllerID: terminal, key: request.key))
        #expect(store.pendingDecision(for: terminal) == nil)
        #expect(store.pending[terminal] == nil)
        // The key is not this terminal's.
        let other = command()
        _ = store.open(other, controllerID: UUID())
        #expect(store.choose(controllerID: terminal, key: other.key, decision: .accept) == .stale)
    }

    @Test("An answer must be valid for the request kind")
    func decisionValidity() throws {
        let store = AgentRequestStore()
        let terminal = UUID()
        let human = CanvasAgentRequest(kind: .command, isHumanCheckpoint: true, command: "go")
        _ = store.open(human, controllerID: terminal)
        #expect(
            store.choose(controllerID: terminal, key: human.key, decision: .acceptForSession)
                == .invalid)
        #expect(
            store.choose(controllerID: terminal, key: human.key, decision: .answers([:]))
                == .invalid)
        #expect(store.decision(for: terminal, key: human.key) == nil)
        let blocked = CanvasAgentRequest(kind: .command, command: "x\u{1B}")
        _ = store.open(blocked, controllerID: terminal)
        #expect(
            store.choose(controllerID: terminal, key: blocked.key, decision: .accept) == .invalid)
        let question = CanvasAgentRequest(
            kind: .userInput,
            questions: [
                .init(
                    id: "q", header: "", text: "Which?",
                    choices: [.init(label: "A", detail: ""), .init(label: "B", detail: "")])
            ])
        _ = store.open(question, controllerID: terminal)
        #expect(
            store.choose(controllerID: terminal, key: question.key, decision: .accept) == .invalid)
        #expect(
            store.choose(controllerID: terminal, key: question.key, decision: .answers(["q": "C"]))
                == .invalid)
        #expect(
            store.choose(controllerID: terminal, key: question.key, decision: .answers(["q": "B"]))
                == .chosen)
    }

    @Test("A question set takes labels and typed text only as the request permits")
    func questionSetAnswers() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let request = CanvasAgentRequest(
            kind: .userInput,
            questions: [
                .init(
                    id: "theme", header: "", text: "Which theme?",
                    choices: [.init(label: "Indigo", detail: ""), .init(label: "Khadi", detail: "")],
                    allowsFreeText: true),
                .init(
                    id: "parts", header: "", text: "Which parts?",
                    choices: [.init(label: "Editor", detail: ""), .init(label: "Git", detail: "")],
                    allowsMultiple: true),
            ])
        _ = store.open(request, controllerID: terminal)
        // One question unanswered.
        #expect(
            store.choose(
                controllerID: terminal, key: request.key, decision: .answers(["theme": "Indigo"]))
                == .invalid)
        // Two labels for a single-choice question.
        #expect(
            store.choose(
                controllerID: terminal, key: request.key,
                decision: .answers([
                    "theme": QuestionAnswer(labels: ["Indigo", "Khadi"]),
                    "parts": QuestionAnswer(labels: ["Git"]),
                ])) == .invalid)
        // Typed text where the question takes none.
        #expect(
            store.choose(
                controllerID: terminal, key: request.key,
                decision: .answers([
                    "theme": "Indigo", "parts": QuestionAnswer(labels: ["Git"], text: "Docs"),
                ])) == .invalid)
        // A remember choice is never valid while the policy is off.
        #expect(
            store.choose(
                controllerID: terminal, key: request.key, decision: .acceptAndRemember(.session))
                == .invalid)
        let answer = CanvasAgentRequestDecision.answers([
            "theme": QuestionAnswer(text: "Solarized"),
            "parts": QuestionAnswer(labels: ["Editor", "Git"]),
        ])
        #expect(store.choose(controllerID: terminal, key: request.key, decision: answer) == .chosen)
        #expect(store.decision(for: terminal, key: request.key) == answer)
    }

    @Test("Clearing a terminal removes its requests and answers only")
    func clear() {
        let store = AgentRequestStore()
        let terminal = UUID()
        let other = UUID()
        let request = command()
        _ = store.open(request, controllerID: terminal)
        _ = store.choose(controllerID: terminal, key: request.key, decision: .accept)
        _ = store.open(command(), controllerID: other)
        store.clear(controllerID: terminal)
        #expect(store.current(for: terminal) == nil)
        #expect(store.pendingDecision(for: terminal) == nil)
        #expect(store.chosen[terminal] == nil)
        #expect(store.current(for: other) != nil)
    }
}
