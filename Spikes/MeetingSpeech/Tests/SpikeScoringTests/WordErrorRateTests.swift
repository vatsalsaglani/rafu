import Testing
@testable import SpikeScoring

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test("identical hypothesis gives 0%")
    func identical() {
        let result = WordErrorRate.score(
            reference: "We should ship the search fix before the review.",
            hypothesis: "we should ship the search fix before the review"
        )
        #expect(result.errorRate == 0.0)
        #expect(result.substitutions == 0)
        #expect(result.deletions == 0)
        #expect(result.insertions == 0)
    }

    @Test("one deleted word in ten gives 10%")
    func oneDeletionInTen() {
        let reference = "one two three four five six seven eight nine ten"
        let hypothesis = "one two three four five six seven eight ten"
        let result = WordErrorRate.score(reference: reference, hypothesis: hypothesis)
        #expect(result.referenceWordCount == 10)
        #expect(result.deletions == 1)
        #expect(result.substitutions == 0)
        #expect(result.insertions == 0)
        #expect(abs(result.errorRate - 0.1) < 0.0001)
    }

    @Test("one substituted word in ten gives 10%")
    func oneSubstitutionInTen() {
        let words = "one two three four five six seven eight nine ten".split(separator: " ").map(String.init)
        var hypWords = words
        hypWords[8] = "ninety"
        let result = WordErrorRate.score(referenceWords: words, hypothesisWords: hypWords)
        #expect(result.substitutions == 1)
        #expect(result.deletions == 0)
        #expect(result.insertions == 0)
        #expect(abs(result.errorRate - 0.1) < 0.0001)
    }

    @Test("one inserted word gives extra error against ten reference words")
    func oneInsertion() {
        let reference = "one two three four five six seven eight nine ten".split(separator: " ").map(String.init)
        var hypothesis = reference
        hypothesis.insert("extra", at: 5)
        let result = WordErrorRate.score(referenceWords: reference, hypothesisWords: hypothesis)
        #expect(result.insertions == 1)
        #expect(result.deletions == 0)
        #expect(result.substitutions == 0)
        #expect(abs(result.errorRate - 0.1) < 0.0001)
    }

    @Test("empty reference and empty hypothesis gives 0%")
    func bothEmpty() {
        let result = WordErrorRate.score(reference: "", hypothesis: "")
        #expect(result.errorRate == 0.0)
    }

    @Test("empty hypothesis against a non-empty reference counts every reference word as a deletion")
    func emptyHypothesis() {
        // Regression: a reference turn with no assigned hypothesis words
        // (the usual case when `spike-score pipeline` finds no words for a
        // speaker in a given time window) must score as all-deletions, not
        // crash. `1...m` with `m == 0` is an invalid range.
        let result = WordErrorRate.score(reference: "one two three", hypothesis: "")
        #expect(result.referenceWordCount == 3)
        #expect(result.deletions == 3)
        #expect(result.substitutions == 0)
        #expect(result.insertions == 0)
        #expect(abs(result.errorRate - 1.0) < 0.0001)
    }

    @Test("punctuation and case are ignored")
    func punctuationIgnored() {
        let result = WordErrorRate.score(
            reference: "Ship it, Thursday!",
            hypothesis: "ship it thursday"
        )
        #expect(result.errorRate == 0.0)
    }

    @Test("normalize keeps internal apostrophes")
    func apostrophes() {
        let words = WordErrorRate.normalize("We don't ship on Thursday.")
        #expect(words == ["we", "don't", "ship", "on", "thursday"])
    }
}
