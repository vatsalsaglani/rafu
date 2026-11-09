import Foundation
import Observation
import RafuCore
import Testing

@testable import RafuApp

/// A terminal node that runs a fake agent. Typed lines are recorded; each
/// line can print an answer. `state` is observable, so the queue sees it change.
@MainActor
@Observable
private final class FakeAgentTerminal {
    var state: AgentSessionState? = .finished
    var front: CanvasAgentConfigureAgent? = .claude
    var lines: [String] = ["╭ Claude Code", "> "]
    var secondsSinceOutput: TimeInterval? = 10
    var sessionID: String? = "s-1"
    @ObservationIgnored var typed: [String] = []
    /// What the agent prints for a typed line.
    @ObservationIgnored var answer: (FakeAgentTerminal, String) -> Void = { _, _ in }

    var terminal: CanvasAgentConfigureTerminal {
        CanvasAgentConfigureTerminal(
            isLive: { true },
            hookState: { [self] in state },
            sessionID: { [self] _ in sessionID },
            secondsSinceOutput: { [self] in secondsSinceOutput },
            agentInFront: { [self] in front },
            viewport: { [self] in Array(lines.suffix(12)) },
            type: { [self] line in
                typed.append(line)
                lines.append("> \(line)")
                answer(self, line)
                return true
            },
            isTypingDone: { true },
            sleep: { _ in await Task.yield() })
    }

    /// Claude Code's answers to `/model` and `/effort`.
    static let claudeAnswers: (FakeAgentTerminal, String) -> Void = { fake, line in
        if line.hasPrefix("/model ") {
            fake.lines.append("⎿ Set model to \(line.dropFirst(7))")
        } else if line.hasPrefix("/effort ") {
            fake.lines.append("⎿ Set effort level to \(line.dropFirst(8))")
        }
    }
}

private final class ConfigureScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-agent-configure-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// An open, shown Ensemble with one terminal node, "Build", and an MCP
/// caller that created it.
@MainActor
private struct ConfigureFixture {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let card: CanvasCard
    let fake = FakeAgentTerminal()
    let creatorID = UUID()
    private let scratch = ConfigureScratchFolder()

    init(title: String = "Build", agent: String = "claude") async throws {
        let scratch = scratch
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.agent-configure-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await session.canvas.configure(root: scratch.url))
        let board = try #require(await session.canvas.create(title: "Configure test"))
        try board.add(title: title, content: .terminal(groupID: TerminalGroupID()))
        session.installCanvasResources(for: board)
        session.canvasResources[board.id]?.present(owner: UUID())
        self.session = session
        self.board = board
        card = try #require(board.cards.first)
        CanvasAgentCenter.shared.noteCreatedTerminal(card.id, caller: creatorID, agent: agent)
    }

    func caller(_ id: UUID? = nil) -> CanvasAgentCaller {
        CanvasAgentCaller(
            session: session, board: board,
            card: CanvasCard(title: "Lead", content: .note(snapshot: "")),
            controllerID: id ?? creatorID, provider: "claude", sendMessage: { _, _ in .init() })
    }

    func call(_ arguments: [String: Any]) throws -> CanvasAgentToolCall {
        var full = arguments
        full["node_id"] = card.id.rawValue.uuidString
        return try CanvasAgentToolCall.parse(tool: "agent_configure", arguments: full)
    }

    /// Runs the MCP path with the fake terminal in place of the live one.
    func handle(_ arguments: [String: Any], caller id: UUID? = nil) async throws
        -> CanvasBridgeResponse
    {
        let call = try call(arguments)
        let fake = fake
        let override: @MainActor @Sendable (CanvasCard) -> CanvasAgentConfigureTerminal? = { _ in
            fake.terminal
        }
        return await CanvasAgentConfigureRunner.$terminalOverride.withValue(override) {
            await CanvasAgentActions.handle(call, caller: caller(id))
        }
    }
}

