import Testing
@testable import SpikeScoring

@Suite("TokenWordGrouper")
struct TokenWordGrouperTests {
    @Test("groups sub-word tokens into words at each word-start mark")
    func groups() {
        let tokens = [
            Token(text: "▁we", time: 0.0, isWordStart: true),
            Token(text: "▁should", time: 0.2, isWordStart: true),
            Token(text: "▁ship", time: 0.5, isWordStart: true),
            Token(text: "pers", time: 0.6, isWordStart: false),
            Token(text: "▁it", time: 0.9, isWordStart: true),
        ]
        let words = TokenWordGrouper.words(from: tokens, fallbackEnd: 1.2)
        #expect(words.map(\.text) == ["▁we", "▁should", "▁shippers", "▁it"])
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.2)
        #expect(words[2].start == 0.5)
        #expect(words[2].end == 0.9)
        #expect(words[3].end == 1.2) // last word uses the fallback end
    }

    @Test("an empty token list gives no words")
    func empty() {
        #expect(TokenWordGrouper.words(from: [], fallbackEnd: 1.0).isEmpty)
    }

    @Test("a leading continuation token starts the first word anyway")
    func leadingContinuation() {
        let tokens = [
            Token(text: "ab", time: 0.0, isWordStart: false),
            Token(text: "▁next", time: 0.3, isWordStart: true),
        ]
        let words = TokenWordGrouper.words(from: tokens, fallbackEnd: 0.6)
        #expect(words.map(\.text) == ["ab", "▁next"])
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.3)
    }
}
