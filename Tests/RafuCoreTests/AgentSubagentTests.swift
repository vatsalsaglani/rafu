import Foundation
import RafuCore
import Testing

// Sub-agent tracking (ADR 0029 amendment): which hook fields are kept and
// how, and the ledger's per-session sub-agent list.

private func payload(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func event(
    _ name: String,
    session: String = "s",
    provider: AgentHookProvider = .claude,
    at seconds: TimeInterval,
    tool: String? = nil,
    turn: String? = nil,
    subagent: String? = nil,
    type: String? = nil,
    model: String? = nil,
    description: String? = nil
) -> AgentHookEvent {
    AgentHookEvent(
        provider: provider, sessionID: session, turnID: turn, subagentID: subagent,
        hookEventName: name, cwd: "/repo", toolName: tool,
        time: Date(timeIntervalSince1970: seconds), subagentType: type, subagentModel: model,
        subagentDescription: description)
}

@Suite("Sub-agent hook fields")
struct AgentSubagentEventTests {
    @Test("SubagentStart keeps agent_id and a sanitized agent_type")
    func subagentStart() throws {
        let start = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "hook_event_name": "SubagentStart", "session_id": "s", "cwd": "/r",
                "agent_id": "a1", "agent_type": "implementor\u{7}<script>",
            ]))
        #expect(start.subagentID == "a1")
        #expect(start.subagentType == "implementorscript")
        #expect(start.subagentModel == nil)
        #expect(start.subagentDescription == nil)
        #expect(!start.isSubagentSpawn)
    }

    @Test("agent_type is ignored without agent_id (a main-thread --agent session)")
    func agentTypeNeedsAgentID() throws {
        let tool = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash",
                "agent_type": "reviewer",
            ]))
        #expect(tool.subagentType == nil)
    }

    @Test("A spawn keeps type, model, and a short description; never the prompt")
    func spawnKeepsThreeFields() throws {
        let spawn = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Agent",
                "tool_use_id": "t1",
                "tool_input": [
                    "subagent_type": "Explore", "model": "haiku",
                    "description": "Find\n the   hook\tpayload", "prompt": "SECRET PROMPT TEXT",
                ],
            ]))
        #expect(spawn.isSubagentSpawn)
        #expect(spawn.subagentType == "Explore")
        #expect(spawn.subagentModel == "haiku")
        #expect(spawn.subagentDescription == "Find the hook payload")
        let encoded = String(decoding: try JSONEncoder().encode(spawn), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
    }

    @Test("Only Claude Agent/Task PreToolUse counts as a spawn")
    func spawnToolsOnly() throws {
        let input: [String: Any] = ["subagent_type": "Explore", "description": "d"]
        let other = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash",
                "tool_input": input,
            ]))
        #expect(other.subagentDescription == nil && other.subagentType == nil)
        let post = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Task",
                "tool_input": input,
            ]))
        #expect(post.subagentDescription == nil && !post.isSubagentSpawn)
        let codex = try AgentHookEvent(
            provider: .codex,
            payload: payload([
                "hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Agent",
                "tool_input": input,
            ]))
        #expect(!codex.isSubagentSpawn && codex.subagentDescription == nil)
    }

    @Test("Description: one line, whitespace folded, capped at 80 with an ellipsis")
    func descriptionCap() {
        #expect(AgentHookEvent.subagentDescription("  a \u{0}b\r\nc  ") == "a b c")
        #expect(AgentHookEvent.subagentDescription(" \n\t ") == nil)
        #expect(AgentHookEvent.subagentDescription(42) == nil)
        let long = String(repeating: "word ", count: 40)
        let capped = AgentHookEvent.subagentDescription(long)
        #expect(capped?.count ?? 0 <= AgentHookEvent.maximumSubagentDescriptionLength)
        #expect(capped?.hasSuffix("…") == true)
        let exact = String(repeating: "x", count: 80)
        #expect(AgentHookEvent.subagentDescription(exact) == exact)
    }

    @Test("Label: config-name characters only, at most 64, nil when empty")
    func labelSanitizer() {
        #expect(AgentHookEvent.subagentLabel("general-purpose") == "general-purpose")
        #expect(AgentHookEvent.subagentLabel("plugin:agent_v2.1") == "plugin:agent_v2.1")
        #expect(AgentHookEvent.subagentLabel("ünïcödé✨") == "ncd")
        #expect(AgentHookEvent.subagentLabel("✨✨") == nil)
        #expect(AgentHookEvent.subagentLabel(String(repeating: "a", count: 100))?.count == 64)
    }

    @Test("Schema 1: a spool file from an older helper decodes without the new fields")
    func oldHelperDecodes() throws {
        let current = event("SubagentStart", at: 5, subagent: "a1", type: "Explore")
        var object = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(current))
                as? [String: Any])
        for key in ["subagentType", "subagentModel", "subagentDescription"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(
            AgentHookEvent.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.subagentID == "a1")
        #expect(decoded.subagentType == nil)
        var ledger = AgentSessionLedger()
        let accepted = ledger.apply(decoded)
        #expect(accepted)
        #expect(ledger.sessions.first?.subagents.map(\.id) == ["a1"])
    }
}