/// Bounded: yields until `condition` holds.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@Suite("agent_configure in the app")
@MainActor
struct CanvasAgentConfigureAppTests {
    @Test("Allow: Claude changes model and effort in place and the readback confirms it")
    func inPlaceConfirmed() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.fake.answer = FakeAgentTerminal.claudeAnswers
        let response = try await fixture.handle(["model": "sonnet", "effort": "low"])
        #expect(response.error == nil)
        #expect(fixture.fake.typed == ["/model sonnet", "/effort low"])
        let result = try #require(response.toolResult)
        #expect(result.strategy == "in_place")
        #expect(result.confirmed == true)
        let readback = try #require(result.readback)
        #expect(readback.contains("Set model to sonnet"))
        #expect(!readback.contains("/model"))
        #expect(readback.count <= 200)
    }

    @Test("No answer in the terminal: not confirmed, said so, and nothing typed again")
    func inPlaceNotConfirmed() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        let response = try await fixture.handle(["model": "opus"])
        let result = try #require(response.toolResult)
        #expect(result.confirmed == false)
        #expect(result.message?.contains("did not show it") == true)
        #expect(fixture.fake.typed == ["/model opus"])
    }

    @Test("An MCP caller that did not create the terminal is refused")
    func nonCreatorRefused() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        let response = try await fixture.handle(["model": "sonnet"], caller: UUID())
        #expect(response.error?.hasPrefix("not_allowed") == true)
        #expect(fixture.fake.typed.isEmpty)
    }

    @Test("Agent control Off denies the change")
    func offDenies() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.off)
        let response = try await fixture.handle(["model": "sonnet"])
        #expect(response.error == CanvasAgentPolicy.offMessage)
        #expect(fixture.fake.typed.isEmpty)
    }

    @Test("A mid-turn agent gives agent_busy and nothing is typed")
    func busyIsRefused() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.fake.state = .working
        let response = try await fixture.handle(["model": "sonnet"])
        #expect(response.error?.hasPrefix("agent_busy") == true)
        #expect(response.error?.contains("queue") == true)
        fixture.fake.state = .waitingForPermission
        let waiting = try await fixture.handle(["model": "sonnet"])
        #expect(waiting.error?.hasPrefix("agent_busy") == true)
        #expect(fixture.fake.typed.isEmpty)
    }

    @Test("Without hooks, recent output counts as busy and queue is refused")
    func busyWithoutHooks() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.fake.state = nil
        fixture.fake.secondsSinceOutput = 0.5
        let response = try await fixture.handle(["model": "sonnet", "queue": true])
        #expect(response.error?.hasPrefix("agent_busy") == true)
        #expect(response.error?.contains("hooks") == true)
        #expect(fixture.fake.typed.isEmpty)
    }

    @Test("A queued change runs when the agent's turn ends")
    func queuedRunsOnFinish() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.fake.state = .working
        fixture.fake.answer = FakeAgentTerminal.claudeAnswers
        let response = try await fixture.handle(["model": "sonnet", "queue": true])
        #expect(response.error == nil)
        #expect(response.toolResult?.strategy == "queued")
        #expect(fixture.fake.typed.isEmpty)
        #expect(CanvasAgentConfigureQueue.shared.isPending(fixture.card.id))
        // A permission prompt is not the end of the turn.
        fixture.fake.state = .waitingForPermission
        #expect(await eventually { !fixture.fake.typed.isEmpty } == false)
        fixture.fake.state = .finished
        #expect(await eventually { fixture.fake.typed == ["/model sonnet"] })
        #expect(!CanvasAgentConfigureQueue.shared.isPending(fixture.card.id))
        #expect(
            await eventually {
                CanvasAgentCenter.shared.log(for: fixture.board.id).last?.outcome.contains(
                    "confirmed") == true
            })
    }

    @Test("A queued change is dropped when the agent stops")
    func queuedDroppedOnEnd() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.fake.state = .working
        _ = try await fixture.handle(["model": "sonnet", "queue": true])
        fixture.fake.state = .ended
        #expect(await eventually { !CanvasAgentConfigureQueue.shared.isPending(fixture.card.id) })
        #expect(fixture.fake.typed.isEmpty)
    }

    @Test("A Claude mode change in place is unsupported and names the resume rung")
    func claudeModeInPlace() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        let response = try await fixture.handle(["mode": "plan", "strategy": "in_place"])
        #expect(response.error?.hasPrefix("unsupported_in_place") == true)
        #expect(response.error?.contains("resume") == true)
    }

    @Test("A shell in front without hooks is not an agent")
    func shellInFrontRefused() async throws {
        let fixture = try await ConfigureFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.fake.state = nil
        fixture.fake.front = nil
        let response = try await fixture.handle(["model": "sonnet"])
        #expect(response.error?.hasPrefix("agent_not_running") == true)
        #expect(fixture.fake.typed.isEmpty)
    }
}

// MARK: Voice

@MainActor
private struct VoiceConfigureFixture {
    let base: ConfigureFixture
    let confirm = ConfirmProbe()
    let voice: VoiceSession
    let suite = TestDefaultsSuite.name("dev.rafu.voice-configure-tests")

    init(title: String = "Build", agent: String = "claude") async throws {
        let base = try await ConfigureFixture(title: title, agent: agent)
        self.base = base
        let transport = ScriptedLiveTransport()
        let audio = FakeVoiceAudio()
        var dependencies = VoiceSession.Dependencies(
            makeTransport: { _ in transport }, openAIKey: { "test-key" },
            requestMicrophone: { true }, makeAudio: { (audio, audio) },
            preferences: VoicePreferences(suiteName: suite), costSuiteName: suite)
        let session = base.session
        let board = base.board
        dependencies.target = { VoiceTarget(session: session, board: board) }
        dependencies.workspaces = { [session] }
        dependencies.runsClock = false
        dependencies.presentConfirm = confirm.presenter
        dependencies.confirmTimeout = .seconds(30)
        voice = VoiceSession(dependencies: dependencies)
    }

