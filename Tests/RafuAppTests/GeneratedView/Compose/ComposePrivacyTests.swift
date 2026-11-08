import Foundation
import JSONRenderCompose
import JSONRenderCore
import RafuCore
import Testing

@testable import RafuApp

/// Records the requests the real evaluator sends through its injected
/// transport and answers them with hand-written Decisions responses.
private actor TransportRecorder {
    private(set) var requests: [URLRequest] = []

    func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = try #require(request.httpBody)
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questionsData = try JSONSerialization.data(withJSONObject: object["questions"] ?? [])
        let questions = try JSONDecoder().decode([DecisionQuestion].self, from: questionsData)
        let data = try JSONEncoder().encode(
            ComposeAnswers.response(questions, root: "card-panel"))
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }
}

private let testKey = "sk-test-compose-0123456789abcdef"

@Suite("Compose privacy")
@MainActor
struct ComposePrivacyTests {
    @Test("The evaluator reads descriptions and counts: no props, bindings, state or tail text")
    func evaluatorInput() async throws {
        let facts = ComposeCandidatesTests.facts(tail: ComposeCandidatesTests.tail)
        let evaluator = ComposeEvaluatorDouble([
            .answer(root: "card-panel"), .answer(root: "card-panel"),
        ])
        let made = try GeneratedViewComposer.composer(
            facts: facts, title: "Private title words", evaluator: evaluator)
        let context = GeneratedViewComposeContext.make(facts: facts, userContext: nil)
        var events = 0
        for try await _ in made.composer.compose(
            prompt: "show the tests", context: context, initialState: made.state)
        {
            events += 1
        }
        #expect(events >= 2)
        let calls = await evaluator.calls
        #expect(calls.count == 2)
        for call in calls {
            let questionText = try String(
                decoding: JSONEncoder().encode(call.questions), as: UTF8.self)
            for text in [call.input.text, questionText] {
                #expect(!text.contains("SECRET_TAIL_LINE"))
                #expect(!text.contains("$state"))
                #expect(!text.contains("$bindState"))
                #expect(!text.contains("\"props\""))
                #expect(!text.contains("Private title words"))
            }
        }
    }

    @Test("The key goes only into the Authorization header; never into the board, logs or notices")
    func keyOnlyInHeader() async throws {
        let fixture = try await ComposeFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let recorder = TransportRecorder()
        let evaluator = OpenAIDecisionsEvaluator(
            keyProvider: { testKey },
            transport: { request in try await recorder.answer(request) })
        let environment = GeneratedViewComposeEnvironment(
            checkKey: {}, makeEvaluator: { evaluator })
        let outcome = await fixture.run(
            ["prompt": "show this ensemble", "context": "my token=\(testKey)"],
            environment: environment)
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        let requests = await recorder.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url?.scheme == "https")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!body.contains(testKey))
        }
        #expect(!outcome.output.contains(testKey))
        #expect(!outcome.summary.contains(testKey))
        #expect(!outcome.summary.contains("show this ensemble"))
        #expect(fixture.board.notice.map { !$0.message.contains(testKey) } ?? true)
        let log = CanvasAgentCenter.shared.log(for: fixture.board.id)
            .map { String(describing: $0) }.joined()
        #expect(!log.contains(testKey))
        #expect(!log.contains("show this ensemble"))
        let saved = try String(decoding: JSONEncoder().encode(fixture.board.cards), as: UTF8.self)
        #expect(!saved.contains(testKey))
        #expect(!saved.contains("show this ensemble"))
        #expect(!fixture.host.boardEffects.joined().contains(testKey))
    }

    @Test("A non-https base URL is refused before the key is read")
    func insecureBaseURL() async throws {
        let read = KeyReadCounter()
        let evaluator = OpenAIDecisionsEvaluator(
            keyProvider: {
                await read.increment()
                return testKey
            },
            baseURL: try #require(URL(string: "http://api.example.com/v1")),
            transport: { _ in throw DecisionError.transport })
        await #expect(throws: DecisionError.insecureBaseURL) {
            _ = try await evaluator.decide(
                input: DecisionInput(text: "{}"),
                questions: [.predicate(name: "q", instructions: "Q?")])
        }
        #expect(await read.count == 0)
    }
}

private actor KeyReadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
