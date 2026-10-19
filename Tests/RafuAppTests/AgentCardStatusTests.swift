import Foundation
import RafuCore
import Testing

@testable import RafuApp

private let now = Date(timeIntervalSince1970: 10_000)

private func trackedSession(
    state: AgentSessionState, lastEventName: String = "", replyEventID: UUID? = nil,
    replyAt: Date? = nil, updatedAt: Date = now
) -> TrackedAgentSession {
    TrackedAgentSession(
        provider: .claude, sessionID: "s", state: state, lastEventName: lastEventName,
        replyEventID: replyEventID, replyAt: replyAt, startedAt: updatedAt, updatedAt: updatedAt)
}

private func hookEvent(
    _ name: String, session: String = "s", at seconds: TimeInterval
) -> AgentHookEvent {
    AgentHookEvent(
        provider: .claude, sessionID: session, hookEventName: name, cwd: "/repo/app",
        time: Date(timeIntervalSince1970: seconds))
}

private func foldedSession(_ events: [AgentHookEvent]) throws -> TrackedAgentSession {
    var ledger = AgentSessionLedger()
    for event in events { ledger.apply(event) }
    return try #require(ledger.sessions.first)
}

@Suite("Agent card status")
struct AgentCardStatusTests {
    @Test("Working, needsYou, and failed resolve from hook state, in precedence order")
    func liveStates() {
        let working = trackedSession(state: .working)
        #expect(
            AgentCardStatus.resolve(
                session: working, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == .working)

        let approval = trackedSession(state: .waitingForPermission)
        #expect(
            AgentCardStatus.resolve(
                session: approval, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == .needsYou(.approval))

        let input = trackedSession(state: .needsInput, lastEventName: "PreToolUse")
        #expect(
            AgentCardStatus.resolve(
                session: input, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == .needsYou(.input))

        let failed = trackedSession(state: .needsInput, lastEventName: "StopFailure")
        #expect(
            AgentCardStatus.resolve(
                session: failed, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == .failed)
    }

    @Test("doneUnread until acknowledged, then done; a new Stop returns doneUnread")
    func doneUnreadThenDone() {
        let replied = trackedSession(state: .finished, replyEventID: UUID(), replyAt: now)
        #expect(
            AgentCardStatus.resolve(
                session: replied, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: false, now: now) == .doneUnread)
        #expect(
            AgentCardStatus.resolve(
                session: replied, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == .done)