@Suite("Sub-agent ledger")
struct AgentSubagentLedgerTests {
    private func subagents(_ ledger: AgentSessionLedger) -> [TrackedSubagent] {
        ledger.sessions.first?.subagents ?? []
    }

    @Test("Start adds, stop removes; a spawn's model and description join its start")
    func startStop() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", at: 1))
        ledger.apply(
            event(
                "PreToolUse", at: 2, tool: "Agent", type: "implementor", model: "opus",
                description: "Build the menu card"))
        ledger.apply(event("SubagentStart", at: 3, subagent: "a1", type: "implementor"))
        ledger.apply(event("SubagentStart", at: 4, subagent: "a2", type: "Explore"))
        #expect(subagents(ledger).map(\.id) == ["a1", "a2"])
        let first = subagents(ledger)[0]
        #expect(first.type == "implementor")
        #expect(first.model == "opus")
        #expect(first.taskDescription == "Build the menu card")
        #expect(subagents(ledger)[1].model == nil)

        ledger.apply(event("SubagentStop", at: 5, subagent: "a1", type: "implementor"))
        #expect(subagents(ledger).map(\.id) == ["a2"])
        // A late event never revives a stopped sub-agent.
        ledger.apply(event("PostToolUse", at: 6, tool: "Read", subagent: "a1"))
        #expect(subagents(ledger).map(\.id) == ["a2"])
    }

    @Test("A spawn without a type is claimed by the next start of any type")
    func untypedSpawn() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("PreToolUse", at: 1, tool: "Task", description: "Look around"))
        ledger.apply(event("SubagentStart", at: 2, subagent: "a1", type: "general-purpose"))
        #expect(subagents(ledger).first?.taskDescription == "Look around")
        #expect(subagents(ledger).first?.type == "general-purpose")
    }

    @Test("Parent Stop keeps sub-agents; SessionEnd clears them")
    func parentStopAndSessionEnd() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", at: 1))
        ledger.apply(event("SubagentStart", at: 2, subagent: "a1"))
        ledger.apply(event("SubagentStart", at: 3, subagent: "a2"))
        ledger.apply(event("Stop", at: 4))
        #expect(ledger.sessions.first?.state == .finished)
        #expect(subagents(ledger).count == 2)
        ledger.apply(event("SessionEnd", at: 5))
        #expect(subagents(ledger).isEmpty)
    }

    @Test("A tool event from an unknown sub-agent adds it (Rafu started mid-run)")
    func implicitInsert() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("PostToolUse", at: 1, tool: "Read", subagent: "a9", type: "Explore"))
        #expect(subagents(ledger).map(\.id) == ["a9"])
        #expect(subagents(ledger).first?.type == "Explore")
    }

    @Test("Sub-agents silent for 10 minutes expire; active ones stay")
    func expiry() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("SubagentStart", at: 0, subagent: "old"))
        ledger.apply(event("SubagentStart", at: 500, subagent: "new"))
        let early = ledger.expire(now: Date(timeIntervalSince1970: 590))
        #expect(!early)
        #expect(subagents(ledger).count == 2)
        let late = ledger.expire(now: Date(timeIntervalSince1970: 601))
        #expect(late)
        #expect(subagents(ledger).map(\.id) == ["new"])
    }

    @Test("At most 16 sub-agents per session; the least recently active drops")
    func cap() {
        var ledger = AgentSessionLedger()
        for index in 0..<20 {
            ledger.apply(event("SubagentStart", at: TimeInterval(index), subagent: "a\(index)"))
        }
        let ids = subagents(ledger).map(\.id)
        #expect(ids.count == TrackedAgentSession.maximumSubagents)
        #expect(ids.first == "a4")
        #expect(ids.last == "a19")
    }

    @Test("Sub-agent events skip the turn guard but never change the parent")
    func turnGuardExemption() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", provider: .codex, at: 1, turn: "t2"))
        ledger.apply(event("SubagentStart", provider: .codex, at: 2, turn: "t1", subagent: "c1"))
        let row = ledger.sessions.first
        #expect(row?.subagents.map(\.id) == ["c1"])
        #expect(row?.turnID == "t2")
        // A late parent Stop from the old turn still cannot finish the turn.
        let lateStop = ledger.apply(event("Stop", provider: .codex, at: 3, turn: "t1"))
        #expect(!lateStop)
        #expect(ledger.sessions.first?.state == .working)
    }

    @Test("A sub-agent stop older than the newest event still removes it")
    func outOfOrderStop() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("SubagentStart", at: 1, subagent: "a1"))
        ledger.apply(event("PostToolUse", at: 10, tool: "Read"))
        let stopped = ledger.apply(event("SubagentStop", at: 5, subagent: "a1"))
        #expect(stopped)
        #expect(subagents(ledger).isEmpty)
        #expect(ledger.sessions.first?.updatedAt == Date(timeIntervalSince1970: 10))
    }
}
