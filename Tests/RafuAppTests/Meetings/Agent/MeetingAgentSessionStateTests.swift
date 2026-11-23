import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: session state of runs and summaries")
@MainActor
struct MeetingAgentSessionStateTests {
    @Test("Agent runs are listed for each meeting and kind, and removed at the end")
    func agentRuns() {
        let session = MeetingsSessionModel()
        let meeting = MeetingID()
        let question = MeetingAgentActivity(
            kind: .question, cli: .codex, started: Date(timeIntervalSince1970: 1))
        let summary = MeetingAgentActivity(
            kind: .summary, cli: .claudeCode, started: Date(timeIntervalSince1970: 2))

        session.noteAgentRun(question, of: meeting, isRunning: true)
        session.noteAgentRun(summary, of: meeting, isRunning: true)
        #expect(session.isAgentRunning(.question, for: meeting))
        #expect(session.isAgentRunning(.summary, for: meeting))
        #expect(!session.isAgentRunning(.speakerNames, for: meeting))

        session.noteAgentRun(question, of: meeting, isRunning: false)
        #expect(!session.isAgentRunning(.question, for: meeting))
        session.noteAgentRun(summary, of: meeting, isRunning: false)
        #expect(session.agentRuns[meeting] == nil)
    }

    @Test("The summary actions call the installed handlers")
    func summaryHandlers() {
        let session = MeetingsSessionModel()
        let meeting = MeetingID()
        var calls: [String] = []
        session.summaryHandlers = MeetingsSummaryHandlers(
            afterProcessing: { _ in calls.append("after") }, make: { _ in calls.append("make") },
            cancel: { _ in calls.append("cancel") }, refresh: { _ in calls.append("refresh") })
        session.makeSummary(meeting)
        session.cancelSummary(meeting)
        session.refreshSummaryState(meeting)
        session.summaryHandlers.afterProcessing(meeting)
        #expect(calls == ["make", "cancel", "refresh", "after"])

        session.summaryStepActive.insert(meeting)
        session.leaveSummaryStep(meeting)
        #expect(session.summaryStepActive.isEmpty)
    }
}
