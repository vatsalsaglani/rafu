import Foundation
import Testing

@testable import RafuCore

private let node = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
private let bypass = "--dangerously-bypass-approvals-and-sandbox"

@Suite("Full access for Codex in Ensemble terminals")
struct CanvasAgentFullAccessTests {
    // MARK: Launch line

    @Test("The default launch line has no bypass flag; full puts it first, before the task")
    func launchLine() {
        #expect(
            CanvasAgentLaunch.argv(agent: "codex", prompt: "run tests", model: nil, effort: nil)
                == ["codex", "run tests"])
        #expect(
            CanvasAgentLaunch.argv(
                agent: "codex", prompt: "run tests", model: "gpt-5", effort: "high",
                fullAccess: true)
                == [
                    "codex", bypass, "-m", "gpt-5", "-c", "model_reasoning_effort=\"high\"",
                    "run tests",
                ])
        #expect(
            CanvasAgentLaunch.argv(
                agent: "codex", prompt: nil, model: nil, effort: nil, fullAccess: true)
                == ["codex", bypass])
        for agent in ["claude", "opencode", "gemini"] {
            #expect(
                CanvasAgentLaunch.argv(
                    agent: agent, prompt: nil, model: nil, effort: nil, fullAccess: true) == nil)
        }
    }

    // MARK: Parsing

    @Test("terminal_create accepts access default or full for codex only")
    func parseAccess() throws {
        let full = try CanvasAgentToolCall.parse(
            tool: "terminal_create", arguments: ["agent": "codex", "access": "FULL"])
        #expect(full.access == "full")
        #expect(full.grantsFullAccess)
        #expect(full.risk == .sensitive)
        #expect(full.approvalSummary.contains { $0.hasPrefix("Full access:") })
        let plain = try CanvasAgentToolCall.parse(
            tool: "terminal_create", arguments: ["agent": "codex", "access": "default"])
        #expect(!plain.grantsFullAccess)
        #expect(!plain.approvalSummary.contains { $0.hasPrefix("Full access:") })
        #expect(
            !(try CanvasAgentToolCall.parse(
                tool: "terminal_create", arguments: ["agent": "codex"])).grantsFullAccess)
    }

    @Test("access for any agent other than codex is refused with a clear reason")
    func refuseOtherAgents() {
        for arguments: [String: Any] in [
            ["agent": "claude", "access": "full"],
            ["agent": "gemini", "access": "full"],
            ["agent": "claude", "access": "default"],
            ["command": ["ls"], "access": "full"],
            ["access": "full"],
        ] {
            #expect(
                throws: CanvasAgentToolError.invalidArgumentReason(
                    key: "access", reason: CanvasAgentFullAccess.onlyCodexReason)
            ) {
                try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: arguments)
            }
        }
        #expect(throws: CanvasAgentToolError.invalidArgument("access")) {
            try CanvasAgentToolCall.parse(
                tool: "terminal_create", arguments: ["agent": "codex", "access": "yolo"])
        }
        #expect(throws: CanvasAgentToolError.unexpectedArgument("access")) {
            try CanvasAgentToolCall.parse(
                tool: "terminal_send", arguments: ["node_id": node, "text": "x", "access": "full"])
        }
    }

    @Test("A command may not ask Codex for full access by itself")
    func refuseBypassInCommands() {
        for command in [
            ["codex", bypass],
            ["codex", "-s", "danger-full-access"],
            ["codex", "-c", "sandbox_mode=\"danger-full-access\""],
        ] {
            #expect(
                throws: CanvasAgentToolError.invalidArgumentReason(
                    key: "command", reason: CanvasAgentFullAccess.commandReason)
            ) {
                try CanvasAgentToolCall.parse(
                    tool: "terminal_create", arguments: ["command": command])
            }
            #expect(throws: CanvasAgentToolError.self) {
                try CanvasAgentToolCall.parse(
                    tool: "terminal_send", arguments: ["node_id": node, "command": command])
            }
        }
        #expect(
            (try? CanvasAgentToolCall.parse(
                tool: "terminal_create", arguments: ["command": ["codex", "-s", "read-only"]]))
                != nil)
    }

    @Test("terminal_create publishes access with both values")
    func schema() throws {
        let definition = try #require(
            CanvasAgentToolCatalog.definitions.first { $0["name"] as? String == "terminal_create" })
        let input = try #require(definition["inputSchema"] as? [String: Any])
        let schema = try #require(input["properties"] as? [String: Any])
        let access = try #require(schema["access"] as? [String: Any])
        #expect(access["enum"] as? [String] == ["default", "full"])
        #expect((access["description"] as? String)?.contains("Allow Full access agents") == true)
    }

    // MARK: Policy

    @Test("Switch Off refuses with the switch's name; Agent control Off refuses as before")
    func switchOff() {
        for mode in [CanvasAgentControlMode.ask, .allow] {
            let decision = CanvasAgentFullAccess.decide(mode: mode, switchIsOn: false)
            #expect(decision == .deny(CanvasAgentFullAccess.switchOffMessage))
        }
        #expect(CanvasAgentFullAccess.switchOffMessage.contains("Allow Full access agents"))
        #expect(
            CanvasAgentFullAccess.decide(mode: .off, switchIsOn: true)
                == .deny(CanvasAgentPolicy.offMessage))
    }

    @Test("With the switch On, full access asks every time, in Ask and in Allow")
    func asksEveryTime() {
        #expect(CanvasAgentFullAccess.decide(mode: .ask, switchIsOn: true) == .ask)
        #expect(CanvasAgentFullAccess.decide(mode: .allow, switchIsOn: true) == .ask)
    }

    // MARK: agent_configure

    @Test("agent_configure mode full is Codex only and resumes with the bypass flag")
    func configureFull() throws {
        let call = try CanvasAgentToolCall.parse(
            tool: "agent_configure", arguments: ["node_id": node, "mode": "full"])
        #expect(call.grantsFullAccess)
        let plan = try CanvasAgentConfigurePlan.make(
            agent: .codex, request: .init(mode: "full"), strategy: nil, sessionID: "abc-123")
        #expect(plan.steps.contains(.shellCommand(["codex", "resume", "abc-123", bypass])))
        #expect(throws: CanvasAgentConfigureRefusal.invalidMode(agent: .claude)) {
            try CanvasAgentConfigurePlan.make(
                agent: .claude, request: .init(mode: "full"), strategy: .resume,
                sessionID: "abc-123")
        }
        let workspace = try CanvasAgentToolCall.parse(
            tool: "agent_configure", arguments: ["node_id": node, "mode": "workspace_write"])
        #expect(!workspace.grantsFullAccess)
    }

    // MARK: Launcher

    @Test("The launcher moves the bypass flag from the terminal UI to the private server")
    func splitArguments() {
        let split = CanvasAgentFullAccess.splitCodexArguments([bypass, "-m", "gpt-5", "fix it"])
        #expect(split.terminal == ["-m", "gpt-5", "fix it"])
        #expect(
            split.server == [
                "-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"danger-full-access\"",
            ])
        let resume = CanvasAgentFullAccess.splitCodexArguments(["resume", "abc", bypass])
        #expect(resume.terminal == ["resume", "abc"])
        #expect(!resume.server.isEmpty)
        let plain = CanvasAgentFullAccess.splitCodexArguments(["-m", "gpt-5"])
        #expect(plain.terminal == ["-m", "gpt-5"])
        #expect(plain.server.isEmpty)
        let quoted = CanvasAgentFullAccess.splitCodexArguments(["--", bypass])
        #expect(quoted.terminal == ["--", bypass])
        #expect(quoted.server.isEmpty)
        let alias = CanvasAgentFullAccess.splitCodexArguments(["--yolo", "fix"])
        #expect(alias.terminal == ["fix"])
        #expect(!alias.server.isEmpty)
    }

    // MARK: Guards on agent input

    @Test("A prompt that starts with \"-\" is refused, so a flag cannot pass as the task")
    func promptFlag() {
        for prompt in [bypass, " --yolo", "\n-s danger-full-access", "-x"] {
            #expect(
                throws: CanvasAgentToolError.invalidArgumentReason(
                    key: "prompt", reason: CanvasAgentFullAccess.promptReason)
            ) {
                try CanvasAgentToolCall.parse(
                    tool: "terminal_create", arguments: ["agent": "codex", "prompt": prompt])
            }
            #expect(
                CanvasAgentLaunch.argv(agent: "codex", prompt: prompt, model: nil, effort: nil)
                    == nil)
        }
        #expect(
            CanvasAgentLaunch.argv(agent: "codex", prompt: "fix -x", model: nil, effort: nil)
                == ["codex", "fix -x"])
    }

    @Test("terminal_send text that holds a full-access flag is refused")
    func sendTextFlag() {
        for text in [
            "codex \(bypass)", "codex --yolo", "codex -s danger-full-access",
        ] {
            #expect(
                throws: CanvasAgentToolError.invalidArgumentReason(
                    key: "text", reason: CanvasAgentFullAccess.textReason)
            ) {
                try CanvasAgentToolCall.parse(
                    tool: "terminal_send", arguments: ["node_id": node, "text": text])
            }
        }
        #expect(
            (try? CanvasAgentToolCall.parse(
                tool: "terminal_send", arguments: ["node_id": node, "text": "run the tests"]))
                != nil)
    }

    @Test("--yolo, the flag inside sh -c, and every sandbox spelling are refused in a command")
    func commandGaps() {
        for command in [
            ["codex", "exec", "--yolo", "task"],
            ["codex", "resume", "--last", "--yolo"],
            ["sh", "-c", "codex \(bypass)"],
            ["codex", "--sandbox", "danger-full-access"],
            ["codex", "--sandbox=danger-full-access"],
        ] {
            #expect(CanvasAgentFullAccess.commandRequestsFullAccess(command))
            #expect(throws: CanvasAgentToolError.self) {
                try CanvasAgentToolCall.parse(
                    tool: "terminal_create", arguments: ["command": command])
            }
        }
    }

    @Test("A change to a full-access node carries the keeps-full-access line")
    func keepsFullAccessLine() throws {
        var call = try CanvasAgentToolCall.parse(
            tool: "agent_configure", arguments: ["node_id": node, "model": "gpt-5"])
        #expect(!call.approvalSummary.contains(CanvasAgentFullAccess.keepsFullAccessLine))
        call.keepsFullAccess = true
        #expect(call.approvalSummary.contains(CanvasAgentFullAccess.keepsFullAccessLine))
    }
}
