import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting processing rules")
struct MeetingProcessingRulesTests {
    // MARK: Engine plan

    @Test("The preferred text engine is used when it is ready")
    func preferredReady() {
        let plan = MeetingProcessingPlan.make(
            preferences: MeetingSpeechPreferences(textEngine: .nemotronEnglish),
            textAvailability: [.nemotronEnglish: .ready, .appleSpeech: .ready],
            speakerAvailability: [.nemotron3: .ready])
        #expect(plan.textEngine == .nemotronEnglish)
        #expect(plan.fallbackTextEngine == .appleSpeech)
        #expect(plan.speakerEngine == .nemotron3)
    }

    @Test("A preferred engine that is not ready gives Apple speech, with no fall-back")
    func preferredNotReady() {
        let plan = MeetingProcessingPlan.make(
            preferences: MeetingSpeechPreferences(textEngine: .nemotronEnglish),
            textAvailability: [
                .nemotronEnglish: .needsModel([.nemotronEnglish1120]), .appleSpeech: .ready,
            ],
            speakerAvailability: [:])
        #expect(plan.textEngine == .appleSpeech)
        #expect(plan.fallbackTextEngine == nil)
        #expect(plan.speakerEngine == nil)
    }

    @Test("WhisperKit preferred and ready makes the final text")
    func whisperKitPreferred() {
        let plan = MeetingProcessingPlan.make(
            preferences: MeetingSpeechPreferences(
                textEngine: .whisperKit, speakerEngine: .speakerKit),
            textAvailability: [.whisperKit: .ready, .appleSpeech: .ready],
            speakerAvailability: [.nemotron3: .ready, .speakerKit: .unavailable(reason: "x")])
        #expect(plan.textEngine == .whisperKit)
        #expect(plan.speakerEngine == .nemotron3)
    }

    @Test("An override replaces the preferred engine")
    func overrideEngine() {
        let plan = MeetingProcessingPlan.make(
            preferences: MeetingSpeechPreferences(textEngine: .nemotronEnglish),
            override: .whisperKit,
            textAvailability: [.nemotronEnglish: .ready, .whisperKit: .ready],
            speakerAvailability: [:])
        #expect(plan.textEngine == .whisperKit)
    }

    @Test("The engine use names the engine and model of the transcripts")
    func engineUse() {
        let them = MeetingTrackTranscript(
            track: .them, words: [], engine: .nemotronEnglish, model: .nemotronEnglish1120,
            modelRevision: "r1")
        let use = MeetingProcessingPlan.engineUse(
            me: nil, them: them, textEngine: .appleSpeech, speakerEngine: .speakerKit)
        #expect(use.textEngine == .nemotronEnglish)
        #expect(use.textModel == .nemotronEnglish1120)
        #expect(use.textModelRevision == "r1")
        #expect(use.speakerEngine == .speakerKit)
        #expect(use.speakerModel == .speakerKit)
        let empty = MeetingProcessingPlan.engineUse(
            me: nil, them: nil, textEngine: .appleSpeech, speakerEngine: nil)
        #expect(empty.textEngine == .appleSpeech)
        #expect(empty.speakerEngine == nil)
    }

    // MARK: Assembly

