import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting talk time")
struct MeetingSpeakerStatsTests {
    private func turn(
        _ number: Int, _ speaker: MeetingSpeakerLabel, speech: TimeInterval?,
        length: TimeInterval = 10, isEcho: Bool = false
    ) -> MeetingTurn {
        let start = Double(number) * 20
        return MeetingTurn(
            id: MeetingTurnID(number), track: speaker == .me ? .me : .them, speaker: speaker,
            start: start, end: start + length, text: "synthetic words", isEcho: isEcho,
            speechSeconds: speech)
    }

    @Test("Shown shares sum to 1; echo turns are not counted")
    func sharesAndEcho() {
        let stats = MeetingSpeakerStatsRule.stats(for: [
            turn(1, .speaker(1), speech: 6),
            turn(2, .me, speech: 2),
            turn(3, .me, speech: 30, isEcho: true),
            turn(4, .speaker(2), speech: 8),
        ])
        #expect(stats.speakers.map(\.speaker) == [.speaker(1), .me, .speaker(2)])
        #expect(stats.speakers.map(\.speechSeconds) == [6, 2, 8])
        #expect(stats.speakers.map(\.share) == [0.375, 0.125, 0.5])
        #expect(stats.speakers.map(\.turnCount) == [1, 1, 1])
        #expect(stats.speakers.allSatisfy { $0.isShown })
        #expect(stats.totalSpeechSeconds == 16)
        #expect(stats.echoTurnCount == 1)
        #expect(!stats.isEstimated)
        #expect(stats.speakers.reduce(0) { $0 + $1.share } == 1)
    }

    @Test("A speaker with 1 s of speech is not shown and has no share")
    func strayHidden() {
        let stats = MeetingSpeakerStatsRule.stats(for: [
            turn(1, .speaker(1), speech: 30),
            turn(2, .them, speech: 1),
            turn(3, .me, speech: 10),
        ])
        let stray = stats.speakers.first { $0.speaker == .them }
        #expect(stray?.isShown == false)
        #expect(stray?.share == 0)
        #expect(stray?.speechSeconds == 1)
        #expect(stats.speakers.filter(\.isShown).map(\.share) == [0.75, 0.25])
        #expect(stats.totalSpeechSeconds == 41)
        #expect(MeetingSpeakerStatsRule.minimumShownSpeechSeconds == 2)
    }

    @Test("When no speaker reaches 2 s, all are shown")
    func allShort() {
        let stats = MeetingSpeakerStatsRule.stats(for: [
            turn(1, .me, speech: 0.5), turn(2, .speaker(1), speech: 1.5),
        ])
        #expect(stats.speakers.allSatisfy { $0.isShown })
        #expect(stats.speakers.map(\.share) == [0.25, 0.75])
    }

    @Test("A stored turn with no speech seconds counts its length and marks the estimate")
    func estimated() {
        let stats = MeetingSpeakerStatsRule.stats(for: [
            turn(1, .me, speech: nil, length: 12), turn(2, .speaker(1), speech: 4),
        ])
        #expect(stats.isEstimated)
        #expect(stats.speakers.map(\.speechSeconds) == [12, 4])
        #expect(stats.speakers.map(\.share) == [0.75, 0.25])

        let echoOnly = MeetingSpeakerStatsRule.stats(for: [
            turn(1, .me, speech: nil, isEcho: true), turn(2, .speaker(1), speech: 4),
        ])
        #expect(!echoOnly.isEstimated)
    }

    @Test("No turns: no speakers")
    func empty() {
        let stats = MeetingSpeakerStatsRule.stats(for: [])
        #expect(stats.speakers.isEmpty && stats.totalSpeechSeconds == 0)
        #expect(stats.echoTurnCount == 0 && !stats.isEstimated)
    }

    @Test("A turn stored before speech seconds existed decodes with nil")
    func oldTurnDecodes() throws {
        let old = MeetingTurn(
            id: MeetingTurnID(3), track: .them, speaker: .speaker(2), start: 4, end: 6,
            text: "synthetic words")
        // A turn with no speech seconds encodes as before: no such key.
        let encoded = try JSONEncoder().encode(old)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("speechSeconds"))
        let decodedOld = try JSONDecoder().decode(MeetingTurn.self, from: encoded)
        #expect(decodedOld == old && decodedOld.speechSeconds == nil)

        var withSpeech = old
        withSpeech.speechSeconds = 1.5
        let roundTrip = try JSONDecoder().decode(
            MeetingTurn.self, from: JSONEncoder().encode(withSpeech))
        #expect(roundTrip.speechSeconds == 1.5)
    }
}
