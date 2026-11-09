import Testing

@testable import RafuApp
@testable import RafuCore

@Suite("Voice timeline capsules")
struct VoiceTimelineCapsuleTests {
    @Test("A spoken row adds the outcome word only when it has one")
    func spokenOutcome() {
        var row = VoiceTimelineEvent(
            id: "#4", lane: .tool, startMS: 12_400, endMS: 13_200, persona: "Rafu",
            title: "note_create", detail: "ok")
        #expect(VoiceTimelineFormat.spoken(row) == "#4, note_create, ok, at 12.4 s, took 0.8 s")
        row.outcome = .ok
        #expect(
            VoiceTimelineFormat.spoken(row)
                == "#4, note_create, ok, at 12.4 s, took 0.8 s, completed")
        row.outcome = .failed
        #expect(
            VoiceTimelineFormat.spoken(row)
                == "#4, note_create, ok, at 12.4 s, took 0.8 s, failed")
    }

    @Test("Pill words, step counts and durations")
    func words() {
        #expect(VoiceTimelineFormat.outcomeLabel(.ok) == "Completed")
        #expect(VoiceTimelineFormat.outcomeLabel(.failed) == "Failed")
        #expect(VoiceTimelineFormat.stepCount(1) == "1 step")
        #expect(VoiceTimelineFormat.stepCount(3) == "3 steps")
        let done = VoiceTimelineEvent(
            id: "#1", lane: .voice, startMS: 1_000, endMS: 3_500, persona: "Rafu",
            title: "Rafu reply")
        #expect(VoiceTimelineFormat.duration(done) == "2.5 s")
        let running = VoiceTimelineEvent(
            id: "#2", lane: .tool, startMS: 1_000, persona: "Rafu", title: "a")
        #expect(VoiceTimelineFormat.duration(running) == "running")
        #expect(VoiceTimelineFormat.stepDuration(running, nowMS: 1_700) == "0.7 s")
        #expect(VoiceTimelineFormat.stepDuration(done, nowMS: 9_000) == "2.5 s")
    }

    @Test("Group titles: Working while running, Thought for after")
    func groupTitles() {
        var timeline = VoiceTimeline()
        timeline.append(
            lane: .delegation, startMS: 0, delegationID: "d1", persona: "Rafu", title: "Delegation")
        let step = timeline.append(lane: .tool, startMS: 100, persona: "Rafu", title: "a")
        func group() -> VoiceTimelineGroup {
            let items = VoiceTimelineGrouping.items(events: timeline.events, sessionOpen: true)
            guard case .group(let value) = items[0] else { fatalError("no group") }
            return value
        }
        #expect(VoiceTimelineFormat.groupTitle(group(), nowMS: 13_600) == "Working 13.6 s")
        #expect(
            VoiceTimelineFormat.spoken(group: group(), nowMS: 13_600)
                == "#1, delegation, working, 1 step")
        timeline.finish(step, endMS: 4_200, outcome: .ok)
        #expect(VoiceTimelineFormat.groupTitle(group(), nowMS: 13_600) == "Thought for 4.2 s")
        #expect(
            VoiceTimelineFormat.spoken(group: group(), nowMS: 13_600)
                == "#1, delegation, thought for 4.2 s, 1 step, completed")
    }

    @Test("The pixel loader lights one cell per step along its path, and is still without motion")
    func loaderBrightness() {
        #expect(VoicePixelLoader.path.sorted() == Array(0..<9))
        for step in 0..<VoicePixelLoader.path.count {
            let levels = (0..<9).map {
                VoicePixelLoader.brightness(cell: $0, step: step, animates: true)
            }
            #expect(levels.filter { $0 == 1 }.count == 1)
            #expect(levels[VoicePixelLoader.path[step]] == 1)
        }
        for cell in 0..<9 {
            #expect(VoicePixelLoader.brightness(cell: cell, step: 3, animates: false) == 0.5)
        }
        #expect(VoicePixelLoader.frameInterval == .milliseconds(125))
        #expect(VoiceRunningRing.frameInterval == .milliseconds(50))
    }
}
