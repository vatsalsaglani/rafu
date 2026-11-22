import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting echo marker")
struct MeetingEchoMarkerTests {
    private typealias Words = MeetingTestWords

    private static let sentence = "so the budget is due on friday"

    /// A far-side turn at 10.0 s and a "Me" turn at `meStart` with `meText`.
    private func pair(
        meStart: TimeInterval = 10.03125, meText: String = MeetingEchoMarkerTests.sentence
    ) -> [MeetingTurn] {
        [
            Words.turn(1, .them, .speaker(1), 10, Self.sentence),
            Words.turn(2, .me, .me, meStart, meText),
        ]
    }

    private func isEcho(_ turns: [MeetingTurn], speakers: Bool = true) -> Bool {
        MeetingEchoMarker.mark(turns, outputWasSpeakers: speakers).turns[1].isEcho
    }

    @Test("An exact repeat 30 ms later is marked; text and ids stay")
    func exactRepeat() {
        let turns = pair()
        let result = MeetingEchoMarker.mark(turns, outputWasSpeakers: true)
        #expect(result.turns[1].isEcho)
        #expect(!result.turns[0].isEcho)
        #expect(result.echoCount == 1)
        #expect(result.turns.map(\.text) == turns.map(\.text))
        #expect(result.turns.map(\.id) == turns.map(\.id))
        #expect(result.turns.count == turns.count)
    }

    @Test("Case, punctuation and accents do not matter")
    func normalisation() {
        #expect(isEcho(pair(meText: "So, the BUDGET is due — on Friday!")))
        #expect(MeetingEchoMarker.normalisedWords("Don't — café, OK?") == ["dont", "cafe", "ok"])
    }

    @Test("A repeat with one wrong word is marked; a repeat with two wrong words is not")
    func wrongWords() {
        // Seven words: six match is 85%; five match is 71%.
        #expect(isEcho(pair(meText: "so the budget is due in friday")))
        #expect(!isEcho(pair(meText: "so the budget was due in friday")))
        // Five words: four match is exactly 80%.
        let short = [
            Words.turn(1, .them, .them, 10, "send the file to me"),
            Words.turn(2, .me, .me, 10.03125, "send the file to you"),
        ]
        #expect(isEcho(short))
    }

    @Test("A short real answer is not an echo, even when it matches")
    func shortAnswer() {
        let them = Words.turn(1, .them, .them, 10, "yes")
        let me = Words.turn(2, .me, .me, 10.03125, "yes")
        #expect(!isEcho([them, me]))
        let two = [
            Words.turn(1, .them, .them, 10, "yes sure"),
            Words.turn(2, .me, .me, 10.03125, "yes sure"),
        ]
        #expect(!isEcho(two))
        let three = [
            Words.turn(1, .them, .them, 10, "yes sure thing"),
            Words.turn(2, .me, .me, 10.03125, "yes sure thing"),
        ]
        #expect(isEcho(three))
    }

    @Test("The same sentence 5 s later is a real repeat, not an echo")
    func laterRepeat() {
        #expect(!isEcho(pair(meStart: 15)))
        #expect(!isEcho(pair(meStart: 15.03125)))
    }

    @Test("The start window runs from -0.3 s to +2.0 s")
    func startWindow() {
        // `them.start - me.start`: me at 10.25 gives -0.25 (inside).
        #expect(isEcho(pair(meStart: 10.25)))
        #expect(!isEcho(pair(meStart: 10.5)))
        // The Me turn starts before the far turn: +2.0 inside, more outside.
        #expect(isEcho(pair(meStart: 8)))
        #expect(!isEcho(pair(meStart: 7.75)))
        #expect(MeetingEchoMarker.themStartWindow == -0.3...2.0)
    }

    @Test("Words in another order are not an echo")
    func wordOrder() {
        #expect(!isEcho(pair(meText: "friday on due is budget the so")))
    }

    @Test("Headphones: nothing is marked")
    func headphones() {
        let result = MeetingEchoMarker.mark(pair(), outputWasSpeakers: false)
        #expect(result.turns == pair())
        #expect(result.echoCount == 0)
    }

    @Test("A Me turn is never compared with another Me turn, and Them is never marked")
    func onlyMeAgainstThem() {
        let turns = [
            Words.turn(1, .me, .me, 10, Self.sentence),
            Words.turn(2, .me, .me, 10.03125, Self.sentence),
            Words.turn(3, .them, .them, 30, Self.sentence),
            Words.turn(4, .them, .them, 30.03125, Self.sentence),
        ]
        let result = MeetingEchoMarker.mark(turns, outputWasSpeakers: true)
        #expect(result.echoCount == 0)
    }

    @Test("Marking is repeatable and counts turns already marked")
    func repeatable() {
        let once = MeetingEchoMarker.mark(pair(), outputWasSpeakers: true)
        let twice = MeetingEchoMarker.mark(once.turns, outputWasSpeakers: true)
        #expect(once == twice)

        let several =
            pair() + [
                Words.turn(3, .them, .speaker(1), 40, Self.sentence),
                Words.turn(4, .me, .me, 40.03125, Self.sentence),
            ]
        #expect(MeetingEchoMarker.mark(several, outputWasSpeakers: true).echoCount == 2)
    }

    @Test("No turns, no echo")
    func empty() {
        let result = MeetingEchoMarker.mark([], outputWasSpeakers: true)
        #expect(result.turns.isEmpty && result.echoCount == 0)
    }

    @Test("The longest common subsequence")
    func subsequence() {
        #expect(
            MeetingEchoMarker.longestCommonSubsequence(["a", "b", "c"], ["a", "x", "b", "c"]) == 3)
        #expect(MeetingEchoMarker.longestCommonSubsequence(["a", "b", "c"], ["c", "b", "a"]) == 1)
        #expect(MeetingEchoMarker.longestCommonSubsequence([], ["a"]) == 0)
    }
}
