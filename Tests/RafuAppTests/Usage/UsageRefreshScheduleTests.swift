import Foundation
import RafuCore
import Testing

@testable import RafuApp

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite("Usage refresh schedule")
struct UsageRefreshScheduleTests {
    @Test("The constants stay pinned")
    func constants() {
        #expect(UsageRefreshSchedule.coalesce == 15)
        #expect(UsageRefreshSchedule.minimumInterval == 60)
        #expect(UsageRefreshSchedule.openStaleness == 60)
        #expect(UsageRefreshSchedule.fallbackInterval == 300)
        #expect(UsageRefreshSchedule.pinnedInterval == 180)
        #expect(UsageRefreshSchedule.maximumFailures == 3)
        #expect(UsageRefreshSchedule.maximumEventAge == 60)
    }

    @Test("Cadence follows what shows usage; a status item beats pinned")
    func cadence() {
        typealias Cadence = UsageRefreshSchedule.Cadence
        #expect(Cadence.resolve(hasStatusItem: false, hasPanel: false, isPinned: false) == .none)
        #expect(Cadence.resolve(hasStatusItem: true, hasPanel: false, isPinned: false) == .resting)
        #expect(Cadence.resolve(hasStatusItem: false, hasPanel: true, isPinned: false) == .resting)
        #expect(Cadence.resolve(hasStatusItem: false, hasPanel: true, isPinned: true) == .pinned)
        #expect(Cadence.resolve(hasStatusItem: true, hasPanel: true, isPinned: true) == .resting)
        #expect(Cadence.none.interval == nil)
        #expect(Cadence.resting.interval == 300)
        #expect(Cadence.pinned.interval == 180)
    }

    @Test("Nothing shows usage: no automatic read, even after a turn end")
    func noSurfaceNoRead() {
        var schedule = UsageRefreshSchedule()
        schedule.receivedTurnEnd(at: t0)
        #expect(schedule.next(cadence: .none) == nil)
        #expect(!schedule.isDue(at: at(10_000), cadence: .none))
    }

    @Test("A fresh schedule is due at once, and the fallback then waits 300 s")
    func fallback() {
        var schedule = UsageRefreshSchedule()
        #expect(schedule.isDue(at: t0, cadence: .resting))
        schedule.begin(at: t0)
        schedule.finish(at: at(2), succeeded: true)
        #expect(schedule.next(cadence: .resting) == at(300))
        #expect(schedule.next(cadence: .pinned) == at(180))
        #expect(!schedule.isDue(at: at(299), cadence: .resting))
        #expect(schedule.isDue(at: at(300), cadence: .resting))
    }

