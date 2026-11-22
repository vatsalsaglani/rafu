import Testing
@testable import SpikeScoring

@Suite("TurnBuilder")
struct TurnBuilderTests {
    @Test("a speaker change starts a new turn (rule 1)")
    func speakerChange() {
        let words = [
            TimedWord(text: "hi", start: 0, end: 0.3, speaker: "A"),
            TimedWord(text: "there", start: 0.3, end: 0.6, speaker: "A"),
            TimedWord(text: "hello", start: 0.7, end: 1.0, speaker: "B"),
        ]
        let turns = TurnBuilder.build(words: words)
        #expect(turns.count == 2)
        #expect(turns[0].speaker == "A")
        #expect(turns[1].speaker == "B")
    }

    @Test("a pause of 0.8 s or more in the same speaker starts a new turn (rule 2)")
    func pauseSplitsTurn() {
        let words = [
            TimedWord(text: "one", start: 0, end: 0.3, speaker: "A"),
            TimedWord(text: "two", start: 1.2, end: 1.5, speaker: "A"), // 0.9 s gap
        ]
        let turns = TurnBuilder.build(words: words)
        #expect(turns.count == 2)
    }

    @Test("a short pause in the same speaker stays one turn")
    func shortPauseStaysOneTurn() {
        let words = [
            TimedWord(text: "one", start: 0, end: 0.3, speaker: "A"),
            TimedWord(text: "two", start: 0.5, end: 0.8, speaker: "A"), // 0.2 s gap
        ]
        let turns = TurnBuilder.build(words: words)
        #expect(turns.count == 1)
        #expect(turns[0].text == "one two")
    }

    @Test("a short reply inside another speaker's turn is a backchannel (rule 4)")
    func backchannel() {
        let words = [
            TimedWord(text: "so", start: 0, end: 0.3, speaker: "A"),
            TimedWord(text: "yes", start: 0.4, end: 0.6, speaker: "B"),
            TimedWord(text: "anyway", start: 0.7, end: 1.0, speaker: "A"),
        ]
        // Force the A words into one turn by keeping the pause short: 0 to 0.3,
        // then 0.7 to 1.0 is only a 0.4 s gap from 0.3, under the 0.8 s default.
        let turns = TurnBuilder.build(words: words)
        let backchannelTurn = turns.first { $0.speaker == "B" }
        #expect(backchannelTurn?.isBackchannel == true)
        let aTurn = turns.first { $0.speaker == "A" }
        #expect(aTurn?.words.count == 2) // not cut in two
    }

    @Test("two speakers overlapping in time both get the overlap flag (rule 5)")
    func overlapFlag() {
        let words = [
            TimedWord(text: "well", start: 0, end: 1.0, speaker: "A"),
            TimedWord(text: "actually", start: 0.5, end: 1.5, speaker: "B"),
        ]
        let turns = TurnBuilder.build(words: words)
        #expect(turns.allSatisfy { $0.isOverlap })
    }

    @Test("words without a speaker are dropped")
    func unlabeledDropped() {
        let words = [
            TimedWord(text: "hi", start: 0, end: 0.3, speaker: nil),
            TimedWord(text: "there", start: 0.4, end: 0.6, speaker: "A"),
        ]
        let turns = TurnBuilder.build(words: words)
        #expect(turns.count == 1)
        #expect(turns[0].text == "there")
    }
}
