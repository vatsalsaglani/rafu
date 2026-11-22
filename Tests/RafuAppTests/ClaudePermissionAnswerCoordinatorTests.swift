import Foundation
import RafuCore
import Testing

@testable import RafuApp

private let start = Date(timeIntervalSince1970: 10_000)
private let terminalPID: Int32 = 4_242

/// An event as the answer-mode helper writes it: a Bash request with a
/// summary and the helper's process chain through the terminal's shell.
private func request(
    session: String = "s1", subagent: String? = nil, tool: String = "Bash",
    at seconds: TimeInterval = 0, chain: [Int32] = [9_001, terminalPID, 1]
) -> AgentHookEvent {
    let input: [String: Any] =
        tool == "Bash" ? ["command": "swift build"] : ["file_path": "/repo/a.swift"]
    return AgentHookEvent(
        provider: .claude, sessionID: session, subagentID: subagent,
        hookEventName: "PermissionRequest", cwd: "/repo", toolName: tool,
        ancestorProcessIDs: chain, time: start.addingTimeInterval(seconds),
        requestSummary: AgentPermissionRequestSummary(toolName: tool, toolInput: input))
}

/// An answer-mode event for any tool, built from a hook payload the way the
/// helper builds it (so an unclassified request carries its shape).
private func prompt(
    tool: String, input: [String: Any], session: String = "s1", at seconds: TimeInterval = 0
) throws -> AgentHookEvent {
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": session, "hook_event_name": "PermissionRequest", "cwd": "/repo",
        "tool_name": tool, "tool_input": input,
    ])
    let event = try AgentHookEvent(
        provider: .claude, payload: payload, time: start.addingTimeInterval(seconds),
        includesRequestSummary: true)
    return AgentHookEvent(
        id: event.id, provider: .claude, sessionID: session, hookEventName: "PermissionRequest",
        cwd: "/repo", toolName: tool, ancestorProcessIDs: [9_001, terminalPID, 1],
        time: event.time, requestSummary: event.requestSummary,
        requestShape: event.requestShape)
}

private func notification(
    _ type: String, message: String? = "Claude needs your permission to use the network",
    session: String = "s1", at seconds: TimeInterval = 6
) -> AgentHookEvent {
    AgentHookEvent(
        provider: .claude, sessionID: session, hookEventName: "Notification", cwd: "/repo",
        notificationType: type, ancestorProcessIDs: [9_003, terminalPID, 1],
        time: start.addingTimeInterval(seconds), notificationMessage: message)
}

private var twoQuestions: [String: Any] { [
    "questions": [
        [
            "question": "Which color?", "header": "Color", "multiSelect": false,
            "options": [["label": "Red", "description": ""], ["label": "Blue", "description": ""]],
        ],
        [
            "question": "Which fruits?", "header": "Fruits", "multiSelect": true,
            "options": [
                ["label": "Apple", "description": ""], ["label": "Banana", "description": ""],
            ],
        ],
    ]
] }

private func hook(
    _ name: String, session: String = "s1", subagent: String? = nil, tool: String? = nil,
    at seconds: TimeInterval = 1
) -> AgentHookEvent {
    AgentHookEvent(
        provider: .claude, sessionID: session, subagentID: subagent, hookEventName: name,
        cwd: "/repo", toolName: tool, ancestorProcessIDs: [9_002, terminalPID, 1],
        time: start.addingTimeInterval(seconds))
}

/// A coordinator over a temporary answer channel, with a fixed clock, its own
/// request store and a recorded writer.
@MainActor
private final class Harness {
    let root: URL
    let channel: AgentAnswerChannel
    let requests = AgentRequestStore()
    let terminalID = UUID()
    var clock = start
    var terminals: [AgentTerminalCandidate]
    var writes: [ClaudeAnswerWrite] = []
    var shapes: [String] = []
    var coordinator: ClaudePermissionAnswerCoordinator!

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-answers-\(UUID().uuidString)", directoryHint: .isDirectory)
        channel = AgentAnswerChannel(
            spool: root.appending(path: "AgentTracking/spool", directoryHint: .isDirectory))
        terminals = [
            AgentTerminalCandidate(
                id: terminalID, processID: terminalPID, cwd: "/repo", provider: .claude)
        ]
        coordinator = ClaudePermissionAnswerCoordinator(
            channel: channel, requests: requests,
            terminals: { [unowned self] in terminals },
            now: { [unowned self] in clock },
            write: { [unowned self] in writes.append($0) },
            recordShape: { [unowned self] in shapes.append($0) })
    }

    func tearDown() {
        coordinator.stop()
        try? FileManager.default.removeItem(at: root)
    }

    var openKeys: [UUID] { requests.requests(for: terminalID).map(\.key) }
}

