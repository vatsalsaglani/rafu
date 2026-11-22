import Testing
@testable import SpikeScoring

@Suite("RTTM and STM")
struct FormatTests {
    @Test("RTTM round-trips a list of segments")
    func rttmRoundTrip() {
        let segments = [
            DiarSegment(speaker: "A", start: 0, end: 1.5),
            DiarSegment(speaker: "B", start: 1.5, end: 3.2),
        ]
        let text = RTTM.write(segments, file: "S3")
        let parsed = RTTM.parse(text)
        #expect(parsed.count == 2)
        #expect(abs(parsed[0].start - 0) < 0.001)
        #expect(abs(parsed[0].end - 1.5) < 0.001)
        #expect(parsed[0].speaker == "A")
        #expect(abs(parsed[1].end - 3.2) < 0.001)
        #expect(parsed[1].speaker == "B")
    }

    @Test("RTTM ignores blank lines and non-SPEAKER lines")
    func rttmIgnoresNoise() {
        let text = "\nSPEAKER S3 1 0.000 1.000 <NA> <NA> A <NA> <NA>\n; a comment\n"
        let parsed = RTTM.parse(text)
        #expect(parsed.count == 1)
    }

    @Test("STM round-trips speaker, times and text")
    func stmRoundTrip() {
        let entries = [
            STMEntry(speaker: "A", start: 0, end: 1.2, text: "we should ship the fix"),
            STMEntry(speaker: "B", start: 1.3, end: 2.0, text: "yes agreed"),
        ]
        let text = STM.write(entries, file: "S3")
        let parsed = STM.parse(text)
        #expect(parsed.count == 2)
        #expect(parsed[0].speaker == "A")
        #expect(parsed[0].text == "we should ship the fix")
        #expect(parsed[1].text == "yes agreed")
    }

    @Test("der with the reference as the hypothesis gives 0.00 after an RTTM round trip")
    func derThroughRTTM() {
        let reference = [
            DiarSegment(speaker: "A", start: 0, end: 2),
            DiarSegment(speaker: "B", start: 2, end: 4),
        ]
        let roundTripped = RTTM.parse(RTTM.write(reference))
        let result = DiarizationScorer.score(reference: reference, hypothesis: roundTripped)
        #expect(result.der == 0.0)
    }
}
