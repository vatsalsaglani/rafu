import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting turns: assigner and builder")
struct MeetingTurnBuilderTests {
    private typealias Words = MeetingTestWords

    // MARK: Speaker assignment

    @Test("Them word: most overlap, then nearest within 0.5 s, else them")
    func assignerRules() {
        let segments = [
            MeetingSpeakerSegment(speaker: 1, start: 0, end: 2),
            MeetingSpeakerSegment(speaker: 2, start: 2, end: 6),
        ]
        let rows: [(MeetingWord, MeetingSpeakerLabel, String)] = [
            (Words.word("a", 0.25, 0.75), .speaker(1), "inside the first segment"),
            (Words.word("b", 1.5, 2.5), .speaker(1), "equal overlap, the earlier segment"),
            (Words.word("c", 1.75, 3.0), .speaker(2), "more overlap with the second"),
            (Words.word("d", 6.25, 6.5), .speaker(2), "no overlap, 0.25 s after the end"),
            (Words.word("e", 6.5, 7.0), .speaker(2), "no overlap, exactly 0.5 s"),
            (Words.word("f", 6.75, 7.0), .them, "no overlap, 0.75 s away"),
            (Words.word("g", 30, 31), .them, "far from every segment"),
        ]
        for (word, expected, note) in rows {
            #expect(
                MeetingWordSpeakerAssigner.label(for: word, segments: segments) == expected,
                Comment(rawValue: note))
        }
    }

    @Test("No speaker segments: every Them word is them")
    func noSegments() {
        let words = Words.sentence("hello there everyone", from: 1)
        let assigned = MeetingWordSpeakerAssigner.assign(themWords: words, segments: [])
        #expect(assigned.map(\.speaker) == [.them, .them, .them])
        #expect(assigned.allSatisfy { $0.track == .them })

        let turns = MeetingTurnBuilder.build(meWords: [], themWords: words, segments: [])
        #expect(turns.map(\.speaker) == [.them])
    }

    @Test("Malformed segments are ignored")
    func malformedSegments() {
        let segments = [
            MeetingSpeakerSegment(speaker: -1, start: 0, end: 5),
            MeetingSpeakerSegment(speaker: 1, start: 5, end: 1),
            MeetingSpeakerSegment(speaker: 2, start: .nan, end: 4),
        ]
        let label = MeetingWordSpeakerAssigner.label(
            for: Words.word("x", 1, 2), segments: segments)
        #expect(label == .them)
    }

    // MARK: Turn rules

    @Test("A pause of 1.0 s starts a new turn; a shorter gap does not")
    func pauseRule() {
        // The gap is the next start minus the end of the last word (0.5).
        let rows: [(nextStart: TimeInterval, turns: Int)] = [
            (0.5, 1), (1.0, 1), (1.25, 1), (1.4375, 1), (1.5, 2), (2.0, 2), (30, 2),
        ]
        for row in rows {
            let words = [
                Words.word("one", 0, 0.5), Words.word("two", row.nextStart, row.nextStart + 0.25),
            ]
            let turns = MeetingTurnBuilder.build(meWords: words, themWords: [], segments: [])
            #expect(turns.count == row.turns, "next word at \(row.nextStart)")
        }
        #expect(MeetingTurnRules.pauseSeconds == 1.0)
    }

    @Test("A speaker change starts a new turn with no pause")
    func speakerChange() {
        let them = [
            Words.word("good", 0, 0.25), Words.word("morning", 0.25, 0.5),
            Words.word("hello", 0.5, 0.75), Words.word("again", 0.75, 1.0),
        ]
        let segments = [
            MeetingSpeakerSegment(speaker: 1, start: 0, end: 0.5),
            MeetingSpeakerSegment(speaker: 2, start: 0.5, end: 1.0),
        ]
        let turns = MeetingTurnBuilder.build(meWords: [], themWords: them, segments: segments)
        #expect(turns.map(\.speaker) == [.speaker(1), .speaker(2)])
        #expect(turns.map(\.text) == ["good morning", "hello again"])
    }

    @Test("A track change starts a new turn")
    func trackChange() {
        let turns = MeetingTurnBuilder.build(
            meWords: Words.sentence("how are you", from: 0),
            themWords: Words.sentence("fine thanks", from: 2),
            segments: [])
        #expect(turns.map(\.track) == [.me, .them])
        #expect(turns.map(\.text) == ["how are you", "fine thanks"])
        #expect(turns.map(\.speaker) == [.me, .them])
        #expect(turns[0].start == 0 && turns[0].end == 1.25)
    }

    @Test("Two people say yes at the same time: two turns, never merged")
    func simultaneousYes() {
        let turns = MeetingTurnBuilder.build(
            meWords: [Words.word("yes", 5, 5.25)],
            themWords: [Words.word("yes", 5, 5.25)],
            segments: [MeetingSpeakerSegment(speaker: 1, start: 4, end: 6)])
        #expect(turns.count == 2)
        #expect(turns.map(\.track) == [.me, .them])
        #expect(turns.map(\.speaker) == [.me, .speaker(1)])
        #expect(turns.map(\.text) == ["yes", "yes"])
    }

    @Test("Overlapped speech keeps each track's sentence in one turn")
    func overlappedSpeech() {
        let turns = MeetingTurnBuilder.build(
            meWords: Words.sentence("we should ship it", from: 0, step: 0.5),
            themWords: [Words.word("right", 0.75, 1.0)],
            segments: [])
        #expect(turns.map(\.text) == ["we should ship it", "right"])
        #expect(turns.map(\.track) == [.me, .them])
    }

    @Test("Words out of order are sorted; blank and invalid words are dropped")
    func unsortedInput() {
        let words = [
            Words.word("three", 1.0, 1.25), Words.word("one", 0, 0.25), Words.word("  ", 0.25, 0.5),
            Words.word("two", 0.5, 0.75), Words.word("bad", .nan, 1), Words.word("", 0.75, 0.8),
        ]
        let turns = MeetingTurnBuilder.build(meWords: words, themWords: [], segments: [])
        #expect(turns.map(\.text) == ["one two three"])
        #expect(turns[0].start == 0 && turns[0].end == 1.25)
    }

    @Test("Empty tracks give no turns; one empty track gives the other's turns")
    func emptyTracks() {
        #expect(MeetingTurnBuilder.build(meWords: [], themWords: [], segments: []).isEmpty)
        let onlyThem = MeetingTurnBuilder.build(
            meWords: [], themWords: Words.sentence("hello", from: 1), segments: [])
        #expect(onlyThem.count == 1 && onlyThem[0].track == .them)
        #expect(onlyThem[0].id == MeetingTurnID(1))
    }

    // MARK: Ids

    private func sampleTurns() -> [MeetingTurn] {
        MeetingTurnBuilder.build(
            meWords: Words.sentence("so what do you think", from: 0)
                + Words.sentence("sounds good to me", from: 20),
            themWords: Words.sentence("the budget is due friday", from: 4)
                + Words.sentence("i will send it today", from: 9),
            segments: [
                MeetingSpeakerSegment(speaker: 1, start: 3, end: 8),
                MeetingSpeakerSegment(speaker: 2, start: 8, end: 14),
            ])
    }

    @Test("Ids are t1, t2, ... in turn order and a second build gives the same ids")
    func idsAreOrderedAndRepeatable() {
        let first = sampleTurns()
        let second = sampleTurns()
        #expect(first.map(\.id.text) == ["t1", "t2", "t3", "t4"])
        #expect(first == second)
        #expect(first.map(\.start) == first.map(\.start).sorted())

        let shifted = MeetingTurnBuilder.build(
            meWords: [Words.word("hi", 0, 0.25)], themWords: [], segments: [], firstTurnNumber: 10)
        #expect(shifted.map(\.id) == [MeetingTurnID(10)])
    }

    @Test("Input order does not change the ids")
    func idsIgnoreInputOrder() {
        let me = Words.sentence("so what do you think", from: 0)
        let them = Words.sentence("the budget is due friday", from: 4)
        let straight = MeetingTurnBuilder.build(meWords: me, themWords: them, segments: [])
        let shuffled = MeetingTurnBuilder.build(
            meWords: me.reversed(), themWords: them.reversed(), segments: [])
        #expect(straight == shuffled)
    }

    @Test("A rename, a text correction and an echo mark never change an id")
    func idsAreStableUnderEdits() {
        let turns = sampleTurns()
        let ids = turns.map(\.id)

        var list = MeetingEditList()
        list.append(.renameSpeaker(label: .speaker(1), name: "Priya", source: .user))
        list.append(.correctText(turn: ids[1], text: "The budget is due on Friday"))
        list.append(.setEchoShown(turn: ids[0], shown: true))
        #expect(list.display(turns).map(\.id) == ids)

        let marked = MeetingEchoMarker.mark(turns, outputWasSpeakers: true)
        #expect(marked.turns.map(\.id) == ids)

        // The citation t2 still opens the same turn after the rename.
        let renamed = list.display(marked.turns)
        #expect(renamed.first { $0.id == MeetingTurnID(text: "t2") }?.speakerName == "Priya")
    }
}
