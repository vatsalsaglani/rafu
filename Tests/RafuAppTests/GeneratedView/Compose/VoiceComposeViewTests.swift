import Foundation
import JSONRenderCompose
import JSONRenderCore
import RafuCore
import Testing

@testable import RafuApp

private var arguments: [String: Any] {
    ["prompt": "show me how this ensemble is doing", "title": "Ensemble status"]
}

@Suite("Voice compose_view")
@MainActor
struct VoiceComposeViewTests {
    @Test("Off refuses and makes no evaluator request")
    func offRefuses() async throws {
        let fixture = try await ComposeFixture(mode: .off)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let evaluator = ComposeEvaluatorDouble([.answer(root: "card-panel")])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(outcome.summary == "agent_control_off")
        #expect(fixture.views.isEmpty)
        #expect(await evaluator.calls.isEmpty)
    }

    @Test("Ask: a preview card, then the final layout, one undo step and an Undo notice")
    func askComposes() async throws {
        let fixture = try await ComposeFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let cardsBefore = fixture.board.cards
        let evaluator = ComposeEvaluatorDouble([
            .answer(root: "card-panel"), .answer(root: "card-panel"),
        ])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        #expect(await evaluator.calls.count == 2)
        let output = try composeJSON(outcome.output)
        #expect(output["status"] as? String == "ok")
        #expect(output["rounds"] as? Int == 2)
        #expect(output["message"] as? String == "Showing Ensemble status.")
        let card = try #require(fixture.views.first)
        #expect(fixture.views.count == 1)
        #expect(output["node_id"] as? String == card.id.rawValue.uuidString)
        #expect(card.title == "Ensemble status")
        // The final layout (round two put a part in the header) validates
        // against the Rafu catalog.
        let specText = try #require(fixture.spec(of: card))
        #expect(fixture.viewHost.validate(specJSON: specText).isSuccess)
        #expect(specText.contains(#""header""#))
        guard case .generatedView(let view) = card.content else { return }
        #expect(view.provenance.provider == "voice")
        #expect(view.provenance.journal.first?.hasPrefix("composed: rounds 2, questions ") == true)
        let notice = try #require(fixture.board.notice)
        #expect(notice.message == "Rafu (voice) composed Ensemble status")
        #expect(notice.action?.title == "Undo")
        #expect(fixture.host.boardEffects == ["1 added"])
        #expect(outcome.summary.hasPrefix("\(output["elements"] as? Int ?? 0) elements; rounds 2"))
        #expect(outcome.summary.hasSuffix("tokens 200"))
        // One voice undo removes the whole request.
        #expect(fixture.host.undoLedger.undo(on: fixture.board))
        #expect(fixture.views.isEmpty)
        #expect(fixture.board.cards == cardsBefore)
    }

    @Test("Allow composes without a Confirm card")
    func allowComposes() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let evaluator = ComposeEvaluatorDouble([
            .answer(root: "stack-panel"), .answer(root: "stack-panel"),
        ])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        #expect(fixture.views.count == 1)
        #expect(!outcome.summary.contains("Ensemble status"))
    }

    @Test("Round one unavailable: an error and no card")
    func unavailableFirstRound() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let evaluator = ComposeEvaluatorDouble([.answer(root: "unavailable")])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(outcome.isError)
        #expect(outcome.output.contains(VoiceToolExecutor.composeUnavailableMessage))
        #expect(outcome.summary.hasPrefix("unavailable"))
        #expect(fixture.views.isEmpty)
    }

    @Test("A service failure in round one names the class only")
    func serviceFailureFirstRound() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let evaluator = ComposeEvaluatorDouble([.fail(.httpStatus(503))])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(outcome.output.contains(VoiceToolExecutor.composeServiceMessage))
        #expect(!outcome.output.contains("503"))
        #expect(fixture.views.isEmpty)
    }

    @Test("Round two fails: the preview stays and the status is partial")
    func secondRoundFails() async throws {
        let fixture = try await ComposeFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let evaluator = ComposeEvaluatorDouble([.answer(root: "card-panel"), .fail(.timeout)])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        let output = try composeJSON(outcome.output)
        #expect(output["status"] as? String == "partial")
        #expect(fixture.views.count == 1)
        #expect(fixture.host.undoLedger.undo(on: fixture.board))
        #expect(fixture.views.isEmpty)
    }

    @Test("A board edit between the rounds makes the final layout a second, honest step")
    func editBetweenRounds() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let board = fixture.board
        let evaluator = ComposeEvaluatorDouble(
            [.answer(root: "card-panel"), .answer(root: "card-panel")],
            beforeCall: { index in
                if index == 2 { _ = try? board.add(title: "User", content: .note(snapshot: "")) }
            })
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        let output = try composeJSON(outcome.output)
        #expect(output["status"] as? String == "ok")
        let card = try #require(fixture.views.first)
        let finalSpec = fixture.spec(of: card)
        // Undo by voice removes only the final layout; the preview stays.
        #expect(fixture.host.undoLedger.undo(on: board))
        let preview = try #require(fixture.views.first)
        #expect(preview.id == card.id)
        #expect(fixture.spec(of: preview) != finalSpec)
    }

    @Test("No key: the Settings sentence and no evaluator request")
    func noKey() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let evaluator = ComposeEvaluatorDouble([])
        let outcome = await fixture.run(arguments, environment: .double(evaluator, hasKey: false))
        #expect(outcome.summary == "no_openai_key")
        #expect(outcome.output.contains("Add an OpenAI key in Settings ▸ AI"))
        #expect(await evaluator.calls.isEmpty)
        #expect(fixture.views.isEmpty)
    }

    @Test("The rate limit refuses before any request")
    func rateLimited() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        while CanvasAgentCenter.shared.admit(fixture.host.callerID) {}
        let evaluator = ComposeEvaluatorDouble([])
        let outcome = await fixture.run(arguments, environment: .double(evaluator))
        #expect(outcome.summary == "rate_limited")
        #expect(await evaluator.calls.isEmpty)
    }

    @Test("Arguments: prompt required and bounded; a default title from the prompt")
    func argumentChecks() {
        guard case .refused(let missing) = VoiceToolExecutor.parseComposeView([:]) else {
            Issue.record("A missing prompt must be refused")
            return
        }
        #expect(missing.summary == "invalid_arguments")
        let long = String(repeating: "a", count: 401)
        guard case .refused = VoiceToolExecutor.parseComposeView(["prompt": long]) else {
            Issue.record("A long prompt must be refused")
            return
        }
        guard
            case .refused = VoiceToolExecutor.parseComposeView([
                "prompt": "x", "context": String(repeating: "c", count: 1_001),
            ])
        else {
            Issue.record("A long context must be refused")
            return
        }
        guard
            case .request(let request) = VoiceToolExecutor.parseComposeView([
                "prompt": "  show the test results\nplease ", "near": "Plan",
            ])
        else {
            Issue.record("A valid call must parse")
            return
        }
        #expect(request.title == "Show the test results please")
        #expect(request.near == "Plan")
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
