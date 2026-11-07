import Testing

@testable import RafuCore

@Suite("Voice blob state")
struct VoiceBlobStateTests {
    private func machine(_ events: [VoiceBlobEvent]) -> VoiceBlobMachine {
        var machine = VoiceBlobMachine()
        for event in events { machine.apply(event) }
        return machine
    }

    @Test("Hold to talk: connect, listen, release to think, speak, pause")
    func holdToTalk() {
        var value = VoiceBlobMachine()
        value.apply(.holdBegan)
        #expect(value.state == .connecting)
        #expect(value.isMicOpen)
        value.apply(.connected)
        #expect(value.state == .listeningHeld)
        value.apply(.holdEnded)
        #expect(value.state == .thinking)
        #expect(!value.isMicOpen)
        value.apply(.replyStarted)
        #expect(value.state == .speaking)
        value.apply(.replyEnded)
        #expect(value.state == .paused)
    }

    @Test("Releasing before the socket connects leaves an open, muted session")
    func releaseWhileConnecting() {
        let value = machine([.holdBegan, .holdEnded, .connected])
        #expect(value.state == .paused)
        #expect(value.mic == .off)
    }

    @Test("Latched: listens through replies, checks in, resumes on speech, pauses")
    func latched() {
        var value = machine([.latchToggled, .connected])
        #expect(value.state == .listeningLatched)
        value.apply(.delegationStarted)
        #expect(value.state == .thinking)
        #expect(value.isMicOpen)
        value.apply(.replyStarted)
        value.apply(.replyEnded)
        #expect(value.state == .listeningLatched)
        value.apply(.checkIn)
        #expect(value.state == .checkIn)
        value.apply(.replyStarted)
        #expect(value.state == .checkIn)
        value.apply(.speechDetected)
        #expect(value.state == .listeningLatched)
        value.apply(.checkIn)
        value.apply(.pause)
        #expect(value.state == .paused)
        #expect(!value.isMicOpen)
        value.apply(.latchToggled)
        #expect(value.state == .listeningLatched)
        value.apply(.latchToggled)
        #expect(value.state == .paused)
    }

    @Test("A held key does nothing to a latched session")
    func holdIgnoredWhileLatched() {
        var value = machine([.latchToggled, .connected])
        value.apply(.holdBegan)
        value.apply(.holdEnded)
        #expect(value.state == .listeningLatched)
        #expect(value.mic == .latched)
    }

    @Test("Illegal events are no-ops")
    func illegal() {
        for event: VoiceBlobEvent in [
            .holdEnded, .connected, .delegationStarted, .replyStarted, .replyEnded,
            .speechDetected, .checkIn, .pause, .needsConfirm, .confirmResolved, .closed,
        ] {
            #expect(machine([event]) == VoiceBlobMachine(), "\(event)")
        }
        let held = machine([.holdBegan, .connected])
        var checked = held
        checked.apply(.checkIn)
        #expect(checked == held)
    }

    @Test("Failure shows the reason until a new press or reset; close returns to idle")
    func failureAndClose() {
        var value = machine([.holdBegan, .failed("Microphone access is off")])
        #expect(value.state == .error("Microphone access is off"))
        #expect(!value.isMicOpen)
        value.apply(.closed)
        #expect(value.state == .error("Microphone access is off"))
        value.apply(.reset)
        #expect(value.state == .idle)
        value = machine([.latchToggled, .connected, .closed])
        #expect(value.state == .idle)
        #expect(value.mic == .off)
    }

    @Test("Every state has a word, a symbol and an accessibility label")
    func presentation() {
        let states: [VoiceBlobState] = [
            .idle, .connecting, .listeningHeld, .listeningLatched, .thinking, .speaking,
            .checkIn, .paused, .needsConfirm, .error("x"),
        ]
        for state in states {
            #expect(!state.word.isEmpty)
            #expect(!state.symbol.isEmpty)
            #expect(!state.accessibilityLabel.isEmpty)
        }
    }
}
