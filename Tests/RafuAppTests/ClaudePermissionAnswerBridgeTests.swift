import Foundation
import RafuCore
import Testing

@testable import RafuApp

private func event(
    tool: String, input: [String: Any], name: String = "PermissionRequest",
    includesSummary: Bool = true, provider: AgentHookProvider = .claude
) throws -> AgentHookEvent {
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "s1", "hook_event_name": name, "cwd": "/Users/me/repo",
        "tool_name": tool, "tool_input": input,
    ])
    return try AgentHookEvent(
        provider: provider, payload: payload, includesRequestSummary: includesSummary)
}

private func temporaryBridge() throws -> (bridge: ClaudePermissionAnswerBridge, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
    let spool = root.appending(path: "AgentTracking", directoryHint: .isDirectory)
        .appending(path: "spool", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
    return (ClaudePermissionAnswerBridge(channel: AgentAnswerChannel(spool: spool)), root)
}

@Suite("Claude permission answer bridge")
struct ClaudePermissionAnswerBridgeTests {
    @Test("A Bash request becomes a command request keyed by the event id")
    func bash() throws {
        let hook = try event(
            tool: "Bash", input: ["command": "swift build", "description": "Build it"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.key == hook.id)
        #expect(request.kind == .command)
        #expect(request.command == "swift build")
        #expect(request.reason == "Build it")
        #expect(request.cwd == "/Users/me/repo")
        #expect(!request.terminalOnly)
        #expect(request.receivedAt == hook.time)
    }

    @Test("A command request offers Run, Deny and Deny and stop, and no session grant")
    func commandOptions() throws {
        let request = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Bash", input: ["command": "ls"])))
        #expect(request.options.map(\.label) == ["Run", "Deny", "Deny and stop"])
        #expect(!request.permits(.acceptForSession))
        #expect(request.permits(.accept))
        #expect(request.permits(.cancel))
    }

    @Test("A file change request carries the content and is answerable")
    func theFileChangeRequestCarriesTheContent() throws {
        let write = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(
                    tool: "Write",
                    input: ["file_path": "/Users/me/repo/a.swift", "content": "body"])))
        #expect(write.kind == .fileChange)
        #expect(write.command == nil)
        #expect(write.reason == "Change file: /Users/me/repo/a.swift")
        #expect(!write.terminalOnly)
        #expect(write.fileChanges.first?.body == "body")
        #expect(write.fileChanges.first?.kind == .overwrite)
        #expect(
            write.options.map(\.label) == ["Allow", "Deny", "Deny and stop"])
        let edit = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(
                    tool: "Edit",
                    input: ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b"])))
        #expect(!edit.terminalOnly)
        #expect(edit.fileChanges.first?.body == "- a\n+ b")
        // A tool input of a shape Rafu does not know stays in the terminal.
        let odd = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Edit", input: ["file_path": "/r/a.swift"])))
        #expect(odd.terminalOnly)
        #expect(odd.options.isEmpty)
        #expect(!odd.permits(.accept))
    }

    @Test("Accept on a file change maps to allow")
    func acceptOnAFileChangeMapsToAllow() throws {
        let hook = try event(tool: "Write", input: ["file_path": "/r/a", "content": "x"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.permits(.accept))
        #expect(
            ClaudePermissionAnswerBridge.answer(for: .accept, eventID: hook.id)
                == AgentPermissionAnswer(eventID: hook.id, verdict: .allow))
        #expect(!request.permits(.acceptForSession))
    }

    @Test("Cancel on a file change maps to deny and stop")
    func cancelMapsToDenyAndStop() throws {
        let hook = try event(tool: "Write", input: ["file_path": "/r/a", "content": "x"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.permits(.cancel))
        #expect(
            ClaudePermissionAnswerBridge.answer(for: .cancel, eventID: hook.id)
                == AgentPermissionAnswer(eventID: hook.id, verdict: .deny, interrupt: true))
    }

    @Test("An MCP tool request becomes a tool call request keyed by the event id")
    func mcpToolCall() throws {
        let name = "mcp__claude_ai_Atlassian_MCP__atlassianUserInfo"
        let hook = try event(tool: name, input: [:])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.key == hook.id)
        #expect(request.kind == .toolCall)
        #expect(request.command == "{}")
        #expect(request.reason == "Atlassian MCP (claude.ai): atlassianUserInfo\n" + name)
        #expect(request.cwd == "/Users/me/repo")
        #expect(!request.terminalOnly)
        #expect(!request.offersSessionAllow)
        #expect(request.receivedAt == hook.time)
        #expect(request.options.map(\.label) == ["Allow", "Deny", "Deny and stop"])
        #expect(!request.permits(.acceptForSession))
    }

    @Test("An MCP tool request whose arguments do not fit needs the terminal")
    func mcpToolCallIncomplete() throws {
        let long = String(repeating: "x", count: CanvasAgentRequest.Limits.commandBytes)
        let request = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "mcp__srv__tool", input: ["q": long])))
        #expect(request.kind == .toolCall)
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
        #expect(!request.permits(.accept))
        let bidi = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "mcp__srv__tool", input: ["q": "a\u{202E}b"])))
        #expect(bidi.terminalOnly)
    }

    @Test("A built-in tool becomes the generic tool card, answered like Bash")
    func builtInToolCall() throws {
        let fetch = try event(
            tool: "WebFetch", input: ["url": "https://example.com", "prompt": "Sum"])
        #expect(ClaudePermissionAnswerBridge.isAnswerable(fetch))
        #expect(ClaudePermissionAnswerBridge.helperWaits(fetch))
        let request = try #require(ClaudePermissionAnswerBridge.request(for: fetch))
        #expect(request.kind == .toolCall)
        #expect(request.reason == "Claude Code tool: WebFetch\nWebFetch")
        #expect(request.command?.contains("https://example.com") == true)
        #expect(!request.terminalOnly)
        #expect(request.options.map(\.label) == ["Allow", "Deny", "Deny and stop"])
        for tool in ["Read", "Glob", "Grep", "WebSearch", "NotebookEdit", "Skill", "Agent"] {
            let other = try #require(
                ClaudePermissionAnswerBridge.request(
                    for: try event(tool: tool, input: ["x": "y"])), "\(tool)")
            #expect(other.kind == .toolCall, "\(tool)")
            #expect(!other.terminalOnly, "\(tool)")
        }
    }

    @Test("A bad tool name becomes a read-only notice, and its helper does not wait")
    func unclassifiedNotice() throws {
        let bad = try event(tool: "mcp__srv__bad name", input: [:])
        #expect(ClaudePermissionAnswerBridge.isAnswerable(bad))
        #expect(!ClaudePermissionAnswerBridge.helperWaits(bad))
        let request = try #require(ClaudePermissionAnswerBridge.request(for: bad))
        #expect(request.kind == .notice)
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
        #expect(
            request.reason
                == "Claude Code asks to use mcp__srv__bad name. Open the terminal to answer.")
        #expect(bad.requestShape == "claude ? object[0]{}")
    }

    @Test("An AskUserQuestion request becomes a question set keyed by index")
    func questionSet() throws {
        let hook = try event(
            tool: "AskUserQuestion",
            input: [
                "questions": [
                    [
                        "question": "Which color?", "header": "Color", "multiSelect": false,
                        "options": [
                            ["label": "Red", "description": "warm"],
                            ["label": "Blue", "description": "cool"],
                        ],
                    ],
                    [
                        "question": "Which fruits?", "header": "Fruits", "multiSelect": true,
                        "options": [
                            ["label": "Apple", "description": ""],
                            ["label": "Banana", "description": ""],
                        ],
                    ],
                ]
            ])
        #expect(ClaudePermissionAnswerBridge.helperWaits(hook))
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.key == hook.id)
        #expect(request.kind == .userInput)
        #expect(!request.terminalOnly)
        #expect(request.questions.map(\.id) == ["0", "1"])
        #expect(request.questions.map(\.allowsMultiple) == [false, true])
        #expect(request.questions.allSatisfy { $0.allowsFreeText })
        #expect(request.options.isEmpty)
        #expect(!request.permits(.accept))
        let decision = CanvasAgentRequestDecision.answers([
            "0": QuestionAnswer(labels: [], text: "Green"),
            "1": QuestionAnswer(labels: ["Apple", "Banana"]),
        ])
        #expect(request.permits(decision))
        #expect(
            ClaudePermissionAnswerBridge.answer(for: decision, eventID: hook.id)
                == AgentPermissionAnswer(
                    eventID: hook.id, verdict: .allow,
                    answers: [
                        .init(index: 0, labels: [], text: "Green"),
                        .init(index: 1, labels: ["Apple", "Banana"]),
                    ]))
    }

    @Test("Answers with an id that is not an index map to nothing")
    func badAnswerIDs() {
        let id = UUID()
        for key in ["q", "-1", "01", " 1", ""] {
            #expect(
                ClaudePermissionAnswerBridge.answer(
                    for: .answers([key: "Red"]), eventID: id) == nil, "\(key)")
        }
        #expect(ClaudePermissionAnswerBridge.answer(for: .answers([:]), eventID: id) == nil)
    }

    @Test("An ExitPlanMode request becomes a read-only plan; its helper does not wait")
    func plan() throws {
        let hook = try event(
            tool: "ExitPlanMode",
            input: ["plan": "## Plan\n1. Build", "planFilePath": "/Users/me/.claude/plans/p.md"])
        #expect(!ClaudePermissionAnswerBridge.helperWaits(hook))
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.kind == .plan)
        #expect(request.reason == "/Users/me/.claude/plans/p.md")
        #expect(request.text == "## Plan\n1. Build")
        #expect(!request.textIsCut)
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
    }

    @Test("One understood suggestion is a hidden rule choice; remember stays off")
    func rememberRule() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "hook_event_name": "PermissionRequest", "cwd": "/r",
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
            "permission_suggestions": [
                [
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "npm test"]],
                    "behavior": "allow", "destination": "localSettings",
                ]
            ],
        ])
        let hook = try AgentHookEvent(
            provider: .claude, payload: payload, includesRequestSummary: true)
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(
            request.persistChoices == [
                .init(kind: .rule, line: "Add rule Bash(npm test) to local settings")
            ])
        // Hidden under today's policy.
        #expect(request.options.map(\.label) == ["Run", "Deny", "Deny and stop"])
        #expect(!request.permits(.acceptAndRemember(.rule)))
        #expect(
            ClaudePermissionAnswerBridge.answer(for: .acceptAndRemember(.rule), eventID: hook.id)
                == nil)
        #expect(
            ClaudePermissionAnswerBridge.answer(
                for: .acceptAndRemember(.rule), eventID: hook.id, policy: .all)
                == AgentPermissionAnswer(eventID: hook.id, verdict: .allow, remember: true))
        #expect(
            ClaudePermissionAnswerBridge.answer(
                for: .acceptAndRemember(.always), eventID: hook.id, policy: .all) == nil)
    }

    @Test("A notification that asks for the person becomes a read-only notice")
    func notificationNotice() throws {
        func notification(_ type: String, message: String?) throws -> AgentHookEvent {
            var object: [String: Any] = [
                "session_id": "s1", "hook_event_name": "Notification", "cwd": "/r",
                "notification_type": type,
            ]
            if let message { object["message"] = message }
            return try AgentHookEvent(
                provider: .claude, payload: JSONSerialization.data(withJSONObject: object))
        }
        let network = try notification(
            "permission_prompt", message: "Claude needs your permission to use the network")
        let notice = try #require(ClaudePermissionAnswerBridge.notice(for: network))
        #expect(notice.key == network.id)
        #expect(notice.kind == .notice)
        #expect(notice.reason == "Permission request")
        #expect(notice.text == "Claude needs your permission to use the network")
        #expect(notice.terminalOnly)
        #expect(!ClaudePermissionAnswerBridge.helperWaits(network))
        #expect(
            ClaudePermissionAnswerBridge.notice(
                for: try notification("elicitation_dialog", message: "Form"))?.reason
                == "MCP server form")
        #expect(
            ClaudePermissionAnswerBridge.notice(
                for: try notification("elicitation_url_dialog", message: "Link"))?.reason
                == "Sign-in in browser")
        // Not a prompt (a background session's wait is not Needs you), or no
        // text: no notice.
        #expect(
            ClaudePermissionAnswerBridge.notice(
                for: try notification("agent_needs_input", message: "Wait")) == nil)
        #expect(
            ClaudePermissionAnswerBridge.notice(
                for: try notification("idle_prompt", message: "Idle")) == nil)
        #expect(
            ClaudePermissionAnswerBridge.notice(
                for: try notification("permission_prompt", message: nil)) == nil)
    }

    @Test("Allow, Deny and Deny and stop on a tool call give the same answers as for Bash")
    func mcpToolCallDecisions() throws {
        let hook = try event(tool: "mcp__srv__tool", input: [:])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        func answer(_ decision: CanvasAgentRequestDecision) -> AgentPermissionAnswer? {
            #expect(request.permits(decision))
            return ClaudePermissionAnswerBridge.answer(for: decision, eventID: hook.id)
        }
        #expect(answer(.accept) == AgentPermissionAnswer(eventID: hook.id, verdict: .allow))
        #expect(answer(.decline) == AgentPermissionAnswer(eventID: hook.id, verdict: .deny))
        #expect(
            answer(.cancel)
                == AgentPermissionAnswer(eventID: hook.id, verdict: .deny, interrupt: true))
    }

    @Test("A command or path that was cut or changed needs the terminal")
    func incomplete() throws {
        let long = String(repeating: "x", count: CanvasAgentRequest.Limits.commandBytes + 1)
        let command = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Bash", input: ["command": long])))
        #expect(command.terminalOnly)
        #expect(command.options.isEmpty)
        let path = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Write", input: ["file_path": "/tmp/a\u{7}b"])))
        #expect(path.terminalOnly)
        #expect(path.options.isEmpty)
    }

    @Test("A Bash request that leaves the sandbox needs the terminal")
    func unsandboxed() throws {
        let request = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(
                    tool: "Bash", input: ["command": "ls", "dangerouslyDisableSandbox": true])))
        #expect(request.command == "ls")
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
    }

    @Test("Only a Claude PermissionRequest with a summary is answerable")
    func notAnswerable() throws {
        let plain = try event(tool: "Bash", input: ["command": "ls"], includesSummary: false)
        #expect(ClaudePermissionAnswerBridge.request(for: plain) == nil)
        let other = try event(tool: "Bash", input: ["command": "ls"], name: "PreToolUse")
        #expect(ClaudePermissionAnswerBridge.request(for: other) == nil)
        let codex = try event(tool: "Bash", input: ["command": "ls"], provider: .codex)
        #expect(ClaudePermissionAnswerBridge.request(for: codex) == nil)
    }

    @Test("Decisions map to hook answers; session grants and bad answers do not")
    func decisions() {
        let id = UUID()
        func answer(_ decision: CanvasAgentRequestDecision) -> AgentPermissionAnswer? {
            ClaudePermissionAnswerBridge.answer(for: decision, eventID: id)
        }
        #expect(answer(.accept) == AgentPermissionAnswer(eventID: id, verdict: .allow))
        #expect(answer(.decline) == AgentPermissionAnswer(eventID: id, verdict: .deny))
        #expect(
            answer(.cancel) == AgentPermissionAnswer(eventID: id, verdict: .deny, interrupt: true))
        #expect(answer(.acceptForSession) == nil)
        #expect(answer(.answers(["q": "yes"])) == nil)
    }

    @Test("A chosen answer is written to the waiting helper once")
    func submit() throws {
        let (bridge, root) = try temporaryBridge()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let answer = CanvasAgentRequestAnswer(key: id, decision: .accept)
        #expect(bridge.submit(answer) == .written)
        #expect(bridge.submit(answer) == .alreadyAnswered)
        #expect(
            bridge.channel.take(eventID: id) == AgentPermissionAnswer(eventID: id, verdict: .allow))
        #expect(
            bridge.submit(CanvasAgentRequestAnswer(key: UUID(), decision: .acceptForSession))
                == .unsupported)
    }

    @Test("Dismiss tells the helper to leave Claude's dialog alone")
    func dismiss() throws {
        let (bridge, root) = try temporaryBridge()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        #expect(bridge.dismiss(eventID: id) == .written)
        let outcome = bridge.channel.wait(eventID: id, timeout: 1, isWatched: { true })
        #expect(outcome == .dismissed)
        #expect(outcome.output == nil)
    }

    @MainActor
    @Test("A request in the store, once chosen, gives the helper's decision JSON")
    func throughTheStore() throws {
        let (bridge, root) = try temporaryBridge()
        defer { try? FileManager.default.removeItem(at: root) }
        let hook = try event(tool: "Bash", input: ["command": "make"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        let store = AgentRequestStore()
        let terminal = UUID()
        #expect(store.open(request, controllerID: terminal) == .opened)
        #expect(
            store.choose(controllerID: terminal, key: hook.id, decision: .acceptForSession)
                == .invalid)
        #expect(store.choose(controllerID: terminal, key: hook.id, decision: .cancel) == .chosen)
        let chosen = try #require(store.pendingDecision(for: terminal))
        #expect(bridge.submit(chosen) == .written)
        let outcome = bridge.channel.wait(eventID: hook.id, timeout: 1, isWatched: { true })
        let json = try #require(outcome.output)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains(#""behavior":"deny""#))
        #expect(text.contains(#""interrupt":true"#))
    }
}
