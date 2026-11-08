import Foundation
import JSONRenderCompose
import JSONRenderCore
import RafuCore
import Testing

@testable import RafuApp

@Suite("Compose candidates")
struct ComposeCandidatesTests {
    static func facts(tail: [GeneratedViewComposeFacts.TailLine]? = nil)
        -> GeneratedViewComposeFacts
    {
        GeneratedViewComposeFacts(
            ensemble: "Release", cards: 7, links: 2, agentControl: "allow",
            terminals: [
                .init(title: "Tests", state: "running", agent: "claude"),
                .init(title: "Server", state: "running", agent: nil),
                .init(title: "Old", state: "exited", agent: "codex"),
            ],
            files: [.init(title: "App.swift", path: "Sources/App.swift")], tail: tail)
    }

    static let tail: [GeneratedViewComposeFacts.TailLine] = [
        .init(terminal: "Tests", line: "✔ Test parser passed"),
        .init(terminal: "Tests", line: "✘ Test SECRET_TAIL_LINE failed"),
        .init(terminal: "Tests", line: "error: build step failed"),
    ]

    @Test("Every candidate is valid for the Rafu catalog; the composer accepts the set")
    func validForCatalog() throws {
        let made = GeneratedViewCandidates.make(facts: Self.facts(tail: Self.tail), title: "T")
        #expect(made.candidates.count <= GeneratedViewCandidates.maximumCandidates)
        for candidate in made.candidates {
            #expect(
                RafuCatalog.rafu.component(named: candidate.element.type) != nil,
                Comment(rawValue: candidate.id))
        }
        _ = try Composer(
            catalog: .rafu, candidates: made.candidates,
            evaluator: ComposeEvaluatorDouble([]), limits: GeneratedViewCandidates.limits,
            instructions: GeneratedViewCandidates.instructions)
    }

    @Test("The terminal output group appears only with a shared tail")
    func testsOnlyWithTail() {
        let without = GeneratedViewCandidates.make(facts: Self.facts(), title: "T")
        #expect(
            !without.candidates.contains { $0.resource == GeneratedViewCandidates.testsResource })
        #expect(without.state["tests"] == nil)
        let with = GeneratedViewCandidates.make(facts: Self.facts(tail: Self.tail), title: "T")
        let tests = with.candidates.filter { $0.resource == GeneratedViewCandidates.testsResource }
        #expect(tests.map(\.id) == ["table-terminal-lines", "bar-test-results"])
    }

    @Test("Descriptions carry the real numbers and never terminal text")
    func descriptions() {
        let made = GeneratedViewCandidates.make(facts: Self.facts(tail: Self.tail), title: "T")
        let byID = Dictionary(uniqueKeysWithValues: made.candidates.map { ($0.id, $0) })
        #expect(byID["stat-cards"]?.description.contains("7 cards") == true)
        #expect(byID["stat-terminals"]?.description.contains("2 terminals running of 3") == true)
        #expect(byID["stat-agents"]?.description.contains("2 agents") == true)
        #expect(byID["bar-test-results"]?.description.contains("2 failed, 1 passed") == true)
        #expect(byID["table-terminal-lines"]?.description.contains("2 failure lines") == true)
        for candidate in made.candidates {
            #expect(!candidate.description.contains("SECRET_TAIL_LINE"))
        }
    }

    @Test("Data lives in state: no literal prop string is longer than 60 characters")
    func dataInState() throws {
        let made = GeneratedViewCandidates.make(facts: Self.facts(tail: Self.tail), title: "T")
        func strings(_ value: JSONRenderCore.JSONValue) -> [String] {
            switch value {
            case .string(let text): [text]
            case .array(let items): items.flatMap(strings)
            case .object(let members):
                members.filter { !$0.key.hasPrefix("$") }.values.flatMap(strings)
            default: []
            }
        }
        for candidate in made.candidates {
            for text in strings(.object(candidate.element.props)) {
                #expect(text.count <= 60, Comment(rawValue: candidate.id))
            }
        }
        let rows = try #require(made.state["tests"]?["rows"]?.arrayValue)
        #expect(rows.count == 2)
        #expect(made.state["counts"]?["running"] == 2)
    }

    @Test("Facts come from describe nodes; the tail is kept only when given")
    func factsFromNodes() {
        let nodes = [
            CanvasAgentNodeSummary(
                id: "a", kind: "terminal", title: "Tests", x: 0, y: 0, width: 1, height: 1,
                state: "running", agent: "claude"),
            CanvasAgentNodeSummary(
                id: "b", kind: "file", title: "App", x: 0, y: 0, width: 1, height: 1,
                path: "Sources/App.swift"),
            CanvasAgentNodeSummary(
                id: "c", kind: "note", title: "N", x: 0, y: 0, width: 1, height: 1),
        ]
        let facts = GeneratedViewComposeFacts.make(
            ensemble: "E", links: 1, agentControl: "ask", nodes: nodes, tails: nil)
        #expect(facts.cards == 3)
        #expect(facts.runningTerminals == 1)
        #expect(facts.agents == 1)
        #expect(facts.files == [.init(title: "App", path: "Sources/App.swift")])
        #expect(facts.tail == nil)
        let shared = GeneratedViewComposeFacts.make(
            ensemble: "E", links: 1, agentControl: "allow", nodes: nodes,
            tails: ["a": "one\ntwo"])
        #expect(shared.tail?.map(\.line) == ["one", "two"])
    }

    @Test("The context holds counts and the scrubbed user words, never the tail")
    func context() throws {
        let context = GeneratedViewComposeContext.make(
            facts: Self.facts(tail: Self.tail),
            userContext: "focus on failures api_key=sk-test-compose-123456789012345")
        let text = try #require(GeneratedViewStatePersistence.canonicalText(context))
        #expect(!text.contains("SECRET_TAIL_LINE"))
        #expect(!text.contains("sk-test-compose-123456789012345"))
        #expect(context["cards"] == 7)
        #expect(context["terminal_output_shared"] == true)
        #expect(context["user_context"]?.stringValue?.hasPrefix("focus on failures") == true)
    }
}
