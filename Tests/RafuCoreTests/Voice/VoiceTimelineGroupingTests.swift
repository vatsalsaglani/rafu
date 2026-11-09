import Testing

@testable import RafuCore

@Suite("Voice timeline grouping")
struct VoiceTimelineGroupingTests {
    private func groups(_ items: [VoiceTimelineItem]) -> [VoiceTimelineGroup] {
        items.compactMap { if case .group(let group) = $0 { group } else { nil } }
    }

    @Test("finish keeps its old call shape and stores an outcome when given")
    func finishOutcome() {
        var timeline = VoiceTimeline()
        let plain = timeline.append(lane: .tool, startMS: 0, persona: "Rafu", title: "a")
        timeline.finish(plain, endMS: 10)
        timeline.finish(plain, endMS: 20, detail: "ok")
        #expect(timeline.events[0].outcome == nil)
        let failed = timeline.append(lane: .tool, startMS: 30, persona: "Rafu", title: "b")
        timeline.finish(failed, endMS: 40, detail: "nope", outcome: .failed)
        #expect(timeline.events[1].outcome == .failed)
        #expect(timeline.events[1].endMS == 40)
        // A later finish without an outcome does not erase it.
        timeline.finish(failed, endMS: 50)
        #expect(timeline.events[1].outcome == .failed)
    }

    @Test("Steps group under their delegation by id, else by time")
    func groupsByIDAndTime() {
        var timeline = VoiceTimeline()
        timeline.append(lane: .you, startMS: 0, persona: "Rafu", title: "You", detail: "hi")
        timeline.append(lane: .tool, startMS: 50, persona: "Rafu", title: "before")
        timeline.append(
            lane: .delegation, startMS: 100, delegationID: "d1", persona: "Rafu",
            title: "Delegation")
        let a = timeline.append(lane: .tool, startMS: 120, persona: "Rafu", title: "a")
        let b = timeline.append(lane: .board, startMS: 130, persona: "Rafu", title: "b")
        timeline.finish(a, endMS: 200)
        timeline.finish(b, endMS: 210)
        timeline.append(
            lane: .delegation, startMS: 500, delegationID: "d2", persona: "Rafu",
            title: "Delegation")
        let c = timeline.append(
            lane: .tool, startMS: 510, delegationID: "d2", persona: "Rafu", title: "c")
        timeline.finish(c, endMS: 600)
        timeline.append(lane: .voice, startMS: 700, persona: "Rafu", title: "Rafu reply")

        let items = VoiceTimelineGrouping.items(events: timeline.events, sessionOpen: true)
        #expect(items.count == 5)
        guard case .you = items[0], case .standalone(let before) = items[1],
            case .group(let first) = items[2], case .group(let second) = items[3],
            case .rafu = items[4]
        else {
            Issue.record("unexpected item order")
            return
        }
        #expect(before.title == "before")
        #expect(first.children.map(\.title) == ["a", "b"])
        #expect(second.children.map(\.title) == ["c"])
        #expect(first.stepCount == 2)
        #expect(first.finishedStepCount == 2)
    }

    @Test("A delegation runs until its steps end, a newer one starts, or the session closes")
    func runningDetection() {
        var timeline = VoiceTimeline()
        timeline.append(
            lane: .delegation, startMS: 0, delegationID: "d1", persona: "Rafu", title: "Delegation")
        // No steps yet: running while the session is open.
        var found = groups(VoiceTimelineGrouping.items(events: timeline.events, sessionOpen: true))
        #expect(found[0].isRunning)
        #expect(found[0].endMS == nil)
        #expect(found[0].outcome == nil)
        #expect(found[0].durationMS(nowMS: 4_200) == 4_200)

        let step = timeline.append(lane: .tool, startMS: 100, persona: "Rafu", title: "a")
        found = groups(VoiceTimelineGrouping.items(events: timeline.events, sessionOpen: true))
        #expect(found[0].isRunning, "an open step keeps the delegation running")

        timeline.finish(step, endMS: 900)
        found = groups(VoiceTimelineGrouping.items(events: timeline.events, sessionOpen: true))
        #expect(!found[0].isRunning)
        #expect(found[0].endMS == 900)
        #expect(found[0].durationMS(nowMS: 99_999) == 900)
        #expect(found[0].outcome == .ok)

        // A closed session leaves nothing running, even with an open step.
        var cut = VoiceTimeline()
        cut.append(
            lane: .delegation, startMS: 0, delegationID: "d1", persona: "Rafu", title: "Delegation")
        cut.append(lane: .tool, startMS: 100, persona: "Rafu", title: "a")
        found = groups(VoiceTimelineGrouping.items(events: cut.events, sessionOpen: false))
        #expect(!found[0].isRunning)
        #expect(found[0].endMS == 100)

        // A newer delegation ends an empty older one at its own start.
        var two = VoiceTimeline()
        two.append(
            lane: .delegation, startMS: 0, delegationID: "d1", persona: "Rafu", title: "Delegation")
        two.append(
            lane: .delegation, startMS: 300, delegationID: "d2", persona: "Rafu",
            title: "Delegation")
        found = groups(VoiceTimelineGrouping.items(events: two.events, sessionOpen: true))
        #expect(!found[0].isRunning)
        #expect(found[0].durationMS(nowMS: 5_000) == 300)
        #expect(found[1].isRunning)
    }

    @Test("One failed step makes the group Failed")
    func groupOutcome() {
        var timeline = VoiceTimeline()
        timeline.append(
            lane: .delegation, startMS: 0, delegationID: "d1", persona: "Rafu", title: "Delegation")
        let a = timeline.append(lane: .tool, startMS: 10, persona: "Rafu", title: "a")
        let b = timeline.append(lane: .tool, startMS: 20, persona: "Rafu", title: "b")
        timeline.finish(a, endMS: 30, outcome: .ok)
        timeline.finish(b, endMS: 40, outcome: .failed)
        let found = groups(VoiceTimelineGrouping.items(events: timeline.events, sessionOpen: true))
        #expect(found[0].outcome == .failed)
        #expect(found[0].stepCount == 2)
    }

    @Test("The clock adds wall time to the newest known time and resets on a new session")
    func clock() {
        let start = ContinuousClock.now
        var clock = VoiceTimelineClock(knownMS: 1_000, at: start)
        #expect(clock.nowMS(at: start) == 1_000)
        #expect(clock.nowMS(at: start.advanced(by: .milliseconds(2_500))) == 3_500)
        // Earlier than the anchor never goes backwards.
        #expect(clock.nowMS(at: start.advanced(by: .milliseconds(-10))) == 1_000)
        clock.note(knownMS: 4_000, at: start.advanced(by: .seconds(3)))
        #expect(clock.nowMS(at: start.advanced(by: .seconds(4))) == 5_000)
        clock.note(knownMS: 0, at: start.advanced(by: .seconds(10)))
        #expect(clock.nowMS(at: start.advanced(by: .seconds(10))) == 0)
    }
}