    private func words(_ text: String, from start: TimeInterval) -> [MeetingWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * 0.4
            return MeetingWord(text: String(word), start: begin, end: begin + 0.3)
        }
    }

    @Test("Two tracks become turns; echo is marked only with speakers output")
    func assembly() {
        let them = MeetingTrackTranscript(
            track: .them, words: words("we ship the beta tomorrow morning", from: 1),
            engine: .appleSpeech)
        let me = MeetingTrackTranscript(
            track: .me, words: words("we ship the beta tomorrow morning", from: 1.2),
            engine: .appleSpeech)
        let headphones = MeetingTranscriptAssembly.assemble(
            me: me, them: them, segments: [], outputWasSpeakers: false)
        #expect(headphones.turns.count == 2)
        #expect(Set(headphones.turns.map(\.track)) == [.me, .them])
        #expect(headphones.turns.allSatisfy { !$0.isEcho })
        #expect(headphones.turns.first { $0.track == .them }?.speaker == .them)

        let speakers = MeetingTranscriptAssembly.assemble(
            me: me, them: them, segments: [], outputWasSpeakers: true)
        #expect(speakers.echoCount == 1)
        #expect(speakers.turns.first { $0.track == .me }?.isEcho == true)
        #expect(speakers.turns.map(\.id) == headphones.turns.map(\.id))
        #expect(speakers.turns.allSatisfy { $0.speechSeconds != nil })
    }

    @Test("Echo words then real words in one Me stream give an echo turn and a real turn")
    func assemblyMixed() {
        let them = MeetingTrackTranscript(
            track: .them, words: words("we ship the beta tomorrow morning", from: 1),
            engine: .appleSpeech)
        let me = MeetingTrackTranscript(
            track: .me,
            words: words("we ship the beta tomorrow morning", from: 1.2)
                + words("i agree with that plan today", from: 3.6),
            engine: .appleSpeech)
        let result = MeetingTranscriptAssembly.assemble(
            me: me, them: them, segments: [], outputWasSpeakers: true)
        let meTurns = result.turns.filter { $0.track == .me }
        #expect(meTurns.map(\.isEcho) == [true, false])
        #expect(
            meTurns.map(\.text) == [
                "we ship the beta tomorrow morning", "i agree with that plan today",
            ])
        #expect(result.echoCount == 1)
    }

    @Test("No words in both tracks gives zero turns")
    func assemblyEmpty() {
        let result = MeetingTranscriptAssembly.assemble(
            me: nil, them: nil, segments: [], outputWasSpeakers: true)
        #expect(result.turns.isEmpty)
    }

    // MARK: Levels and warnings

    @Test("The level scale maps -60...0 dBFS to 0...1")
    func levelScale() {
        #expect(MeetingLevelScale.unit(fromDBFS: -160) == 0)
        #expect(MeetingLevelScale.unit(fromDBFS: -60) == 0)
        #expect(MeetingLevelScale.unit(fromDBFS: -30) == 0.5)
        #expect(MeetingLevelScale.unit(fromDBFS: 0) == 1)
        #expect(MeetingLevelScale.unit(fromDBFS: 6) == 1)
        #expect(MeetingLevelScale.unit(fromDBFS: .nan) == 0)
    }

    @Test("Problems set warnings; sound on that track clears them")
    func warningRules() {
        var rules = MeetingLiveWarningRules()
        rules.apply(problem: .noBuffers, lastPeaks: [.them: -160])
        rules.apply(problem: .missingMicrophonePermission, lastPeaks: [.me: -160])
        rules.apply(problem: .deviceLost)
        #expect(rules.warnings == [.themNoSound, .meSilent])

        rules.apply(meDBFS: -55, themDBFS: -70)
        #expect(rules.warnings == [.themNoSound, .meSilent])
        rules.apply(meDBFS: -160, themDBFS: -20)
        #expect(rules.warnings == [.meSilent])
        rules.apply(meDBFS: -10, themDBFS: -20)
        #expect(rules.warnings.isEmpty)
    }

    @Test("A stale peak (no new block) does not clear a warning")
    func stalePeak() {
        var rules = MeetingLiveWarningRules()
        rules.apply(problem: .noBuffers, lastPeaks: [.them: -18])
        rules.apply(meDBFS: -160, themDBFS: -18)
        #expect(rules.warnings == [.themNoSound])
        rules.apply(meDBFS: -160, themDBFS: -17.5)
        #expect(rules.warnings.isEmpty)
    }

    @Test("Headset and speakers warnings stay for the recording")
    func factWarnings() {
        var rules = MeetingLiveWarningRules()
        rules.apply(usesHeadsetMicrophone: true, outputWasSpeakers: true)
        rules.apply(meDBFS: 0, themDBFS: 0)
        #expect(rules.warnings == [.headsetMicrophone, .speakersEcho])
    }

    // MARK: Title and interrupted rule

    @Test("The default title names the date and the time")
    func defaultTitle() throws {
        let zone = try #require(TimeZone(identifier: "Europe/London"))
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 23
        parts.hour = 10
        parts.minute = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try #require(calendar.date(from: parts))
        #expect(MeetingDefaultTitle.text(for: date, timeZone: zone) == "Meeting 23 Nov 2026, 10:05")
    }

    @Test("Interrupted: recording, paused or processing, not live, no job")
    func interrupted() {
        func record(_ state: MeetingState) -> MeetingSummaryRecord {
            MeetingSummaryRecord(
                id: MeetingID(), title: "t", startDate: Date(), duration: 0, state: state)
        }
        let recording = record(.recording)
        let paused = record(.paused)
        let processing = record(.processing)
        let ready = record(.ready)
        let failed = record(.failed(reasonCode: "x"))
        let live = record(.recording)
        let queued = record(.processing)
        let result = MeetingInterruptedRule.interrupted(
            [recording, paused, processing, ready, failed, live, queued],
            liveMeeting: live.id, activeJobs: [queued.id])
        #expect(result.map(\.id) == [recording.id, paused.id, processing.id])
    }
}