@MainActor
@Suite("Claude permission answer coordinator")
struct ClaudePermissionAnswerCoordinatorTests {
    // MARK: Watch lock

    @Test("The watch lock is held only while watching is on")
    func watchLock() {
        let harness = Harness()
        defer { harness.tearDown() }
        #expect(!harness.channel.isWatched)
        harness.coordinator.setWatching(true)
        #expect(harness.coordinator.isWatching)
        #expect(harness.channel.isWatched)
        harness.coordinator.setWatching(true)
        #expect(harness.channel.isWatched)
        harness.coordinator.setWatching(false)
        #expect(!harness.coordinator.isWatching)
        #expect(!harness.channel.isWatched)
    }

    @Test("The store wants the lock only with the switch, both entries and a watched spool")
    func wantsAnswerWatch() {
        #expect(
            AgentActivityStore.wantsAnswerWatch(
                watching: true, enabled: true, answerEntryConnected: true, claudeConnected: true))
        for flags in [
            (false, true, true, true), (true, false, true, true), (true, true, false, true),
            (true, true, true, false),
        ] {
            #expect(
                !AgentActivityStore.wantsAnswerWatch(
                    watching: flags.0, enabled: flags.1, answerEntryConnected: flags.2,
                    claudeConnected: flags.3))
        }
    }

    // MARK: Opening

    @Test("A matched request opens in the store for its terminal")
    func opensMatched() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        #expect(harness.openKeys == [event.id])
        #expect(harness.requests.current(for: harness.terminalID)?.command == "swift build")
        #expect(harness.writes.isEmpty)
        #expect(harness.coordinator.book.entry(eventID: event.id) != nil)
        // The same event drained again opens nothing new.
        harness.coordinator.handle([event])
        #expect(harness.openKeys == [event.id])
    }

    @Test("A session that runs in no Rafu terminal is dismissed")
    func dismissesUnmatched() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request(chain: [9_001, 7_777, 1])
        harness.coordinator.handle([event])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("Two terminals that both match is no match")
    func ambiguousMatch() {
        let event = request(chain: [])
        let candidates = [UUID(), UUID()].map {
            AgentTerminalCandidate(id: $0, processID: nil, cwd: "/repo", provider: .claude)
        }
        #expect(ClaudePermissionAnswerCoordinator.terminal(for: event, in: candidates) == nil)
        #expect(
            ClaudePermissionAnswerCoordinator.terminal(for: event, in: [candidates[0]])
                == candidates[0].id)
    }

    @Test("Without the watch lock, or for an old event, nothing opens and nothing is written")
    func ignoredWhenNotWatching() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.handle([request()])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)
        harness.coordinator.setWatching(true)
        harness.clock = start.addingTimeInterval(ClaudeAnswerRequestBook.lifetime + 1)
        harness.coordinator.handle([request()])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)
    }

    @Test("The normal entry's event for the same request opens nothing")
    func activityEventIgnored() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        harness.coordinator.handle([hook("PermissionRequest", tool: "Bash", at: 0)])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)
    }

    @Test("A full terminal queue dismisses the extra request")
    func fullQueue() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let events = (0...AgentRequestStore.perTerminalLimit).map { index in
            request(session: "s\(index)")
        }
        harness.coordinator.handle(events)
        #expect(harness.openKeys.count == AgentRequestStore.perTerminalLimit)
        #expect(harness.writes == [.dismiss(events.last!.id)])
    }

    // MARK: Question sets, plans and notices

    @Test("A question set opens, its answers are submitted by index, and it closes")
    func questionSetAnswered() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = try prompt(tool: "AskUserQuestion", input: twoQuestions)
        harness.coordinator.handle([event])
        let open = try #require(harness.requests.current(for: harness.terminalID))
        #expect(open.kind == .userInput)
        #expect(open.questions.count == 2)
        let decision = CanvasAgentRequestDecision.answers([
            "0": "Blue", "1": QuestionAnswer(labels: ["Apple"], text: "Mango"),
        ])
        #expect(
            harness.requests.choose(
                controllerID: harness.terminalID, key: event.id, decision: decision) == .chosen)
        harness.coordinator.reconcile()
        #expect(
            harness.writes == [.submit(CanvasAgentRequestAnswer(key: event.id, decision: decision))])
        #expect(harness.openKeys.isEmpty)
    }

    @Test("A question answered in the terminal closes on PostToolUse of AskUserQuestion")
    func questionSetAnsweredInTerminal() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = try prompt(tool: "AskUserQuestion", input: twoQuestions)
        harness.coordinator.handle([event])
        #expect(harness.openKeys == [event.id])
        // Another tool finishing does not end it.
        harness.coordinator.handle([hook("PostToolUse", tool: "Bash", at: 1)])
        #expect(harness.openKeys == [event.id])
        harness.coordinator.handle([hook("PostToolUse", tool: "AskUserQuestion", at: 2)])
        #expect(harness.openKeys.isEmpty)
        // Its helper waits, so it is told to stop.
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("A plan shows read-only and closes on PostToolUse of ExitPlanMode, with no dismiss")
    func planShownOnly() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = try prompt(
            tool: "ExitPlanMode", input: ["plan": "## Plan", "planFilePath": "/tmp/p.md"])
        harness.coordinator.handle([event])
        let open = try #require(harness.requests.current(for: harness.terminalID))
        #expect(open.kind == .plan)
        #expect(open.terminalOnly)
        harness.coordinator.handle([hook("PostToolUse", tool: "ExitPlanMode", at: 2)])
        #expect(harness.openKeys.isEmpty)
        // No helper waits for a plan: nothing is written.
        #expect(harness.writes.isEmpty)
    }

    @Test("A plan in a session of no Rafu terminal writes nothing")
    func planUnmatched() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        harness.terminals = []
        harness.coordinator.handle([try prompt(tool: "ExitPlanMode", input: ["plan": "p"])])
        #expect(harness.writes.isEmpty)
    }

    @Test("An unclassified request shows a notice, records its shape, and expires silently")
    func unclassifiedNotice() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let secret = "sk-ant-not-a-real-key"
        let event = try prompt(tool: "odd tool", input: ["token": secret])
        harness.coordinator.handle([event])
        let open = try #require(harness.requests.current(for: harness.terminalID))
        #expect(open.kind == .notice)
        #expect(open.reason == "Claude Code asks to use odd tool. Open the terminal to answer.")
        #expect(harness.shapes == ["claude ? object[1]{string:1}"])
        #expect(!harness.shapes.joined().contains(secret))
        harness.clock = start.addingTimeInterval(ClaudeAnswerRequestBook.lifetime)
        harness.coordinator.reconcile()
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)
    }

    @Test("A waiting notification opens a notice only when the session shows nothing else")
    func notificationNotice() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        // A sandboxed network request: no PermissionRequest, only the notification.
        let network = notification("permission_prompt")
        harness.coordinator.handle([network])
        let open = try #require(harness.requests.current(for: harness.terminalID))
        #expect(open.kind == .notice)
        #expect(open.reason == "Permission request")
        #expect(open.text == "Claude needs your permission to use the network")
        // The command runs after the person allows it in the terminal.
        harness.coordinator.handle([hook("PostToolUse", tool: "Bash", at: 9)])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)

        // A notification for a request Rafu shows already adds nothing.
        let bash = request(at: 10)
        harness.coordinator.handle([bash, notification("permission_prompt", at: 16)])
        #expect(harness.openKeys == [bash.id])
        // An idle notification never opens one.
        harness.coordinator.handle([hook("PostToolUse", tool: "Bash", at: 17)])
        harness.coordinator.handle([notification("idle_prompt", message: "Idle", at: 80)])
        #expect(harness.openKeys.isEmpty)
    }

    @Test("Without the watch lock a notification opens nothing")
    func notificationNotWatching() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.handle([notification("elicitation_dialog")])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)
    }

    @Test("Releasing the lock dismisses only the requests whose helper waits")
    func releaseDismissesWaitingOnly() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let bash = request()
        let plan = try prompt(tool: "ExitPlanMode", input: ["plan": "p"], session: "s2")
        harness.coordinator.handle([bash, plan])
        #expect(Set(harness.openKeys) == [bash.id, plan.id])
        harness.coordinator.setWatching(false)
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(bash.id)])
    }

    // MARK: Answering

    @Test("A chosen answer is submitted once and the request closes")
    func submitsDecision() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        #expect(
            harness.requests.choose(
                controllerID: harness.terminalID, key: event.id, decision: .cancel) == .chosen)
        harness.coordinator.reconcile()
        #expect(
            harness.writes == [.submit(CanvasAgentRequestAnswer(key: event.id, decision: .cancel))])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.coordinator.book.isEmpty)
        harness.coordinator.reconcile()
        #expect(harness.writes.count == 1)
    }

    @Test("The default writer puts the answer or the dismiss file in the channel")
    func defaultWriterWritesFile() async {
        let harness = Harness()
        defer { harness.tearDown() }
        let bridge = ClaudePermissionAnswerBridge(channel: harness.channel)
        let allowed = UUID()
        await ClaudeAnswerIO.perform(
            .submit(CanvasAgentRequestAnswer(key: allowed, decision: .accept)), bridge)
        #expect(
            harness.channel.take(eventID: allowed)
                == AgentPermissionAnswer(eventID: allowed, verdict: .allow))
        let dismissed = UUID()
        await ClaudeAnswerIO.perform(.dismiss(dismissed), bridge)
        #expect(
            harness.channel.take(eventID: dismissed)
                == AgentPermissionAnswer(eventID: dismissed, verdict: .dismiss))
    }

    // MARK: Ending without an answer from Rafu

    @Test("The next event that shows the tool ran closes the request and dismisses")
    func resolvedInTerminal() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        // Claude's own notification and another tool's result do not end it.
        harness.coordinator.handle([
            hook("Notification", at: 1), hook("PostToolUse", tool: "Read", at: 2),
        ])
        #expect(harness.openKeys == [event.id])
        harness.coordinator.handle([hook("PostToolUse", tool: "Bash", at: 3)])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("A request and its resolving event in one drain end closed")
    func sameBatch() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event, hook("PostToolUseFailure", tool: "Bash", at: 1)])
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("Resolving events follow the session and the sub-agent")
    func resolutionRules() throws {
        let event = request(subagent: nil)
        var book = ClaudeAnswerRequestBook()
        book.add(event, controllerID: UUID())
        let entry = try #require(book.entry(eventID: event.id))
        let resolves = { ClaudeAnswerRequestBook.resolves($0, entry) }
        #expect(resolves(hook("Stop")))
        #expect(resolves(hook("StopFailure")))
        #expect(resolves(hook("UserPromptSubmit")))
        #expect(resolves(hook("SessionEnd")))
        #expect(resolves(request(at: 2)))
        #expect(!resolves(hook("PermissionRequest", tool: "Bash")))
        #expect(!resolves(hook("PreToolUse", tool: "Bash")))
        #expect(!resolves(hook("Stop", session: "other")))
        #expect(!resolves(hook("PostToolUse", subagent: "agent-1", tool: "Bash")))
        #expect(!resolves(hook("Stop", at: -1)))
        #expect(!resolves(event))

        let subagentEvent = request(subagent: "agent-1")
        var subBook = ClaudeAnswerRequestBook()
        subBook.add(subagentEvent, controllerID: UUID())
        let subEntry = try #require(subBook.entry(eventID: subagentEvent.id))
        #expect(
            ClaudeAnswerRequestBook.resolves(hook("SubagentStop", subagent: "agent-1"), subEntry))
        #expect(!ClaudeAnswerRequestBook.resolves(hook("Stop"), subEntry))
        // The main session ending ends a sub-agent's request too.
        #expect(ClaudeAnswerRequestBook.resolves(hook("SessionEnd"), subEntry))
    }

    @Test("A request expires when the helper stops waiting")
    func expires() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        harness.clock = start.addingTimeInterval(ClaudeAnswerRequestBook.lifetime - 1)
        harness.coordinator.reconcile()
        #expect(harness.openKeys == [event.id])
        harness.clock = start.addingTimeInterval(ClaudeAnswerRequestBook.lifetime)
        harness.coordinator.reconcile()
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("A request cleared by its terminal's exit is dismissed")
    func clearedByTerminal() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        harness.requests.clear(controllerID: harness.terminalID)
        harness.coordinator.reconcile()
        #expect(harness.writes == [.dismiss(event.id)])
        #expect(harness.coordinator.book.isEmpty)
    }

    @Test("A request whose terminal is gone closes and is dismissed")
    func terminalGone() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        harness.terminals = []
        harness.coordinator.reconcile()
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("Turning watching off releases the lock, closes and dismisses each request")
    func watchingOff() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        let event = request()
        harness.coordinator.handle([event])
        harness.coordinator.setWatching(false)
        #expect(!harness.channel.isWatched)
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes == [.dismiss(event.id)])
    }

    @Test("Quit releases the lock and clears requests without writing")
    func quit() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.coordinator.setWatching(true)
        harness.coordinator.handle([request()])
        harness.coordinator.stop()
        #expect(!harness.channel.isWatched)
        #expect(harness.openKeys.isEmpty)
        #expect(harness.writes.isEmpty)
    }

    // MARK: Store wiring

    @Test("The activity store forwards drained events to the coordinator")
    func storeForwardsEvents() {
        let suite = TestDefaultsSuite.name("dev.rafu.tests.claude-answers")
        defer { TestDefaultsSuite.remove(suite) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-answer-store-\(UUID().uuidString)/AgentTracking")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let requests = AgentRequestStore()
        let terminalID = UUID()
        let store = AgentActivityStore(
            paths: AgentTrackingPaths(root: root),
            defaults: UserDefaults(suiteName: suite) ?? .standard,
            agentRequests: requests,
            terminals: {
                [
                    AgentTerminalCandidate(
                        id: terminalID, processID: terminalPID, cwd: "/repo", provider: .claude)
                ]
            })
        defer { store.stopAnswering() }
        #expect(!store.claudeAnswersEnabled)
        #expect(!store.claudeAnswersConnected)
        // Not watching (the switch is off): the event opens nothing.
        let event = AgentHookEvent(
            provider: .claude, sessionID: "s1", hookEventName: "PermissionRequest", cwd: "/repo",
            toolName: "Bash", ancestorProcessIDs: [9_001, terminalPID, 1], time: Date(),
            requestSummary: AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "ls"]))
        store.apply([event], at: Date())
        #expect(requests.requests(for: terminalID).isEmpty)
        // The switch and the entry alone do not take the lock while the spool
        // is not watched.
        store.setClaudeAnswersEnabled(true)
        store.setClaudeAnswersConnected(true)
        store.setConnected(.claude, true)
        #expect(!store.claudeAnswers.isWatching)
        // With the lock held, the same kind of event opens a request.
        store.claudeAnswers.setWatching(true)
        let second = AgentHookEvent(
            provider: .claude, sessionID: "s1", hookEventName: "PermissionRequest", cwd: "/repo",
            toolName: "Bash", ancestorProcessIDs: [9_001, terminalPID, 1], time: Date(),
            requestSummary: AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "ls"]))
        store.apply([second], at: Date())
        #expect(requests.requests(for: terminalID).map(\.key) == [second.id])
        store.stop()
        #expect(!store.claudeAnswers.isWatching)
        #expect(requests.requests(for: terminalID).isEmpty)
    }

    @Test("A recorded activity Disconnect for Claude Code also marks the answer entry gone")
    func setupModelRecords() throws {
        let suite = TestDefaultsSuite.name("dev.rafu.tests.claude-answers-setup")
        defer { TestDefaultsSuite.remove(suite) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-answer-setup-\(UUID().uuidString)/AgentTracking")
        let paths = AgentTrackingPaths(root: root)
        let store = AgentActivityStore(
            paths: paths, defaults: UserDefaults(suiteName: suite) ?? .standard,
            agentRequests: AgentRequestStore(), terminals: { [] })
        defer { store.stopAnswering() }
        let model = AgentHookSetupModel(
            store: store, home: root, environment: [:], bundledHelper: nil)
        let destination = root.appending(path: "settings.json")
        let activity = try AgentHookConfiguration.plan(
            provider: .claude, destination: destination, existing: nil, helper: paths.helper,
            spool: paths.spool, removing: false)
        model.record(activity)
        #expect(model.canConnectAnswers)
        let answers = try AgentHookConfiguration.plan(
            provider: .claude, destination: destination, existing: activity.after,
            helper: paths.helper, spool: paths.spool, removing: false, scope: .answers)
        model.record(answers)
        #expect(model.answerStatus == .connected)
        #expect(store.claudeAnswersConnected)
        #expect(model.status(for: .claude) == .connected)
        let disconnect = try AgentHookConfiguration.plan(
            provider: .claude, destination: destination, existing: answers.after,
            helper: paths.helper, spool: paths.spool, removing: true)
        model.record(disconnect)
        #expect(model.answerStatus == .notConnected)
        #expect(!store.claudeAnswersConnected)
        #expect(!model.canConnectAnswers)
        model.claudeAnswersEnabled = true
        #expect(store.claudeAnswersEnabled)
    }
}
