import AppKit
import Testing

@testable import RafuApp

/// Zero-config agent-completion detection: a qualified burst of output
/// followed by silence fires attention (terminal-manager.md T-E follow-up).
/// Pure policy — injected dates, no timers, no sleeps.
@Suite("Terminal quiescence policy")
struct TerminalQuiescenceTests {
    private let policy = TerminalQuiescencePolicy(
        minimumBusySeconds: 4, minimumBusyBytes: 2_048, quietSeconds: 2.5
    )
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("A qualified burst followed by silence fires exactly once")
    func qualifiedBurstFires() {
        var state = TerminalQuiescencePolicy.State.idle
        // 5 seconds of spinner-style output, plenty of bytes.
        for second in 0..<5 {
            state = policy.advance(state, bytes: 1_000, at: t0.addingTimeInterval(Double(second)))
        }
        // Not quiet yet.
        var check = policy.checkQuiescence(state, at: t0.addingTimeInterval(5))
        #expect(!check.fired)
        // Quiet long enough → fires, and the state resets so it cannot
        // fire twice.
        check = policy.checkQuiescence(check.state, at: t0.addingTimeInterval(8))
        #expect(check.fired)
        #expect(check.state == .idle)
        let again = policy.checkQuiescence(check.state, at: t0.addingTimeInterval(20))
        #expect(!again.fired)
    }

    @Test("A short burst — a prompt repaint, an ls — never fires")
    func shortBurstNeverFires() {
        var state = TerminalQuiescencePolicy.State.idle
        state = policy.advance(state, bytes: 5_000, at: t0)
        state = policy.advance(state, bytes: 5_000, at: t0.addingTimeInterval(0.5))
        // Loud but brief: bytes qualify, duration does not.
        let check = policy.checkQuiescence(state, at: t0.addingTimeInterval(10))
        #expect(!check.fired)
        #expect(check.state == .idle)
    }

    @Test("A long trickle below the byte floor never fires")
    func quietTrickleNeverFires() {
        var state = TerminalQuiescencePolicy.State.idle
        for second in 0..<10 {
            state = policy.advance(state, bytes: 10, at: t0.addingTimeInterval(Double(second)))
        }
        let check = policy.checkQuiescence(state, at: t0.addingTimeInterval(15))
        #expect(!check.fired)
    }

    @Test("Continued output keeps the burst alive instead of firing")
    func continuedOutputDefersFiring() {
        var state = TerminalQuiescencePolicy.State.idle
        for second in 0..<5 {
            state = policy.advance(state, bytes: 1_000, at: t0.addingTimeInterval(Double(second)))
        }
        // One second of quiet — under the 2.5s threshold.
        let check = policy.checkQuiescence(state, at: t0.addingTimeInterval(5.9))
        #expect(!check.fired)
        if case .idle = check.state {
            Issue.record("burst must survive sub-threshold quiet")
        }
    }

    @Test("The dataReceived tap reports byte counts without inspecting content")
    @MainActor
    func dataReceivedTapReportsBytes() {
        let view = RafuTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var counts: [Int] = []
        view.onOutputActivity = { counts.append($0) }
        view.dataReceived(slice: ArraySlice(Array("hello".utf8)))
        view.dataReceived(slice: ArraySlice(Array("\u{1b}]9;done\u{07}".utf8)))
        #expect(counts == [5, 9])
    }
}
