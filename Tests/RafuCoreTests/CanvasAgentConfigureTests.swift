import Foundation
import Testing

@testable import RafuCore

private let node = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

@Suite("agent_configure: allowlists, plans and readback")
struct CanvasAgentConfigureTests {
    // MARK: Launch argv

    @Test("Launch argv puts model and effort flags before the task, per agent")
    func launchArgv() {
        #expect(
            CanvasAgentLaunch.argv(
                agent: "claude", prompt: "fix it", model: "sonnet", effort: "low")
                == ["claude", "--model", "sonnet", "--effort", "low", "fix it"])
        #expect(
            CanvasAgentLaunch.argv(agent: "claude", prompt: nil, model: "opus", effort: nil)
                == ["claude", "--model", "opus"])
        #expect(
            CanvasAgentLaunch.argv(agent: "claude", prompt: nil, model: nil, effort: "max")
                == ["claude", "--effort", "max"])
        #expect(
            CanvasAgentLaunch.argv(
                agent: "codex", prompt: "run tests", model: "gpt-5", effort: "high")
                == ["codex", "-m", "gpt-5", "-c", "model_reasoning_effort=\"high\"", "run tests"])
        #expect(
            CanvasAgentLaunch.argv(agent: "codex", prompt: nil, model: nil, effort: "low")
                == ["codex", "-c", "model_reasoning_effort=\"low\""])
        // The old form is unchanged.
        #expect(CanvasAgentLaunch.argv(agent: "codex", prompt: nil) == ["codex"])
    }

    @Test("Launch argv refuses a bad model, a foreign effort, auto, and another agent")
    func launchArgvRefuses() {
        #expect(
            CanvasAgentLaunch.argv(agent: "claude", prompt: nil, model: "a b", effort: nil) == nil)
        #expect(
            CanvasAgentLaunch.argv(agent: "codex", prompt: nil, model: nil, effort: "max") == nil)
        #expect(
            CanvasAgentLaunch.argv(agent: "claude", prompt: nil, model: nil, effort: "auto") == nil)
        #expect(
            CanvasAgentLaunch.argv(agent: "gemini", prompt: nil, model: "x", effort: nil) == nil)
    }

    @Test("terminal_create accepts model and effort only with claude or codex")
    func terminalCreateParsesModelAndEffort() throws {
        let call = try CanvasAgentToolCall.parse(
            tool: "terminal_create",
            arguments: ["agent": "claude", "model": "Sonnet", "effort": "HIGH"])
        #expect(call.model == "sonnet")
        #expect(call.effort == "high")
        #expect(call.startsProcess)
        #expect(throws: CanvasAgentToolError.self) {
            try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: ["model": "sonnet"])
        }
        #expect(throws: CanvasAgentToolError.self) {
            try CanvasAgentToolCall.parse(
                tool: "terminal_create", arguments: ["agent": "codex", "effort": "xhigh"])
        }
        #expect(throws: CanvasAgentToolError.self) {
            try CanvasAgentToolCall.parse(
                tool: "terminal_create", arguments: ["agent": "gemini", "model": "flash"])
        }
    }

    // MARK: Allowlists

    @Test(
        "The model allowlist rejects spaces, quotes, shell characters and a leading dash",
        arguments: [
            "", "a b", "sonnet;rm", "\"opus\"", "'opus'", "-opus", ".opus", "opus$(x)", "op|us",
            "Opus", "op\nus", String(repeating: "a", count: 65),
        ])
    func modelAllowlistRejects(_ value: String) {
        #expect(!CanvasAgentConfigurePlan.isValidModel(value))
    }

    @Test(
        "The model allowlist accepts CLI names",
        arguments: ["sonnet", "opus", "gpt-5", "gpt-5.1-codex", "claude-sonnet-4-5", "o3_mini"])
    func modelAllowlistAccepts(_ value: String) {
        #expect(CanvasAgentConfigurePlan.isValidModel(value))
    }

    @Test("agent_configure parses, lowercases and bounds its arguments")
    func parseConfigure() throws {
        let call = try CanvasAgentToolCall.parse(
            tool: "agent_configure",
            arguments: [
                "node_id": node, "model": "Opus", "effort": "Low", "strategy": "IN_PLACE",
                "queue": true,
            ])
        #expect(call.tool == .agentConfigure)
        #expect(call.risk == .sensitive)
        #expect(call.model == "opus")
        #expect(call.effort == "low")
        #expect(call.strategy == "in_place")
        #expect(call.queue == true)
        let modeOnly = try CanvasAgentToolCall.parse(
            tool: "agent_configure", arguments: ["node_id": node, "mode": "plan"])
        #expect(modeOnly.mode == "plan")
        for bad: [String: Any] in [
            ["node_id": node],
            ["model": "opus"],
            ["node_id": node, "model": "opus; rm -rf /"],
            ["node_id": node, "effort": "turbo"],
            ["node_id": node, "mode": "append"],
            ["node_id": node, "mode": "bypass_permissions"],
            ["node_id": node, "model": "opus", "strategy": "fresh"],
            ["node_id": node, "model": "opus", "queue": "yes"],
            ["node_id": node, "model": "opus", "text": "hello"],
        ] {
            #expect(throws: CanvasAgentToolError.self) {
                try CanvasAgentToolCall.parse(tool: "agent_configure", arguments: bad)
            }
        }
    }

    @Test("note_write still checks its own modes")
    func noteModesUnchanged() {
        #expect(throws: CanvasAgentToolError.self) {
            try CanvasAgentToolCall.parse(
                tool: "note_write", arguments: ["node_id": node, "text": "x", "mode": "plan"])
        }
    }

    @Test("The approval names the strategy and never more than the tokens")
    func approvalSummary() throws {
        var call = try CanvasAgentToolCall.parse(
            tool: "agent_configure", arguments: ["node_id": node, "model": "sonnet"])
        call.strategy = "resume"
        #expect(call.approvalSummary.contains("Model: sonnet"))
        #expect(call.approvalSummary.contains { $0.hasPrefix("Restart:") })
        call.strategy = "in_place"
        call.queue = true
        #expect(call.approvalSummary.contains { $0.hasPrefix("In place:") })
        #expect(call.approvalSummary.contains { $0.hasPrefix("Queue:") })
    }

    // MARK: Plans

    @Test("Claude in place types /model then /effort, then reads back both")
    func claudeInPlace() throws {
        let plan = try CanvasAgentConfigurePlan.make(
            agent: .claude, request: .init(model: "sonnet", effort: "low"), strategy: nil,
            sessionID: nil)
        #expect(plan.strategy == .inPlace)
        #expect(!plan.restartsAgent)
        #expect(
            plan.steps == [
                .agentLine("/model sonnet"), .agentLine("/effort low"),
                .readback(
                    .init(tokens: ["sonnet", "low"], ignoredLineMarkers: ["/model", "/effort"])),
            ])
    }

    @Test("A Claude mode change is unsupported in place and resumes with flags")
    func claudeModeNeedsResume() throws {
        #expect(throws: CanvasAgentConfigureRefusal.unsupportedInPlace(agent: .claude)) {
            try CanvasAgentConfigurePlan.make(
                agent: .claude, request: .init(mode: "plan"), strategy: nil, sessionID: "abc")
        }
        let plan = try CanvasAgentConfigurePlan.make(
            agent: .claude, request: .init(model: "opus", effort: "high", mode: "accept_edits"),
            strategy: .resume, sessionID: "abc-123")
        #expect(plan.restartsAgent)
        #expect(
            plan.steps == [
                .exitAgent("/exit"),
                .shellCommand([
                    "claude", "--resume", "abc-123", "--model", "opus", "--effort", "high",
                    "--permission-mode", "acceptEdits",
                ]),
            ])
    }

    @Test("Codex resumes by default with -c config and reads back /status")
    func codexResume() throws {
        #expect(throws: CanvasAgentConfigureRefusal.unsupportedInPlace(agent: .codex)) {
            try CanvasAgentConfigurePlan.make(
                agent: .codex, request: .init(model: "gpt-5"), strategy: .inPlace, sessionID: "t1")
        }
        let plan = try CanvasAgentConfigurePlan.make(
            agent: .codex, request: .init(model: "gpt-5", effort: "low"), strategy: nil,
            sessionID: "0199-thread")
        #expect(plan.strategy == .resume)
        #expect(plan.steps.first == .exitAgent("/quit"))
        #expect(
            plan.steps[1]
                == .shellCommand([
                    "codex", "resume", "0199-thread", "-c", "model=\"gpt-5\"", "-c",
                    "model_reasoning_effort=\"low\"",
                ]))
        #expect(plan.steps[2] == .waitForAgent)
        #expect(plan.steps[3] == .agentLine("/status"))
        guard case .readback(let matcher) = plan.steps[4] else {
            Issue.record("expected a readback step")
            return
        }
        #expect(matcher.tokens == ["gpt-5", "low"])
    }

    @Test("A resume without a safe conversation id is refused")
    func resumeNeedsSession() {
        for id in [nil, "", "-rm", "a b", "x;y"] as [String?] {
            #expect(throws: CanvasAgentConfigureRefusal.noSession(agent: .codex)) {
                try CanvasAgentConfigurePlan.make(
                    agent: .codex, request: .init(model: "gpt-5"), strategy: nil, sessionID: id)
            }
        }
    }

    @Test("Per-agent allowlists refuse foreign efforts and modes")
    func perAgentAllowlists() {
        #expect(throws: CanvasAgentConfigureRefusal.invalidEffort(agent: .codex)) {
            try CanvasAgentConfigurePlan.make(
                agent: .codex, request: .init(effort: "xhigh"), strategy: nil, sessionID: "t")
        }
        #expect(throws: CanvasAgentConfigureRefusal.invalidMode(agent: .claude)) {
            try CanvasAgentConfigurePlan.make(
                agent: .claude, request: .init(mode: "read_only"), strategy: .resume,
                sessionID: "t")
        }
        #expect(throws: CanvasAgentConfigureRefusal.nothingToChange) {
            try CanvasAgentConfigurePlan.make(
                agent: .claude, request: .init(), strategy: nil, sessionID: nil)
        }
    }

    @Test("Every typed line is a fixed template plus one allowlisted token")
    func templatesHoldNoFreeText() throws {
        let allowed = ["/model ", "/effort ", "/status", "/exit", "/quit"]
        for agent in CanvasAgentConfigureAgent.allCases {
            for strategy in CanvasAgentConfigureStrategy.allCases {
                let request = CanvasAgentConfigureRequest(
                    model: "gpt-5", effort: agent.efforts.first,
                    mode: strategy == .resume ? agent.modes.first : nil)
                guard
                    let plan = try? CanvasAgentConfigurePlan.make(
                        agent: agent, request: request, strategy: strategy, sessionID: "s-1")
                else { continue }
                for step in plan.steps {
                    switch step {
                    case .agentLine(let line), .exitAgent(let line):
                        #expect(allowed.contains { line.hasPrefix($0) })
                        #expect(!CanvasAgentText.hasControl(line))
                        let token = line.split(separator: " ").dropFirst().joined()
                        #expect(token.isEmpty || token == "gpt-5" || agent.efforts.contains(token))
                    case .shellCommand(let argv):
                        #expect(CanvasAgentShell.refusal(for: argv) == nil)
                        #expect(argv.allSatisfy { !$0.contains(" ") && !$0.contains(";") })
                    case .waitForAgent, .readback: break
                    }
                }
            }
        }
    }

    @Test("History resume and agent_configure build the same argv")
    func historyResumeFlags() {
        let claude = AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc")
        #expect(
            AgentHistoryResumeCommand.arguments(for: claude, model: nil, effort: nil, mode: nil)
                == ["claude", "--resume", "abc"])
        #expect(
            AgentHistoryResumeCommand.arguments(
                for: claude, model: "sonnet", effort: "auto", mode: "plan")
                == ["claude", "--resume", "abc", "--model", "sonnet", "--permission-mode", "plan"])
        let codex = AgentHistorySessionKey(provider: .codex, sessionID: "t")
        #expect(
            AgentHistoryResumeCommand.arguments(
                for: codex, model: nil, effort: nil, mode: "read_only")
                == ["codex", "resume", "t", "-c", "sandbox_mode=\"read-only\""])
        #expect(
            AgentHistoryResumeCommand.arguments(for: codex, model: "a b", effort: nil, mode: nil)
                == nil)
    }

    // MARK: Readiness

    @Test("Readiness: only a finished or quiet agent takes a change")
    func readiness() {
        typealias Readiness = CanvasAgentConfigureReadiness
        #expect(Readiness.check(hookState: .finished, secondsSinceOutput: 0) == .idle)
        #expect(Readiness.check(hookState: .working, secondsSinceOutput: 60) == .busy)
        #expect(Readiness.check(hookState: .needsInput, secondsSinceOutput: 60) == .waitingForUser)
        #expect(
            Readiness.check(hookState: .waitingForPermission, secondsSinceOutput: nil)
                == .waitingForUser)
        #expect(Readiness.check(hookState: .ended, secondsSinceOutput: nil) == .notRunning)
        #expect(Readiness.check(hookState: nil, secondsSinceOutput: 1) == .busyWithoutHooks)
        #expect(Readiness.check(hookState: nil, secondsSinceOutput: 5) == .idle)
        #expect(Readiness.check(hookState: nil, secondsSinceOutput: nil) == .idle)
        #expect(Readiness.busy.canQueue)
        #expect(!Readiness.busyWithoutHooks.canQueue)
        #expect(Readiness.busy.code == "agent_busy")
        #expect(Readiness.busyWithoutHooks.message.contains("hooks"))
    }

    // MARK: Readback

    @Test("Readback ignores the typed command's echo and old lines")
    func readbackMatcher() {
        let matcher = CanvasAgentReadbackMatcher(
            tokens: ["sonnet", "low"], ignoredLineMarkers: ["/model", "/effort"])
        let before = ["> earlier prompt", "⎿ Set model to Opus"]
        let echoOnly = before + ["> /model sonnet", "> /effort low"]
        #expect(!matcher.matches(before: before, after: echoOnly))
        let answered =
            echoOnly + [
                "⎿ Set model to Sonnet 4.5 (claude-sonnet-4-5)", "⎿ Set effort level to low",
            ]
        #expect(matcher.matches(before: before, after: answered))
        // "below" is not the word "low".
        let partial = echoOnly + ["⎿ Set model to sonnet", "⎿ see below"]
        #expect(!matcher.matches(before: before, after: partial))
        // A line already on screen before the change never confirms it.
        let stale = ["⎿ Set model to sonnet", "⎿ effort low"]
        #expect(!matcher.matches(before: stale, after: stale))
    }

    @Test("Readback text is scrubbed and holds at most 200 characters")
    func readbackText() {
        let matcher = CanvasAgentReadbackMatcher(tokens: ["x"], ignoredLineMarkers: ["/model"])
        let secret = "sk-" + String(repeating: "A", count: 30)
        let text = matcher.readback(
            before: [], after: ["> /model x", "key \(secret)", String(repeating: "y", count: 400)])
        #expect(!text.contains(secret))
        #expect(!text.contains("/model"))
        #expect(text.count <= CanvasAgentReadbackMatcher.maximumReadbackCharacters)
    }

    @Test("The MCP definition lists agent_configure with enums from the allowlists")
    func definition() throws {
        let definition = try #require(
            CanvasAgentToolCatalog.definitions.first { $0["name"] as? String == "agent_configure" })
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(
            Set(properties.keys) == ["node_id", "model", "effort", "mode", "strategy", "queue"])
        #expect(schema["required"] as? [String] == ["node_id"])
    }
}
