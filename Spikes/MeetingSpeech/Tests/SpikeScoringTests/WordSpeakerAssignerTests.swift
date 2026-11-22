import Testing
@testable import SpikeScoring

@Suite("WordSpeakerAssigner")
struct WordSpeakerAssignerTests {
    @Test("a word inside one segment gets that speaker")
    func simpleCase() {
        let words = [TimedWord(text: "hello", start: 1.0, end: 1.4)]
        let segments = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2, end: 4),
        ]
        let result = WordSpeakerAssigner.assign(words: words, segments: segments)
        #expect(result[0].speaker == "A")
    }

    @Test("a word split across two speakers goes to the one with more overlap")
    func splitAcrossSpeakers() {
        // Word spans 1.8 to 2.4: 0.2 s with A, 0.4 s with B.
        let words = [TimedWord(text: "umbrella", start: 1.8, end: 2.4)]
        let segments = [
            DiarSegment(speaker: "A", start: 0, end: 2.0),
            DiarSegment(speaker: "B", start: 2.0, end: 4.0),
        ]
        let result = WordSpeakerAssigner.assign(words: words, segments: segments)
        #expect(result[0].speaker == "B")
    }

    @Test("a word with no overlapping segment keeps its existing speaker")
    func noOverlapKeepsExisting() {
        let words = [TimedWord(text: "hi", start: 10, end: 10.3, speaker: "Me")]
        let segments = [DiarSegment(speaker: "A", start: 0, end: 2)]
        let result = WordSpeakerAssigner.assign(words: words, segments: segments)
        #expect(result[0].speaker == "Me")
    }
}
