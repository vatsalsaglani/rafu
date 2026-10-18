import Foundation
import RafuCore
import Testing

private func event(
    _ name: String,
    session: String = "s",
    provider: AgentHookProvider = .claude,
    at seconds: TimeInterval,
    tool: String? = nil,
    notification: String? = nil,
    turn: String? = nil,
    subagent: String? = nil,
    message: String? = nil,
    cwd: String = "/repo",
    ancestors: [Int32] = []
) -> AgentHookEvent {
    AgentHookEvent(
        provider: provider, sessionID: session, turnID: turn, subagentID: subagent,
        hookEventName: name, cwd: cwd, toolName: tool, notificationType: notification,
        lastAssistantMessage: message, ancestorProcessIDs: ancestors,
        time: Date(timeIntervalSince1970: seconds))
}

@Suite("Agent session ledger")
struct AgentSessionLedgerTests {
    @Test("A turn: prompt works, permission waits, Stop finishes with a reply")
    func turn() throws {
        var ledger = AgentSessionLedger()
        ledger.apply(event("SessionStart", at: 1))
        #expect(ledger.sessions.first?.state == .finished)
        #expect(ledger.sessions.first?.replyEventID == nil)
        ledger.apply(event("UserPromptSubmit", at: 2))
        #expect(ledger.sessions.first?.state == .working)
        ledger.apply(event("PreToolUse", at: 3, tool: "Bash"))
        ledger.apply(event("PermissionRequest", at: 4, tool: "Bash"))
        let waiting = try #require(ledger.sessions.first)
        #expect(waiting.state == .waitingForPermission)
        #expect(waiting.needsAttention)
        #expect(waiting.lastTool == "Bash")
        ledger.apply(event("PostToolUse", at: 5, tool: "Bash"))
        #expect(ledger.sessions.first?.state == .working)
        let stop = event("Stop", at: 6, message: "All done")
        ledger.apply(stop)
        let finished = try #require(ledger.sessions.first)
        #expect(finished.state == .finished)
        #expect(finished.replyEventID == stop.id)
        #expect(finished.lastMessagePreview == "All done")
        #expect(finished.hasFreshReply(at: Date(timeIntervalSince1970: 30)))
        #expect(!finished.hasFreshReply(at: Date(timeIntervalSince1970: 6 + 600)))
        ledger.apply(event("SessionEnd", at: 7))
        #expect(ledger.sessions.first?.state == .ended)
    }

