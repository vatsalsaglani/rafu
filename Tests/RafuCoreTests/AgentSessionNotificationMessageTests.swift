import Foundation
import RafuCore
import Testing

private func event(
    _ name: String, at seconds: TimeInterval, tool: String? = nil,
    notification: String? = nil, message: String? = nil, subagent: String? = nil
) -> AgentHookEvent {
    AgentHookEvent(
        provider: .claude, sessionID: "s", subagentID: subagent, hookEventName: name,
        cwd: "/repo", toolName: tool, notificationType: notification,
        time: Date(timeIntervalSince1970: seconds), notificationMessage: message)
}

@Suite("Agent session notification message")
struct AgentSessionNotificationMessageTests {
    @Test("A waiting notification's text stays while the session waits")
    func keptWhileWaiting() throws {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", at: 1))
        ledger.apply(
            event(
                "Notification", at: 2, notification: "permission_prompt",
                message: "Claude needs your permission to use the network"))
        let waiting = try #require(ledger.sessions.first)
        #expect(waiting.state == .waitingForPermission)
        #expect(waiting.notificationMessage == "Claude needs your permission to use the network")
        // The command runs after the person answers in the terminal.
        ledger.apply(event("PostToolUse", at: 3, tool: "Bash"))
        #expect(ledger.sessions.first?.notificationMessage == nil)
    }

    @Test("A new prompt clears the old text")
    func newPromptClears() {
        var ledger = AgentSessionLedger()
        ledger.apply(
            event("Notification", at: 1, notification: "elicitation_dialog", message: "Form"))
        #expect(ledger.sessions.first?.notificationMessage == "Form")
        ledger.apply(event("PermissionRequest", at: 2, tool: "Bash"))
        #expect(ledger.sessions.first?.state == .waitingForPermission)
        #expect(ledger.sessions.first?.notificationMessage == nil)
    }

    @Test("Other notification types keep no text; an idle one clears it")
    func otherTypes() {
        var ledger = AgentSessionLedger()
        ledger.apply(event("Notification", at: 1, notification: "auth_success", message: "Hi"))
        #expect(ledger.sessions.first?.notificationMessage == nil)
        ledger.apply(
            event("Notification", at: 2, notification: "permission_prompt", message: "Allow?"))
        ledger.apply(event("Notification", at: 3, notification: "idle_prompt", message: "Idle"))
        #expect(ledger.sessions.first?.state == .finished)
        #expect(ledger.sessions.first?.notificationMessage == nil)
    }

    @Test("A background session's wait keeps no text and is not Needs you")
    func agentNeedsInput() throws {
        var ledger = AgentSessionLedger()
        ledger.apply(event("UserPromptSubmit", at: 1))
        ledger.apply(
            event(
                "Notification", at: 2, notification: "agent_needs_input",
                message: "A teammate asks how to show its terminal"))
        let row = try #require(ledger.sessions.first)
        #expect(row.state == .working)
        #expect(row.notificationMessage == nil)
    }
}
