import Foundation
import Testing

@testable import RafuCore

/// Every prompt name an agent can send must map to a class Rafu shows. When
/// Claude Code or Codex is updated, refresh these fixtures (see the
/// version-bump checklist in the agent prompt coverage reference note) and run
/// this suite. With `RAFU_CODEX_SCHEMA_DIR` set to the output folder of
/// `codex app-server generate-ts --out <dir>`, the second test also reads the
/// generated `ServerRequest.ts` and fails on a method the fixture lacks.
@Suite("Agent prompt coverage")
struct AgentPromptCoverageTests {
    /// The tools table of the Claude Code tools reference, fetched
    /// 2026-11-22 for Claude Code 2.1.330 (53 names).
    static let claudeVersion = "Claude Code 2.1.330"
    static let claudeToolNames = [
        "Agent", "Artifact", "AskUserQuestion", "Bash", "CronCreate", "CronDelete", "CronList",
        "Edit", "EndConversation", "EnterPlanMode", "EnterWorktree", "ExitPlanMode",
        "ExitWorktree", "Glob", "Grep", "ListAgents", "ListMcpResourcesTool", "ListPlugins",
        "ListSkills", "LSP", "Monitor", "NotebookEdit", "PowerShell", "propose_skills",
        "PushNotification", "Read", "ReadMcpResourceTool", "RemoteTrigger", "ReportFindings",
        "ScheduleWakeup", "SearchPlugins", "SearchSkills", "SendFeedback", "SendMessage",
        "SendUserFile", "ShareOnboardingGuide", "Skill", "SubagentHandback",
        "SuggestPluginInstall", "SuggestSkills", "TaskCreate", "TaskGet", "TaskList",
        "TaskOutput", "TaskStop", "TaskUpdate", "TodoWrite", "ToolSearch", "WaitForMcpServers",
        "WebFetch", "WebSearch", "Workflow", "Write",
    ]

    /// Every `ServerRequest` method of the schema Codex CLI 0.171.0
    /// generated (10 methods).
    static let codexVersion = "Codex CLI 0.171.0"
    static let codexServerRequestMethods = [
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
        "item/tool/requestUserInput", "mcpServer/elicitation/request",
        "item/permissions/requestApproval", "item/tool/call",
        "account/chatgptAuthTokens/refresh", "attestation/generate", "applyPatchApproval",
        "execCommandApproval",
    ]

    @Test("Every Claude Code tool maps to a class other than unclassified")
    func claudeTools() {
        #expect(Self.claudeToolNames.count == 53, "\(Self.claudeVersion)")
        #expect(Set(Self.claudeToolNames).count == Self.claudeToolNames.count)
        for name in Self.claudeToolNames {
            #expect(
                AgentPermissionRequestSummary.classification(forToolName: name) != .unclassified,
                "\(name) (\(Self.claudeVersion))")
        }
        // The special classes keep their own cards.
        let classify = AgentPermissionRequestSummary.classification(forToolName:)
        #expect(classify("AskUserQuestion") == .questions)
        #expect(classify("ExitPlanMode") == .plan)
        #expect(classify("Bash") == .command)
        #expect(classify("NotebookEdit") == .toolCall)
    }

    @Test("Every Codex server request method maps to a class other than unclassified")
    func codexMethods() throws {
        #expect(Self.codexServerRequestMethods.count == 10, "\(Self.codexVersion)")
        for method in Self.codexServerRequestMethods {
            #expect(
                CanvasAgentRequest.classify(method: method) != .unclassified,
                "\(method) (\(Self.codexVersion))")
        }
        guard let folder = ProcessInfo.processInfo.environment["RAFU_CODEX_SCHEMA_DIR"] else {
            return
        }
        let file = URL(fileURLWithPath: folder).appending(path: "ServerRequest.ts")
        let text = try String(contentsOf: file, encoding: .utf8)
        let methods = Self.methods(inServerRequestSchema: text)
        #expect(!methods.isEmpty, "No method found in \(file.path)")
        for method in methods {
            #expect(
                Self.codexServerRequestMethods.contains(method),
                "The generated schema has \(method); add it to the fixture and classify it.")
        }
    }

    @Test("The schema reader finds every method of a generated ServerRequest union")
    func schemaReader() {
        let sample =
            #"export type ServerRequest ={ "method": "item/tool/call", id: RequestId, params: P, } | { "method": "attestation/generate", id: RequestId, params: Q, };"#
        #expect(
            Self.methods(inServerRequestSchema: sample) == [
                "item/tool/call", "attestation/generate",
            ])
    }

    @Test("An invented name is unclassified and still yields a notice request")
    func inventedNames() {
        let claude = AgentPermissionRequestSummary.classify(
            toolName: "Invented Tool!", toolInput: ["x": 1])
        #expect(claude.classification == .unclassified)
        let reason = claude.noticeReason
        #expect(reason == "Claude Code asks to use Invented Tool!. Open the terminal to answer.")
        let claudeNotice = CanvasAgentRequest(kind: .notice, reason: reason)
        #expect(claudeNotice.kind == .notice)
        #expect(claudeNotice.terminalOnly)
        #expect(claudeNotice.options.isEmpty)

        let method = "item/invented/requestSomething"
        #expect(CanvasAgentRequest.classify(method: method) == .unclassified)
        let word = method.split(separator: "/").last.map(String.init)
        let codexNotice = CanvasAgentRequest(
            kind: .notice, reason: word, text: "The agent's own message")
        #expect(codexNotice.kind == .notice)
        #expect(codexNotice.terminalOnly)
    }

    /// The `"method": "<name>"` values of a generated `ServerRequest.ts`.
    static func methods(inServerRequestSchema text: String) -> [String] {
        let marker = #""method": ""#
        var methods: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: marker) {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            methods.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return methods
    }
}
