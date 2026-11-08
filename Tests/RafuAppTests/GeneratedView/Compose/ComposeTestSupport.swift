import Foundation
import JSONRenderCompose
import JSONRenderCore
import RafuCore
import Testing

@testable import RafuApp

/// Answers Decisions questions without the network. The root is the given
/// value; every predicate says yes; a variants choice takes the first `use:`
/// value; `parent_node_1` takes a header slot when one is offered; any other
/// layout choice takes the first offered value; density is normal.
/// Hand-written (no recording made with a real key).
nonisolated enum ComposeAnswers {
    static func response(_ questions: [DecisionQuestion], root: String) -> DecisionResponse {
        DecisionResponse(
            answers: questions.map { question in
                switch question {
                case .predicate(let name, _):
                    return .predicate(name: name, probability: 1)
                case .choice(let name, _, let choices):
                    let value: String
                    if name == "root" {
                        value = root
                    } else if name == "parent_node_1",
                        let header = choices.first(where: { $0.value.hasSuffix(":header") })
                    {
                        // The layout round moves the first part into the
                        // card header, so the final layout differs from
                        // the preview.
                        value = header.value
                    } else {
                        value =
                            choices.first(where: { $0.value.hasPrefix("use:") })?.value
                            ?? choices.first?.value ?? ""
                    }
                    return .choice(
                        name: name, choice: value, probabilities: [value: 1], confidence: 1)
                case .score(let name, _, _):
                    return .score(name: name, score: 1, probabilities: [1: 1], confidence: 1)
                }
            }, usage: DecisionUsage(inputTokens: 100))
    }
}

/// What the evaluator received for one request.
nonisolated struct ComposeEvaluatorCall: Sendable {
    let input: DecisionInput
    let questions: [DecisionQuestion]
}

/// A `DecisionEvaluator` double: one planned result per request, a record of
/// every request, and an optional main-actor hook that runs before a request
/// (to change the board between the two rounds).
actor ComposeEvaluatorDouble: DecisionEvaluator {
    enum Plan: Sendable {
        case answer(root: String)
        case fail(DecisionError)
    }

    private let plans: [Plan]
    private let beforeCall: (@MainActor @Sendable (Int) async -> Void)?
    private(set) var calls: [ComposeEvaluatorCall] = []

    init(_ plans: [Plan], beforeCall: (@MainActor @Sendable (Int) async -> Void)? = nil) {
        self.plans = plans
        self.beforeCall = beforeCall
    }

    func decide(input: DecisionInput, questions: [DecisionQuestion]) async throws
        -> DecisionResponse
    {
        calls.append(ComposeEvaluatorCall(input: input, questions: questions))
        let index = calls.count
        if let beforeCall { await beforeCall(index) }
        guard index <= plans.count else {
            Issue.record("The composer made an unexpected request \(index).")
            throw DecisionError.transport
        }
        switch plans[index - 1] {
        case .answer(let root): return ComposeAnswers.response(questions, root: root)
        case .fail(let error): throw error
        }
    }
}

extension GeneratedViewComposeEnvironment {
    /// A key check that passes, and the given evaluator.
    static func double(_ evaluator: any DecisionEvaluator, hasKey: Bool = true)
        -> GeneratedViewComposeEnvironment
    {
        GeneratedViewComposeEnvironment(
            checkKey: { if !hasKey { throw VoiceError.noOpenAIKey } },
            makeEvaluator: { evaluator })
    }
}

/// Removes the fixture's temporary workspace.
final class ComposeScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-compose-view-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// One workspace with one Ensemble (a note and two file cards), the real
/// view host, and the executor's fake voice host.
@MainActor
struct ComposeFixture {
    let workspace: WorkspaceSession
    let board: CanvasBoardState
    let viewHost = GeneratedViewActions()
    let host: FakeVoiceToolHost
    let suite: String
    let scratch = ComposeScratchFolder()

    init(mode: CanvasAgentControlMode) async throws {
        let scratch = scratch
        suite = TestDefaultsSuite.name("dev.rafu.compose-view-tests")
        let workspace = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.compose-view-restoration"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await workspace.canvas.configure(root: scratch.url))
        let board = try #require(await workspace.canvas.create(title: "Compose test"))
        try board.add(title: "Plan", content: .note(snapshot: "# Plan\n"))
        try board.add(title: "App.swift", content: .file(path: "Sources/App.swift"))
        try board.add(title: "README.md", content: .file(path: "README.md"))
        board.setAgentControlMode(mode)
        self.workspace = workspace
        self.board = board
        host = FakeVoiceToolHost(session: workspace, board: board, viewHost: nil, suite: suite)
        host.generatedViewHost = viewHost
    }

    func run(_ arguments: [String: Any], environment: GeneratedViewComposeEnvironment) async
        -> VoiceToolOutcome
    {
        await VoiceToolExecutor.composeView(arguments, host: host, environment: environment)
    }

    var views: [CanvasCard] {
        board.cards.filter { GeneratedViewActions.isView($0) }
    }

    func spec(of card: CanvasCard) -> String? {
        guard case .generatedView(let view) = card.content else { return nil }
        return view.specJSON
    }
}

func composeJSON(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
