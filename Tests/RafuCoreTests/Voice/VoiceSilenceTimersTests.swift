import Testing

@testable import RafuCore

@Suite("Voice silence timers")
struct VoiceSilenceTimersTests {
    @Test("Latched silence: check-in at 45 s, pause at 60 s, close at 90 s")
    func latchedSequence() {
        var clock = VoiceActivityClock()
        clock.setLatched(true, at: .zero)
        #expect(clock.nextAction(at: .seconds(44)) == nil)
        #expect(clock.nextAction(at: .seconds(45)) == .checkIn)
        clock.checkedIn = true
        #expect(clock.nextAction(at: .seconds(50)) == nil)
        #expect(clock.nextAction(at: .seconds(60)) == .pause)
        clock.paused = true
        #expect(clock.nextAction(at: .seconds(89)) == nil)
        #expect(clock.nextAction(at: .seconds(90)) == .close)
    }

    @Test("Speech resets the silence and clears the check-in")
    func speechResets() {
        var clock = VoiceActivityClock()
        clock.setLatched(true, at: .zero)
        clock.checkedIn = true
        clock.noteSpeech(at: .seconds(50))
        #expect(!clock.checkedIn)
        #expect(clock.nextAction(at: .seconds(94)) == nil)
        #expect(clock.nextAction(at: .seconds(95)) == .checkIn)
    }

    @Test("Server activity keeps the session open but a held session never checks in")
    func heldSession() {
        var clock = VoiceActivityClock()
        clock.noteServerActivity(at: .seconds(30))
        #expect(clock.nextAction(at: .seconds(100)) == nil)
        #expect(clock.nextAction(at: .seconds(119)) == nil)
        #expect(clock.nextAction(at: .seconds(120)) == .close)
    }

    @Test("Open work orders extend the idle close to ten minutes")
    func workOrders() {
        var clock = VoiceActivityClock()
        clock.openWorkOrders = 1
        #expect(clock.nextAction(at: .seconds(90)) == nil)
        #expect(clock.nextAction(at: .seconds(600)) == .close)
    }

    @Test("Instants never move backwards")
    func monotonic() {
        var clock = VoiceActivityClock()
        clock.noteSpeech(at: .seconds(40))
        clock.noteSpeech(at: .seconds(10))
        #expect(clock.lastSpeech == .seconds(40))
    }
}
