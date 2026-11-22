import Foundation
import RafuCore
import Testing

@Suite("Meetings speech worker word and speaker logic")
struct MeetingWorkerTextAndSpeakerLogicTests {
    private static func token(_ text: String, _ time: Double) -> MeetingWorkerToken {
        MeetingWorkerToken(piece: text, time: time)
    }

    // MARK: Word grouper (ported from the speech spike's tests)

    @Test("Sub-word tokens group into words at each word-start mark")
    func groups() {
        let tokens = [
            Self.token("▁we", 0.0), Self.token("▁should", 0.2), Self.token("▁ship", 0.5),
            Self.token("pers", 0.6), Self.token("▁it", 0.9),
        ]
        let words = MeetingTokenWordGrouper.words(from: tokens, fallbackEnd: 1.2)
        #expect(words.map(\.text) == ["we", "should", "shippers", "it"])
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.2)
        #expect(words[2].start == 0.5)
        #expect(words[2].end == 0.9)
        #expect(words[3].end == 1.2)
    }

    @Test("An empty token list gives no words; a leading continuation starts a word")
    func edges() {
        #expect(MeetingTokenWordGrouper.words(from: [], fallbackEnd: 1).isEmpty)
        let words = MeetingTokenWordGrouper.words(
            from: [Self.token("ab", 0), Self.token("▁next", 0.3)], fallbackEnd: 0.6)
        #expect(words.map(\.text) == ["ab", "next"])
        #expect(words[0].end == 0.3)
        let spaced = MeetingTokenWordGrouper.words(
            from: [Self.token(" Hi", 0), Self.token("▁", 0.2), Self.token(" there", 0.4)],
            fallbackEnd: 1)
        #expect(spaced.map(\.text) == ["Hi", "there"])
    }

    // MARK: Live accumulator

    @Test("A word becomes final when the next word starts; the tail is volatile")
    func liveAccumulator() {
        var accumulator = MeetingLiveWordAccumulator()
        var tokens = [Self.token("▁we", 0.0), Self.token("▁sh", 0.2)]
        var update = accumulator.update(allTokens: tokens)
        #expect(update.finalWords.map(\.text) == ["we"])
        #expect(update.finalWords.first?.end == 0.2)
        #expect(update.volatileText == "sh")
        #expect(update.volatileStart == 0.2)

        tokens += [Self.token("ip", 0.3)]
        update = accumulator.update(allTokens: tokens)
        #expect(update.finalWords.isEmpty)
        #expect(update.volatileText == "ship")

        tokens += [Self.token("▁it", 0.6), Self.token("▁now", 0.9)]
        update = accumulator.update(allTokens: tokens)
        #expect(update.finalWords.map(\.text) == ["ship", "it"])
        #expect(update.volatileText == "now")
        #expect(accumulator.update(allTokens: tokens).finalWords.isEmpty)

        let last = accumulator.finish(allTokens: tokens, fallbackEnd: 1.4)
        #expect(last.map(\.text) == ["now"])
        #expect(last.first?.end == 1.4)
        #expect(accumulator.finish(allTokens: tokens, fallbackEnd: 2).isEmpty)
    }

    @Test("Each token becomes part of exactly one final word")
    func accumulatorLosesNothing() {
        let pieces = ["▁the", "▁search", "▁fix", "▁sh", "ipped", "▁on", "▁thurs", "day", "▁."]
        let tokens = pieces.enumerated().map { Self.token($0.element, Double($0.offset) * 0.3) }
        for step in 1...4 {
            var accumulator = MeetingLiveWordAccumulator()
            var words: [MeetingWord] = []
            var count = 0
            while count < tokens.count {
                count = min(tokens.count, count + step)
                words += accumulator.update(allTokens: Array(tokens[..<count])).finalWords
            }
            words += accumulator.finish(allTokens: tokens, fallbackEnd: 3)
            #expect(
                words.map(\.text)
                    == MeetingTokenWordGrouper.words(from: tokens, fallbackEnd: 3).map(\.text))
        }
    }

    // MARK: Clock map

    @Test("Fed audio maps to the meeting clock across a pause")
    func clockMap() {
        var map = MeetingLiveClockMap()
        map.record(startTime: 12.65, sampleCount: 16_000)
        map.record(startTime: 13.65, sampleCount: 16_000)
        #expect(map.anchorCount == 1)
        // A pause: the next frame starts at 30 s on the meeting clock.
        map.record(startTime: 30, sampleCount: 8_000)
        #expect(map.anchorCount == 2)
        #expect(abs(map.meetingTime(forFedSeconds: 0) - 12.65) < 1e-9)
        #expect(abs(map.meetingTime(forFedSeconds: 1.5) - 14.15) < 1e-9)
        #expect(abs(map.meetingTime(forFedSeconds: 2.25) - 30.25) < 1e-9)
        let words = map.mapped([MeetingWord(text: "x", start: 1.0, end: 2.1)])
        #expect(abs(words[0].start - 13.65) < 1e-9)
        #expect(abs(words[0].end - 30.1) < 1e-9)
    }

    @Test("Percentiles use the nearest rank")
    func percentiles() {
        #expect(MeetingWorkerPercentile.value([], fraction: 0.95) == nil)
        let values = (1...100).map(Double.init)
        #expect(MeetingWorkerPercentile.value(values, fraction: 0.95) == 96)
        #expect(MeetingWorkerPercentile.value(values, fraction: 0.5) == 51)
        #expect(MeetingWorkerPercentile.value([7], fraction: 0.95) == 7)
    }

    // MARK: Streaming speaker segments

    /// FluidAudio's `Nemotron3Diarizer.segments` on the whole list (the
    /// reference the streaming form must match).
    private static func referenceSegments(
        _ probabilities: [Float], frames: Int, slots: Int, threshold: Float, minimum: Double
    ) -> [MeetingSpeakerSegment] {
        var result: [MeetingSpeakerSegment] = []
        for slot in 0..<slots {
            var start: Int?
            for frame in 0...frames {
                let active = frame < frames && probabilities[frame * slots + slot] > threshold
                if active, start == nil {
                    start = frame
                } else if !active, let begin = start {
                    let duration = Double(frame - begin) * 0.01
                    if duration >= minimum {
                        result.append(
                            MeetingSpeakerSegment(
                                speaker: slot + 1, start: Double(begin) * 0.01,
                                end: Double(frame) * 0.01))
                    }
                    start = nil
                }
            }
        }
        return result
    }

    private static func ordered(_ segments: [MeetingSpeakerSegment]) -> [MeetingSpeakerSegment] {
        segments.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    @Test("Streaming segments match the whole-list segments for any chunking")
    func streamingSegmentsMatch() {
        var generator = SystemRandomNumberGenerator()
        let slots = 8
        let frames = 3_000
        var probabilities = [Float](repeating: 0, count: frames * slots)
        var active = [Bool](repeating: false, count: slots)
        for frame in 0..<frames {
            for slot in 0..<slots {
                if Int.random(in: 0..<40, using: &generator) == 0 { active[slot].toggle() }
                probabilities[frame * slots + slot] =
                    active[slot] ? Float.random(in: 0.5...1) : Float.random(in: 0...0.5)
            }
        }
        // Exactly the threshold is not active (strictly greater than).
        probabilities[0] = 0.5
        for minimum in [0.0, 0.2] {
            let reference = Self.ordered(
                Self.referenceSegments(
                    probabilities, frames: frames, slots: slots, threshold: 0.5, minimum: minimum))
            for chunk in [1, 7, 80, 3_000] {
                var segmenter = MeetingStreamingSpeakerSegmenter(
                    speakerSlots: slots, threshold: 0.5, frameSeconds: 0.01,
                    minimumDurationSeconds: minimum)
                var offset = 0
                while offset < frames {
                    let count = min(chunk, frames - offset)
                    segmenter.append(
                        probabilities: Array(
                            probabilities[(offset * slots)..<((offset + count) * slots)]),
                        frameCount: count)
                    offset += count
                }
                #expect(segmenter.frameCount == frames)
                let streamed = segmenter.finish()
                #expect(Self.ordered(streamed) == reference)
                #expect(streamed.map(\.start) == streamed.map(\.start).sorted())
            }
        }
    }
}