    func run(_ arguments: String) async -> VoiceToolOutcome {
        let fake = base.fake
        let override: @MainActor @Sendable (CanvasCard) -> CanvasAgentConfigureTerminal? = { _ in
            fake.terminal
        }
        return await CanvasAgentConfigureRunner.$terminalOverride.withValue(override) {
            await VoiceToolExecutor.run(
                name: "agent_configure", argumentsJSON: arguments, host: voice)
        }
    }
}

@Suite("agent_configure by voice")
@MainActor
struct VoiceAgentConfigureTests {
    @Test("Ask: an in-place change shows a Confirm card; spoken model names are mapped")
    func askConfirmsInPlace() async throws {
        let fixture = try await VoiceConfigureFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.base.fake.answer = FakeAgentTerminal.claudeAnswers
        fixture.confirm.autoAnswer = .allowOnce
        let outcome = await fixture.run(
            #"{"node_id":"Build","model":"Claude Sonnet","effort":"Low"}"#)
        #expect(!outcome.isError)
        let request = try #require(fixture.confirm.requests.first)
        #expect(request.tool == .agentConfigure)
        #expect(!request.isDestructive)
        #expect(request.offersSessionGrant)
        #expect(request.summary.contains("Model: sonnet"))
        #expect(fixture.base.fake.typed == ["/model sonnet", "/effort low"])
        #expect(outcome.output.contains(#""strategy":"in_place""#))
        #expect(outcome.output.contains(#""confirmed":true"#))
    }

    @Test("Ask: Cancel types nothing")
    func askCancel() async throws {
        let fixture = try await VoiceConfigureFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.confirm.autoAnswer = .cancel
        let outcome = await fixture.run(#"{"node_id":"Build","model":"opus"}"#)
        #expect(outcome.output.contains("cancelled"))
        #expect(fixture.base.fake.typed.isEmpty)
    }

    @Test("Busy by voice is agent_busy before any Confirm card")
    func busyBeforeConfirm() async throws {
        let fixture = try await VoiceConfigureFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.base.fake.state = .working
        let outcome = await fixture.run(#"{"node_id":"Build","model":"opus"}"#)
        #expect(outcome.output.contains("agent_busy"))
        #expect(fixture.confirm.requests.isEmpty)
    }

    @Test("Codex resumes with -c flags behind a destructive Confirm, even in Allow")
    func codexResume() async throws {
        let fixture = try await VoiceConfigureFixture(title: "Tests", agent: "codex")
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.base.board.setAgentControlMode(.allow)
        let fake = fixture.base.fake
        fake.front = .codex
        fake.sessionID = "t-1"
        fake.answer = { fake, line in
            if line == "/quit" {
                fake.front = nil
                fake.secondsSinceOutput = 5
                fake.lines.append("$ ")
            } else if line.hasPrefix("codex resume") {
                fake.front = .codex
            } else if line == "/status" {
                fake.lines.append("Model: gpt-5 (reasoning low, summaries auto)")
            }
        }
        fixture.confirm.autoAnswer = .allowOnce
        let outcome = await fixture.run(
            #"{"node_id":"Tests","model":"GPT 5","effort":"low"}"#)
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        let request = try #require(fixture.confirm.requests.first)
        #expect(request.isDestructive)
        #expect(request.restartsAgent)
        #expect(!request.offersSessionGrant)
        #expect(request.actionTitle == "Restart")
        #expect(request.title == "Restart Codex in “Tests” with the same conversation?")
        #expect(
            fake.typed == [
                "/quit", #"codex resume t-1 -c 'model="gpt-5"' -c 'model_reasoning_effort="low"'"#,
                "/status",
            ])
        #expect(outcome.output.contains(#""strategy":"resume""#))
        #expect(outcome.output.contains(#""confirmed":true"#))
    }

    @Test("A resume stops before the resume line when the agent does not quit")
    func resumeStopsWhenAgentStays() async throws {
        let fixture = try await VoiceConfigureFixture(title: "Tests", agent: "codex")
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let fake = fixture.base.fake
        fake.front = .codex
        fake.sessionID = "t-1"
        fixture.confirm.autoAnswer = .allowOnce
        let outcome = await fixture.run(#"{"node_id":"Tests","model":"gpt-5"}"#)
        #expect(outcome.isError)
        #expect(outcome.output.contains("did not quit"))
        #expect(fake.typed == ["/quit"])
    }
}
