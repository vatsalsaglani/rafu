import Testing
@testable import SpikeScoring

@Suite("DiarizationScorer")
struct DiarizationErrorRateTests {
    @Test("hypothesis equal to the reference gives 0%")
    func identical() {
        let segments = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2, end: 4),
        ]
        let result = DiarizationScorer.score(reference: segments, hypothesis: segments)
        #expect(result.der == 0.0)
        #expect(result.missSeconds == 0)
        #expect(result.falseAlarmSeconds == 0)
        #expect(result.confusionSeconds == 0)
    }

    @Test("two swapped speaker labels give 0% after mapping")
    func swappedLabels() {
        let reference = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2, end: 4),
        ]
        let hypothesis = [
            DiarSegment(speaker: "X", start: 0, end: 2),
            DiarSegment(speaker: "Y", start: 2, end: 4),
        ]
        let result = DiarizationScorer.score(reference: reference, hypothesis: hypothesis)
        #expect(result.der == 0.0)
        #expect(result.speakerMapping["X"] == "A")
        #expect(result.speakerMapping["Y"] == "B")
    }

    @Test("a missed segment counts as miss, not confusion")
    func missed() {
        let reference = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2, end: 4),
        ]
        let hypothesis = [
            DiarSegment(speaker: "A", start: 0, end: 2),
        ]
        let result = DiarizationScorer.score(reference: reference, hypothesis: hypothesis)
        #expect(abs(result.totalReferenceSpeakerSeconds - 4) < 0.02)
        #expect(abs(result.missSeconds - 2) < 0.02)
        #expect(result.falseAlarmSeconds == 0)
        #expect(abs(result.der - 0.5) < 0.02)
    }

    @Test("an extra hypothesis segment with no reference counts as false alarm")
    func falseAlarm() {
        let reference = [
            DiarSegment(speaker: "A", start: 0, end: 2),
        ]
        let hypothesis = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2, end: 4),
        ]
        let result = DiarizationScorer.score(reference: reference, hypothesis: hypothesis)
        #expect(abs(result.totalReferenceSpeakerSeconds - 2) < 0.02)
        #expect(result.missSeconds == 0)
        #expect(abs(result.falseAlarmSeconds - 2) < 0.02)
        #expect(abs(result.der - 1.0) < 0.02)
    }

    @Test("a collar excludes frames near a reference boundary")
    func collarExcludesBoundary() {
        let reference = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2.1, end: 4),
        ]
        // Hypothesis slips the boundary by 0.1 s; collar 0.25 should absorb it.
        let hypothesis = [
            DiarSegment(speaker: "A", start: 0, end: 2.1),
            DiarSegment(speaker: "B", start: 2.1, end: 4),
        ]
        let strict = DiarizationScorer.score(reference: reference, hypothesis: hypothesis, collar: 0.0)
        let collared = DiarizationScorer.score(reference: reference, hypothesis: hypothesis, collar: 0.25)
        #expect(strict.der > 0.0)
        #expect(collared.der < strict.der)
    }

    @Test("overlapping reference speech is counted twice in reference time")
    func overlapIncluded() {
        let reference = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 1, end: 3),
        ]
        let result = DiarizationScorer.score(reference: reference, hypothesis: reference)
        #expect(abs(result.totalReferenceSpeakerSeconds - 4) < 0.02)
        #expect(result.der == 0.0)
    }

    @Test("empty reference and empty hypothesis gives 0%")
    func bothEmpty() {
        let result = DiarizationScorer.score(reference: [], hypothesis: [])
        #expect(result.der == 0.0)
    }
}