    @Test("A turn end waits the coalescing window")
    func coalescesOneEvent() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.finish(at: at(1), succeeded: true)
        // Far past the minimum interval, so only the window applies.
        schedule.receivedTurnEnd(at: at(100))
        #expect(schedule.next(cadence: .resting) == at(115))
    }

    @Test("A burst of turn ends is one read; later events never push it back")
    func burstKeepsEarliestDue() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.finish(at: at(1), succeeded: true)
        schedule.receivedTurnEnd(at: at(100))
        schedule.receivedTurnEnd(at: at(105))
        schedule.receivedTurnEnd(at: at(112))
        #expect(schedule.next(cadence: .resting) == at(115))
    }

    @Test("Automatic reads start at least 60 s apart")
    func minimumInterval() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.finish(at: at(1), succeeded: true)
        // The turn ends 5 s after the read started: the window alone says
        // 20 s, the interval says 60 s.
        schedule.receivedTurnEnd(at: at(5))
        #expect(schedule.next(cadence: .resting) == at(60))
    }

    @Test("A turn end during a read asks for exactly one follow-up read")
    func followUp() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.receivedTurnEnd(at: at(10))
        schedule.receivedTurnEnd(at: at(12))
        // While a read runs nothing is scheduled.
        #expect(schedule.next(cadence: .resting) == nil)
        schedule.finish(at: at(20), succeeded: true)
        // Window after the finish (35), interval after the start (60).
        #expect(schedule.next(cadence: .resting) == at(60))
        let started = schedule.begin(at: at(60))
        #expect(started)
        schedule.finish(at: at(61), succeeded: true)
        // The follow-up was used: back to the fallback only.
        #expect(schedule.next(cadence: .resting) == at(360))
    }

    @Test("A turn end before the first read is coalesced, but the fresh fallback is due at once")
    func turnEndBeforeFirstRead() {
        var schedule = UsageRefreshSchedule()
        schedule.receivedTurnEnd(at: t0)
        #expect(schedule.turnEndDue == at(15))
        #expect(schedule.isDue(at: t0, cadence: .resting))
    }

    @Test("Opening reads only when the data is older than 60 s")
    func openStaleness() {
        var schedule = UsageRefreshSchedule()
        #expect(schedule.shouldRefreshOnOpen(at: t0))
        schedule.begin(at: t0)
        #expect(!schedule.shouldRefreshOnOpen(at: at(1)))
        schedule.finish(at: at(2), succeeded: true)
        #expect(!schedule.shouldRefreshOnOpen(at: at(30)))
        #expect(!schedule.shouldRefreshOnOpen(at: at(62)))
        #expect(schedule.shouldRefreshOnOpen(at: at(63)))
    }

    @Test("A manual refresh starts at any time but joins a running read")
    func manualJoins() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.finish(at: at(1), succeeded: true)
        // Inside the minimum interval, still allowed.
        #expect(schedule.shouldStartManualRefresh())
        schedule.begin(at: at(5))
        #expect(!schedule.shouldStartManualRefresh())
        let startedAgain = schedule.begin(at: at(6))
        #expect(!startedAgain)
        #expect(schedule.lastStarted == at(5))
    }

    @Test("Failures back off by 300 s times the count, capped at three")
    func backoffCap() {
        var schedule = UsageRefreshSchedule()
        var clock = t0
        for step: TimeInterval in [300, 600, 900, 900, 900] {
            schedule.begin(at: clock)
            schedule.finish(at: clock, succeeded: false)
            #expect(schedule.next(cadence: .resting) == clock.addingTimeInterval(step))
            clock = clock.addingTimeInterval(step)
        }
        #expect(schedule.failures == 3)
    }

    @Test("A turn end cannot skip the failure backoff; a success clears it")
    func backoffHoldsTurnEnds() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.finish(at: at(1), succeeded: false)
        schedule.receivedTurnEnd(at: at(100))
        #expect(schedule.next(cadence: .resting) == at(301))
        schedule.begin(at: at(301))
        schedule.finish(at: at(302), succeeded: true)
        #expect(schedule.failures == 0)
        schedule.receivedTurnEnd(at: at(400))
        #expect(schedule.next(cadence: .resting) == at(415))
    }

    @Test("Abort frees a cancelled read without counting a result")
    func abort() {
        var schedule = UsageRefreshSchedule()
        schedule.begin(at: t0)
        schedule.receivedTurnEnd(at: at(1))
        schedule.abort()
        #expect(!schedule.isRunning)
        #expect(schedule.lastSucceeded == nil)
        #expect(schedule.failures == 0)
        let restarted = schedule.begin(at: at(2))
        #expect(restarted)
    }

    @Test("Only fresh Stop-class events count; an old spool replay does not")
    func triggerFreshness() {
        func event(_ name: String, age: TimeInterval) -> AgentHookEvent {
            AgentHookEvent(
                provider: .claude, sessionID: "s", hookEventName: name,
                time: t0.addingTimeInterval(-age))
        }
        for name in ["Stop", "SubagentStop", "StopFailure", "SessionEnd"] {
            #expect(UsageRefreshTrigger.isFreshTurnEnd(event(name, age: 1), now: t0))
        }
        #expect(UsageRefreshTrigger.isFreshTurnEnd(event("Stop", age: 60), now: t0))
        #expect(!UsageRefreshTrigger.isFreshTurnEnd(event("Stop", age: 61), now: t0))
        #expect(!UsageRefreshTrigger.isFreshTurnEnd(event("Stop", age: -3_600), now: t0))
        for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionStart"] {
            #expect(!UsageRefreshTrigger.isFreshTurnEnd(event(name, age: 1), now: t0))
        }
    }

    @Test("Agent providers map to their usage providers")
    func providerMapping() {
        #expect(UsageRefreshTrigger.usageProvider(for: .claude) == .claude)
        #expect(UsageRefreshTrigger.usageProvider(for: .codex) == .codex)
        #expect(UsageRefreshTrigger.usageProvider(for: .cursor) == .cursor)
    }
}