        let newReply = trackedSession(state: .finished, replyEventID: UUID(), replyAt: now)
        #expect(
            AgentCardStatus.resolve(
                session: newReply, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: false, now: now) == .doneUnread)
    }

    @Test("A finished session with no reply (e.g. after Interrupt) is plain done")
    func doneWithoutReply() {
        let finished = trackedSession(state: .finished, replyEventID: nil)
        #expect(
            AgentCardStatus.resolve(
                session: finished, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == .done)
    }

    @Test("Real hook folding: StopFailure resolves failed; Interrupt resolves done")
    func foldedEventsMatchTheirStates() throws {
        let failedSession = try foldedSession([
            hookEvent("UserPromptSubmit", at: 0), hookEvent("StopFailure", at: 1),
        ])
        #expect(
            AgentCardStatus.resolve(
                session: failedSession, terminalStatus: .running, paneStatus: .live,
                ranAgent: true, isReplyAcknowledged: true,
                now: Date(timeIntervalSince1970: 1)) == .failed)

        let interrupted = try foldedSession([
            hookEvent("UserPromptSubmit", at: 0), hookEvent("Interrupt", at: 1),
        ])
        #expect(
            AgentCardStatus.resolve(
                session: interrupted, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: Date(timeIntervalSince1970: 1)) == .done)
    }

    @Test("A done session goes inactive at 30 minutes, not a moment before")
    func inactiveBoundary() {
        let finished = trackedSession(state: .finished, updatedAt: Date(timeIntervalSince1970: 0))
        let justBefore = Date(timeIntervalSince1970: AgentCardStatus.inactiveInterval - 1)
        let atThreshold = Date(timeIntervalSince1970: AgentCardStatus.inactiveInterval)
        #expect(
            AgentCardStatus.resolve(
                session: finished, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: justBefore) == .done)
        #expect(
            AgentCardStatus.resolve(
                session: finished, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: atThreshold) == .inactive)
    }

    @Test("A stale working session goes inactive at 30 minutes")
    func staleWorkingGoesInactive() {
        let working = trackedSession(state: .working, updatedAt: Date(timeIntervalSince1970: 0))
        let atThreshold = Date(timeIntervalSince1970: AgentCardStatus.inactiveInterval)
        #expect(
            AgentCardStatus.resolve(
                session: working, terminalStatus: .running, paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: atThreshold) == .inactive)
    }

    @Test("Stopped requires ranAgent; an ordinary shell's exit stays nil")
    func stoppedRequiresRanAgent() {
        for paneStatus: TerminalPaneStatus in [.stopped, .exited, .idle] {
            #expect(
                AgentCardStatus.resolve(
                    session: nil, terminalStatus: .exited(code: 0), paneStatus: paneStatus,
                    ranAgent: true, isReplyAcknowledged: true, now: now) == .stopped)
            #expect(
                AgentCardStatus.resolve(
                    session: nil, terminalStatus: .exited(code: 0), paneStatus: paneStatus,
                    ranAgent: false, isReplyAcknowledged: true, now: now) == nil)
        }
        #expect(
            AgentCardStatus.resolve(
                session: nil, terminalStatus: .exited(code: 0), paneStatus: .live, ranAgent: true,
                isReplyAcknowledged: true, now: now) == nil)
    }

    @Test("An ended session also reads stopped once the pane ran an agent")
    func endedSessionReadsStopped() {
        let ended = trackedSession(state: .ended)
        #expect(
            AgentCardStatus.resolve(
                session: ended, terminalStatus: .exited(code: 0), paneStatus: .exited,
                ranAgent: true, isReplyAcknowledged: true, now: now) == .stopped)
    }

    @Test("Word, symbol, and bold-title vocabulary match the status table")
    func vocabulary() {
        #expect(AgentCardStatus.working.word == "Working")
        #expect(AgentCardStatus.working.symbolName == nil)
        #expect(AgentCardStatus.needsYou(.approval).word == "Needs approval")
        #expect(AgentCardStatus.needsYou(.input).word == "Needs input")
        #expect(AgentCardStatus.failed.word == "Failed")
        #expect(AgentCardStatus.failed.symbolName == "exclamationmark.triangle.fill")
        #expect(AgentCardStatus.doneUnread.word == "Done")
        #expect(AgentCardStatus.doneUnread.symbolName == "checkmark.circle.fill")
        #expect(AgentCardStatus.doneUnread.readsTitleBold)
        #expect(AgentCardStatus.done.word == "Done")
        #expect(AgentCardStatus.done.symbolName == "checkmark")
        #expect(!AgentCardStatus.done.readsTitleBold)
        #expect(AgentCardStatus.inactive.word == "Inactive")
        #expect(AgentCardStatus.inactive.symbolName == "moon.fill")
        #expect(AgentCardStatus.stopped.word == "Stopped")
        #expect(AgentCardStatus.stopped.symbolName == "stop.circle")
    }

    @Test("Accessibility values speak the full sentence")
    func accessibilityValues() {
        #expect(AgentCardStatus.working.accessibilityValue(elapsed: 60) == "Working, 1 minute")
        #expect(
            AgentCardStatus.needsYou(.approval).accessibilityValue(elapsed: 0) == "Needs approval")
        #expect(AgentCardStatus.needsYou(.input).accessibilityValue(elapsed: 0) == "Needs input")
        #expect(AgentCardStatus.failed.accessibilityValue(elapsed: 0) == "Failed")
        #expect(
            AgentCardStatus.doneUnread.accessibilityValue(elapsed: 240)
                == "Done, unread, 4 minutes ago")
        #expect(AgentCardStatus.done.accessibilityValue(elapsed: 60) == "Done, 1 minute ago")
        #expect(
            AgentCardStatus.inactive.accessibilityValue(elapsed: 7_200) == "Inactive, 2 hours ago")
        #expect(AgentCardStatus.stopped.accessibilityValue(elapsed: 999) == "Stopped")
    }

    @Test("Elapsed labels: now, minutes, hours, and days, at every boundary")
    func elapsedLabels() {
        let start = Date(timeIntervalSince1970: 0)
        func label(_ seconds: TimeInterval) -> String {
            AgentCardElapsed.label(since: start, now: start.addingTimeInterval(seconds))
        }
        #expect(label(0) == "now")
        #expect(label(59) == "now")
        #expect(label(60) == "1m")
        #expect(label(59 * 60) == "59m")
        #expect(label(60 * 60) == "1h")
        #expect(label(23 * 60 * 60) == "23h")
        #expect(label(24 * 60 * 60) == "1d")
        #expect(label(2 * 24 * 60 * 60) == "2d")
    }
}
