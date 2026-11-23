import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting echo marks per word")
struct MeetingEchoWordMarkerTests {
    private typealias Words = MeetingTestWords

    private func mark(
        me: [MeetingWord], them: [MeetingWord], speakers: Bool = true
    ) -> [Bool] {
        MeetingEchoWordMarker.mark(meWords: me, themWords: them, outputWasSpeakers: speakers)
    }

    @Test("Echo 0.25 s late with one word in five different: every word is echo")
    func perWord() {
        let them = Words.anonymous(20, from: 10)
        var me = Words.heard(them)
        for index in stride(from: 2, to: me.count, by: 5) { me[index].text = "other" }
        #expect(mark(me: me, them: them) == Array(repeating: true, count: 20))

        let turns = MeetingTurnBuilder.build(
            meWords: me, themWords: them, segments: [], outputWasSpeakers: true)
        let meTurns = turns.filter { $0.track == .me }
        #expect(meTurns.count == 1 && meTurns[0].isEcho)
        #expect(meTurns[0].text.split(separator: " ").count == 20)
    }

    @Test("Headphones: the same words are never echo")
    func headphones() {
        let them = Words.anonymous(20, from: 10)
        let me = Words.heard(them)
        #expect(mark(me: me, them: them, speakers: false) == Array(repeating: false, count: 20))
        let turns = MeetingTurnBuilder.build(
            meWords: me, themWords: them, segments: [], outputWasSpeakers: false)
        #expect(turns.allSatisfy { !$0.isEcho })
    }

    @Test("Echo that starts 8 s after the far turn is still echo")
    func lateStart() {
        let them = Words.anonymous(40, from: 0)
        let me = Words.heard(Array(them[16...]))
        #expect(me[0].start == 8.25)
        let result = MeetingTranscriptAssembly.assemble(
            me: MeetingTrackTranscript(track: .me, words: me, engine: .appleSpeech),
            them: MeetingTrackTranscript(track: .them, words: them, engine: .appleSpeech),
            segments: [], outputWasSpeakers: true)
        #expect(result.turns.filter { $0.track == .me }.allSatisfy { $0.isEcho })
        #expect(result.echoCount == 1)
    }

    @Test("One long Nemotron turn with 79.7% of its words matched is echo")
    func nemotronLongTurn() {
        let them = Words.nemotronShape(Words.anonymous(59, from: 0))
        var me = Words.heard(them)
        // 12 of 59 words differ: 47 of 59 match (79.7%).
        for index in stride(from: 0, to: me.count, by: 5) { me[index].text = "mine" }
        #expect(mark(me: me, them: them).allSatisfy { $0 })
        let turns = MeetingTurnBuilder.build(
            meWords: me, themWords: them, segments: [], outputWasSpeakers: true)
        #expect(turns.filter { $0.track == .me }.allSatisfy { $0.isEcho })
    }

    @Test("20 echo words then 20 real words: two Me turns, the first is echo")
    func mixedTurn() {
        let them = Words.anonymous(20, from: 10)
        let me = Words.heard(them) + Words.anonymous(20, from: 20.25, prefix: "real")
        let flags = mark(me: me, them: them)
        #expect(flags == Array(repeating: true, count: 20) + Array(repeating: false, count: 20))

        let meTurns = MeetingTurnBuilder.build(
            meWords: me, themWords: them, segments: [], outputWasSpeakers: true
        ).filter { $0.track == .me }
        #expect(meTurns.map(\.isEcho) == [true, false])
        #expect(meTurns[1].text.hasPrefix("real0 real1"))
    }

    @Test("Real speech over a short far backchannel is not echo")
    func backchannel() {
        var me = Words.anonymous(60, from: 0, prefix: "mine")
        me[10].text = "yeah"
        me[31].text = "right"
        me[32].text = "okay"
        let them = [
            Words.word("yeah", 5, 5.25), Words.word("right", 15.25, 15.5),
            Words.word("okay", 15.75, 16),
        ]
        #expect(
            MeetingEchoWordMarker.matches(meWords: me, themWords: them).filter { $0 }.count == 3)
        #expect(mark(me: me, them: them).allSatisfy { !$0 })
    }

    @Test("A short real answer is not echo, even when it matches; three words are")
    func shortAnswer() {
        let them = [Words.word("yes", 10, 10.25), Words.word("sure", 10.5, 10.75)]
        #expect(mark(me: Words.heard(them), them: them) == [false, false])

        let three = them + [Words.word("thing", 11, 11.25)]
        #expect(mark(me: Words.heard(three), them: three) == [true, true, true])
    }

    @Test("One Them word matches one Me word; a tie goes to the earlier Them word")
    func matchOnce() {
        let them = [Words.word("hello", 10, 10.25)]
        let me = [
            Words.word("hello", 9.5, 9.75), Words.word("hello", 10.25, 10.5),
            Words.word("hello", 11, 11.25),
        ]
        #expect(
            MeetingEchoWordMarker.matches(meWords: me, themWords: them) == [true, false, false])

        let tie = [Words.word("hello", 9.75, 10), Words.word("hello", 10.25, 10.5)]
        let later = [Words.word("hello", 10, 10.25), Words.word("hello", 11.5, 11.75)]
        // Me at 10.0 takes 9.75; then 11.5 can still take 10.25 (1.25 s).
        #expect(MeetingEchoWordMarker.matches(meWords: later, themWords: tie) == [true, true])
    }

    @Test("A match needs the same normalised text within 1.5 s")
    func matchWindow() {
        let them = [Words.word("Budget,", 10, 10.25)]
        let rows: [(TimeInterval, Bool)] = [
            (11.5, true), (8.5, true), (11.75, false), (8.25, false),
        ]
        for (start, expected) in rows {
            let me = [Words.word("budget", start, start + 0.25)]
            #expect(
                MeetingEchoWordMarker.matches(meWords: me, themWords: them) == [expected],
                "Me at \(start)")
        }
        let punctuation = [Words.word("—", 10, 10.25)]
        #expect(
            MeetingEchoWordMarker.matches(meWords: punctuation, themWords: punctuation) == [false])
        #expect(MeetingEchoWordMarker.matchSeconds == 1.5)
    }

    @Test("Flags follow the input order of the Me words")
    func inputOrder() {
        let them = Words.anonymous(20, from: 10)
        let me = Words.heard(them) + Words.anonymous(20, from: 20.25, prefix: "real")
        let reversed = Array(me.reversed())
        #expect(mark(me: reversed, them: them) == Array(mark(me: me, them: them).reversed()))
    }

    @Test("Normalisation ignores case, punctuation and accents")
    func normalisation() {
        #expect(MeetingEchoMarker.normalisedWords("Don't — café, OK?") == ["dont", "cafe", "ok"])
    }

    @Test("No words, no echo")
    func empty() {
        #expect(mark(me: [], them: Words.anonymous(3, from: 0)).isEmpty)
        #expect(mark(me: Words.anonymous(3, from: 0), them: []) == [false, false, false])
        let result = MeetingTranscriptAssembly.assemble(
            me: nil, them: nil, segments: [], outputWasSpeakers: true)
        #expect(result.turns.isEmpty && result.echoCount == 0)
    }
}
