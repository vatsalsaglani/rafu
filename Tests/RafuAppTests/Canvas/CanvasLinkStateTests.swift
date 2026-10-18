import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas link state and activity")
struct CanvasLinkStateTests {
    private let policy = CanvasBurstPolicy(limit: 3, window: 2, travel: 0.5)
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("Paused wins over every terminal condition")
    func pausedWins() {
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: false, from: .missing, to: .suspended(.connectionLost),
                failure: "x") == .paused)
    }

    @Test("A live link needs both ends connected")
    func liveNeedsBothEnds() {
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .connected, to: .connected, failure: nil) == .live)
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .connected, to: .missing, failure: nil)
                == .disconnected(.sessionEnded))
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .notConnected, to: .connected, failure: nil)
                == .disconnected(.agentNotRunning))
    }

    @Test("A changed conversation or lost transport is a disconnect with its own reason")
    func suspensionReasons() {
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .connected, to: .suspended(.conversationChanged),
                failure: nil) == .disconnected(.conversationChanged))
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .suspended(.connectionLost), to: .missing, failure: nil)
                == .disconnected(.connectionLost))
        #expect(
            CanvasLinkDisconnectReason.conversationChanged.message
                == "The conversation changed. Start a new terminal to link it.")
        #expect(
            CanvasLinkDisconnectReason.sessionEnded.message
                == "This session ended. Start the terminal again to reconnect.")
    }

    @Test("A refused send fails the link only while both terminals are connected")
    func failure() {
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .connected, to: .connected, failure: "Inbox full")
                == .failed("Inbox full"))
        #expect(
            CanvasLinkStateMapper.resolve(
                isEnabled: true, from: .connected, to: .missing, failure: "Inbox full")
                == .disconnected(.sessionEnded))
        #expect(CanvasLinkState.failed("Inbox full").reason == "Inbox full")
        #expect(CanvasLinkState.live.reason == nil)
    }

    @Test("Every state has a word and a glyph, not only a colour")
    func wordsAndGlyphs() {
        #expect(CanvasLinkState.live.badgeText == "⇄ Live")
        #expect(CanvasLinkState.paused.badgeText == "‖ Paused")
        #expect(CanvasLinkState.disconnected(.sessionEnded).badgeText == "⊘ Disconnected")
        #expect(CanvasLinkState.failed("x").badgeText == "△ Failed")
    }

    @Test("The status summary counts each state")
    func summary() {
        let summary = CanvasLinkSummary(states: [
            .live, .live, .paused, .disconnected(.sessionEnded), .failed("x"),
        ])
        #expect(summary.live == 2)
        #expect(summary.paused == 1)
        #expect(summary.total == 5)
        #expect(summary.text == "⇄ 2 live · 1 paused · 1 disconnected · 1 failed")
        #expect(CanvasLinkSummary(states: [.live]).text == "⇄ 1 live · 0 paused")
        #expect(CanvasLinkSummary(states: []).total == 0)
    }

    @Test("A single message starts one dot in its direction and counts once")
    func singleMessage() {
        var activity = CanvasLinkActivity()
        let outcome = activity.record(direction: .reverse, at: start, policy: policy)
        #expect(outcome == .travel(.reverse))
        #expect(activity.count == 1)
        #expect(activity.dotDirection == .reverse)
        #expect(activity.isDotActive(at: start.addingTimeInterval(0.25), travel: 0.5))
        #expect(!activity.isDotActive(at: start.addingTimeInterval(0.5), travel: 0.5))
        let progress = activity.dotProgress(at: start.addingTimeInterval(0.25), travel: 0.5)
        #expect(progress == 0.5)
        #expect(activity.dotProgress(at: start.addingTimeInterval(1), travel: 0.5) == nil)
    }

    @Test("A message while a dot runs adds to the count but no second dot")
    func oneDotAtATime() {
        var activity = CanvasLinkActivity()
        activity.record(direction: .forward, at: start, policy: policy)
        let second = activity.record(
            direction: .reverse, at: start.addingTimeInterval(0.2), policy: policy)
        #expect(second == .countOnly)
        #expect(activity.count == 2)
        #expect(activity.dotDirection == .forward)
        let third = activity.record(
            direction: .reverse, at: start.addingTimeInterval(0.6), policy: policy)
        #expect(third == .travel(.reverse))
        #expect(activity.count == 3)
    }

    @Test("More than three messages in two seconds show only the count")
    func burst() {
        var activity = CanvasLinkActivity()
        var outcomes: [CanvasLinkActivity.Outcome] = []
        for index in 0..<6 {
            let time = start.addingTimeInterval(Double(index) * 0.55)
            outcomes.append(activity.record(direction: .forward, at: time, policy: policy))
        }
        // 0.00, 0.55, 1.10, 1.65 are inside one 2 s window: the fourth is a burst.
        #expect(outcomes[0] == .travel(.forward))
        #expect(outcomes[1] == .travel(.forward))
        #expect(outcomes[2] == .travel(.forward))
        #expect(outcomes[3] == .countOnly)
        #expect(activity.count == 6)
        // Once old messages leave the window, dots resume.
        let later = activity.record(
            direction: .forward, at: start.addingTimeInterval(10), policy: policy)
        #expect(later == .travel(.forward))
    }

    @Test("The count resets after ten minutes without messages")
    func countReset() {
        var activity = CanvasLinkActivity()
        activity.record(direction: .forward, at: start, policy: policy)
        activity.record(direction: .forward, at: start.addingTimeInterval(5), policy: policy)
        #expect(activity.visibleCount(at: start.addingTimeInterval(60), resetAfter: 600) == 2)
        #expect(activity.visibleCount(at: start.addingTimeInterval(700), resetAfter: 600) == 0)
        activity.record(direction: .forward, at: start.addingTimeInterval(700), policy: policy)
        #expect(activity.count == 1)
        #expect(activity.visibleCount(at: start.addingTimeInterval(701), resetAfter: 600) == 1)
    }

    @Test("The serial changes on every message so Reduce Motion can pulse the badge")
    func serial() {
        var activity = CanvasLinkActivity()
        #expect(activity.serial == 0)
        activity.record(direction: .forward, at: start, policy: policy)
        activity.record(direction: .forward, at: start.addingTimeInterval(0.1), policy: policy)
        #expect(activity.serial == 2)
    }

    @Test("Badge, tooltip, accessibility and announcement text")
    func text() {
        #expect(CanvasLinkText.badge(state: .live, count: 0, label: nil) == "⇄ Live")
        #expect(CanvasLinkText.badge(state: .live, count: 3, label: nil) == "⇄ Live · 3")
        #expect(
            CanvasLinkText.badge(state: .live, count: 3, label: "review") == "⇄ Live · 3 · review")
        #expect(CanvasLinkText.badge(state: .paused, count: 0, label: "") == "‖ Paused")
        #expect(
            CanvasLinkText.tooltip(
                from: "claude — api", to: "codex — tests", isMessageLink: true, state: .live,
                count: 3, label: nil)
                == "claude — api ⇄ codex — tests · Live · 3 messages in 10 min")
        #expect(
            CanvasLinkText.tooltip(
                from: "A", to: "B", isMessageLink: true, state: .live, count: 1, label: nil)
                == "A ⇄ B · Live · 1 message in 10 min")
        #expect(
            CanvasLinkText.tooltip(
                from: "A", to: "B", isMessageLink: true,
                state: .disconnected(.sessionEnded), count: 0, label: nil)
                == "A ⇄ B · Disconnected\nThis session ended. Start the terminal again to reconnect."
        )
        #expect(
            CanvasLinkText.tooltip(
                from: "A", to: "B", isMessageLink: false, state: nil, count: 0, label: "spec for")
                == "A → B · spec for")
        #expect(
            CanvasLinkText.accessibilityLabel(
                from: "claude — api", to: "codex — tests", isMessageLink: true, state: .live,
                label: "review")
                == "Message link from claude — api to codex — tests, Live, label review")
        #expect(
            CanvasLinkText.accessibilityLabel(
                from: "A", to: "B", isMessageLink: false, state: nil, label: nil)
                == "Relationship from A to B")
        #expect(
            CanvasLinkText.announcement(target: "codex — tests", state: .paused)
                == "Link to codex — tests paused")
    }

    @Test("Placeholder labels count as unlabelled")
    func labels() {
        var connection = CanvasConnection(from: CanvasCardID(), to: CanvasCardID())
        #expect(connection.customLabel == nil)
        connection.label = "Session link"
        #expect(connection.customLabel == nil)
        connection.label = "  spec for "
        #expect(connection.customLabel == "spec for")
        #expect(CanvasConnection.placeholderLabel(for: .session) == "Session link")
        #expect(CanvasConnection.placeholderLabel(for: .related) == "Related to")
    }
}