    @Test("Notifications: permission and input prompts need the person")
    func notifications() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("Notification", at: 1, notification: "permission_prompt"))
        #expect(ledger.sessions.first?.state == .waitingForPermission)
        ledger.apply(event("Notification", at: 2, notification: "idle_prompt"))
        #expect(ledger.sessions.first?.state == .needsInput)
        ledger.apply(event("Notification", at: 3, notification: "auth_success"))
        #expect(ledger.sessions.first?.state == .needsInput)
    }

    @Test("A question tool needs input; its answer resumes work")
    func questionTool() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("PreToolUse", at: 1, tool: "AskUserQuestion"))
        #expect(ledger.sessions.first?.state == .needsInput)
        ledger.apply(event("PostToolUse", at: 2, tool: "AskUserQuestion"))
        #expect(ledger.sessions.first?.state == .working)
    }

    @Test("Duplicates, older events, and late events from an old turn change nothing")
    func guards() {
        var ledger = AgentSessionLedger()
        let prompt = event("UserPromptSubmit", provider: .codex, at: 10, turn: "t2")
        let changed1 = ledger.apply(prompt)
        #expect(changed1)
        let changed2 = ledger.apply(prompt)
        #expect(!changed2)
        let changed3 = ledger.apply(event("Stop", provider: .codex, at: 5, turn: "t2"))
        #expect(!changed3)
        let changed4 = ledger.apply(event("Stop", provider: .codex, at: 11, turn: "t1"))
        #expect(!changed4)
        #expect(ledger.sessions.first?.state == .working)
        let changed5 = ledger.apply(event("Stop", provider: .codex, at: 12, turn: "t2"))
        #expect(changed5)
        #expect(ledger.sessions.first?.state == .finished)
    }

    @Test("A subagent keeps the parent working and never finishes it")
    func subagents() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", at: 1))
        ledger.apply(event("SubagentStart", at: 2, subagent: "a1"))
        ledger.apply(event("PreToolUse", at: 3, tool: "Read", subagent: "a1"))
        ledger.apply(event("SubagentStop", at: 4, subagent: "a1"))
        #expect(ledger.sessions.first?.state == .working)
        ledger.apply(event("Stop", at: 5))
        ledger.apply(event("SubagentStop", at: 6))
        #expect(ledger.sessions.first?.state == .finished)
    }

    @Test("Codex Interrupt finishes without a reply; StopFailure needs the person")
    func interruptAndFailure() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", provider: .codex, at: 1))
        ledger.apply(event("Interrupt", provider: .codex, at: 2))
        #expect(ledger.sessions.first?.state == .finished)
        #expect(ledger.sessions.first?.replyEventID == nil)
        ledger.apply(event("StopFailure", session: "x", at: 3))
        #expect(ledger.sessions.first { $0.sessionID == "x" }?.state == .needsInput)
    }

    @Test("Sessions are keyed by provider and session id; attention sorts first")
    func keysAndOrder() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", session: "same", provider: .claude, at: 1))
        ledger.apply(event("UserPromptSubmit", session: "same", provider: .codex, at: 2))
        ledger.apply(event("PermissionRequest", session: "same", provider: .claude, at: 3))
        ledger.apply(event("UserPromptSubmit", session: "other", provider: .codex, at: 4))
        #expect(ledger.sessions.count == 3)
        #expect(ledger.sessions.first?.id == "claude:same")
    }

    @Test("Expiry drops ended sessions quickly and silent sessions eventually")
    func expiry() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("SessionEnd", session: "ended", at: 0))
        ledger.apply(event("UserPromptSubmit", session: "busy", at: 0))
        let changed6 = ledger.expire(now: Date(timeIntervalSince1970: 30))
        #expect(!changed6)
        let changed7 = ledger.expire(now: Date(timeIntervalSince1970: 200))
        #expect(changed7)
        #expect(ledger.sessions.map(\.sessionID) == ["busy"])
        #expect(ledger.sessions.first?.isStale(at: Date(timeIntervalSince1970: 1_000)) == true)
        let changed8 = ledger.expire(now: Date(timeIntervalSince1970: 7 * 60 * 60))
        #expect(changed8)
        #expect(ledger.sessions.isEmpty)
    }

    @Test("The ledger keeps at most maximumSessions sessions")
    func bounded() {
        var ledger = AgentSessionLedger()
        for index in 0..<(AgentSessionLedger.maximumSessions + 5) {
            ledger.apply(event("SessionStart", session: "s\(index)", at: Double(index)))
        }
        #expect(ledger.sessions.count == AgentSessionLedger.maximumSessions)
        #expect(!ledger.sessions.contains { $0.sessionID == "s0" })
    }
}

@Suite("Agent terminal matching")
struct AgentTerminalMatcherTests {
    private func ledger(_ events: [AgentHookEvent]) -> [TrackedAgentSession] {
        var ledger = AgentSessionLedger()
        for item in events { ledger.apply(item) }
        return ledger.sessions
    }

    @Test("The process chain picks the terminal whose shell started the agent")
    func processChain() {
        let sessions = ledger([
            event("UserPromptSubmit", session: "a", at: 1, ancestors: [501, 400, 300]),
            event("UserPromptSubmit", session: "b", at: 2, ancestors: [601, 401, 300]),
        ])
        let terminal = AgentTerminalCandidate(
            id: UUID(), processID: 400, cwd: "/repo", provider: .claude)
        #expect(AgentTerminalMatcher.session(for: terminal, in: sessions)?.sessionID == "a")
    }

    @Test("The folder rule applies only to a session with no process chain")
    func folderFallback() {
        let sessions = ledger([
            event("UserPromptSubmit", session: "chained", at: 1, ancestors: [900]),
            event("UserPromptSubmit", session: "bare", at: 2, cwd: "/repo/"),
        ])
        let terminal = AgentTerminalCandidate(
            id: UUID(), processID: 400, cwd: "/repo", provider: .claude)
        #expect(AgentTerminalMatcher.session(for: terminal, in: sessions)?.sessionID == "bare")
        let codexTerminal = AgentTerminalCandidate(
            id: UUID(), processID: 400, cwd: "/repo", provider: .codex)
        #expect(AgentTerminalMatcher.session(for: codexTerminal, in: sessions) == nil)
    }

    @Test("External sessions exclude owned ones and descendants of Rafu")
    func external() {
        let sessions = ledger([
            event("UserPromptSubmit", session: "mine", at: 1, ancestors: [10, 20]),
            event("UserPromptSubmit", session: "iterm", at: 2, ancestors: [30, 40]),
            event("UserPromptSubmit", session: "rafu-child", at: 3, ancestors: [50, 99]),
            event("SessionEnd", session: "gone", at: 4, ancestors: [60]),
        ])
        let terminal = AgentTerminalCandidate(
            id: UUID(), processID: 20, cwd: nil, provider: .claude)
        let external = AgentTerminalMatcher.externalSessions(
            sessions, terminals: [terminal], appProcessID: 99)
        #expect(external.map(\.sessionID) == ["iterm"])
    }
}
