import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting live turns")
struct MeetingLiveTurnAssemblerTests {
    private typealias Words = MeetingTestWords

    @Test("Final words and a volatile tail make one turn")
    func finalAndVolatile() {
        var assembler = MeetingLiveTurnAssembler()
        assembler.ingest(.final(words: Words.sentence("hello there", from: 0)), track: .them)
        assembler.ingest(.volatile(text: "how are", range: 1.0...1.75), track: .them)
        let turns = assembler.turns()
        #expect(turns.count == 1)
        #expect(turns[0].text == "hello there how are")
        #expect(turns[0].isVolatile)
        #expect(turns[0].speaker == .them)
    }

    @Test("A final event replaces the volatile text it covers")
    func finalReplacesVolatile() {
        var assembler = MeetingLiveTurnAssembler()
        assembler.ingest(.volatile(text: "hello thr", range: 0...1.0), track: .me)
        assembler.ingest(.final(words: Words.sentence("hello there", from: 0)), track: .me)
        let turns = assembler.turns()
        #expect(turns.map(\.text) == ["hello there"])
        #expect(!turns[0].isVolatile)

        assembler.ingest(.volatile(text: "and then", range: 1.0...1.5), track: .me)
        #expect(assembler.turns().map(\.text) == ["hello there and then"])
    }

    @Test("A pause of 1.0 s starts a new live turn")
    func pause() {
        var assembler = MeetingLiveTurnAssembler()
        assembler.ingest(
            .final(words: [
                Words.word("one", 0, 0.5), Words.word("two", 1.25, 1.5),
                Words.word("three", 2.5, 2.75),
            ]),
            track: .me)
        #expect(assembler.turns().map(\.text) == ["one two", "three"])
    }

    @Test("Two tracks stay separate, ordered by start")
    func twoTracks() {
        var assembler = MeetingLiveTurnAssembler()
        assembler.ingest(.final(words: Words.sentence("yes", from: 5)), track: .them)
        assembler.ingest(.final(words: Words.sentence("yes", from: 5)), track: .me)
        assembler.ingest(.final(words: Words.sentence("earlier", from: 1)), track: .them)
        let turns = assembler.turns()
        #expect(turns.map(\.text) == ["earlier", "yes", "yes"])
        #expect(turns.map(\.track) == [.them, .me, .them])
        #expect(Set(turns.map(\.id)).count == 3)
    }

    @Test("Final words that arrive out of order are sorted")
    func outOfOrder() {
        var assembler = MeetingLiveTurnAssembler()
        assembler.ingest(.final(words: [Words.word("two", 0.5, 0.75)]), track: .me)
        assembler.ingest(.final(words: [Words.word("one", 0, 0.25)]), track: .me)
        #expect(assembler.turns().map(\.text) == ["one two"])
    }

    @Test("Unavailable clears the preview and keeps the final words")
    func unavailable() {
        var assembler = MeetingLiveTurnAssembler()
        assembler.ingest(.final(words: Words.sentence("kept words", from: 0)), track: .them)
        assembler.ingest(.volatile(text: "gone", range: 1.0...1.5), track: .them)
        assembler.ingest(.unavailable(reason: "Speech stopped"), track: .them)
        #expect(assembler.turns().map(\.text) == ["kept words"])
        #expect(assembler.unavailableReason(for: .them) == "Speech stopped")
        #expect(assembler.unavailableReason(for: .me) == nil)
    }

    @Test("Empty input gives no turns")
    func empty() {
        var assembler = MeetingLiveTurnAssembler()
        #expect(assembler.turns().isEmpty)
        assembler.ingest(.volatile(text: "   ", range: 0...1), track: .me)
        assembler.ingest(.final(words: []), track: .me)
        #expect(assembler.turns().isEmpty)
    }
}
