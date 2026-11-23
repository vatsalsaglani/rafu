import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting contracts: coding")
struct MeetingContractCodingTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("Each stored type survives a JSON round trip")
    func storedTypesRoundTrip() throws {
        let meeting = MeetingID()
        #expect(try roundTrip(meeting) == meeting)
        #expect(try roundTrip(MeetingTurnID(12)) == MeetingTurnID(12))
        for track in MeetingTrack.allCases { #expect(try roundTrip(track) == track) }
        for label in [MeetingSpeakerLabel.me, .them, .speaker(0), .speaker(3)] {
            #expect(try roundTrip(label) == label)
        }
        for state in [
            MeetingState.recording, .paused, .processing, .ready,
            .failed(reasonCode: "helper-crashed"),
        ] {
            #expect(try roundTrip(state) == state)
        }
        let summary = MeetingSummaryRecord(
            id: meeting, title: "Weekly sync", startDate: Date(timeIntervalSince1970: 1_000),
            duration: 1_800, state: .ready,
            sizes: MeetingSizes(audioBytes: 10, transcriptBytes: 2),
            engines: MeetingEngineUse(
                textEngine: .nemotronEnglish, textModel: .nemotronEnglish1120,
                textModelRevision: "0651794", speakerEngine: .nemotron3,
                speakerModel: .nemotron3Fast32, speakerModelRevision: "25a90f9"),
            version: 4)
        #expect(try roundTrip(summary) == summary)
        let word = MeetingWord(text: "hello", start: 1.25, end: 1.5)
        #expect(try roundTrip(word) == word)
        let turn = MeetingTurn(
            id: MeetingTurnID(3), track: .them, speaker: .speaker(2), start: 4, end: 6,
            text: "synthetic words", isEcho: true)
        #expect(try roundTrip(turn) == turn)
        let segment = MeetingSpeakerSegment(speaker: 1, start: 0, end: 2.5)
        #expect(try roundTrip(segment) == segment)
        let transcript = MeetingTrackTranscript(
            track: .me, words: [word], engine: .appleSpeech, model: nil, modelRevision: nil)
        #expect(try roundTrip(transcript) == transcript)
        let preferences = MeetingSpeechPreferences(
            textEngine: .whisperKit, speakerEngine: .speakerKit)
        #expect(try roundTrip(preferences) == preferences)
        for choice in [MeetingMicrophoneChoice.automatic, .systemDefault, .device(uid: "BuiltIn")] {
            #expect(try roundTrip(choice) == choice)
        }
        for retention in MeetingAudioRetention.allCases {
            #expect(try roundTrip(retention) == retention)
        }
        for access in MeetingAgentAccess.allCases { #expect(try roundTrip(access) == access) }
        let citation = MeetingCitation(turn: MeetingTurnID(7), quote: "synthetic")
        #expect(try roundTrip(citation) == citation)
        let event = MeetingDiagnosticEvent.devices(
            input: MeetingAudioDeviceFacts(
                name: "Built-in Microphone", uid: "BuiltInMicrophoneDevice",
                transportType: 0x626C_746E, nominalSampleRate: 48_000, channelCount: 1),
            output: nil)
        #expect(try roundTrip(event) == event)
    }

    @Test("A turn id has the text form t<number>")
    func turnIDTextForm() throws {
        #expect(MeetingTurnID(12).text == "t12")
        #expect(MeetingTurnID(text: "t0") == MeetingTurnID(0))
        #expect(MeetingTurnID(text: "t42") == MeetingTurnID(42))
        for bad in ["", "t", "12", "T12", "t-1", "t1a", "t 1", "t١"] {
            #expect(MeetingTurnID(text: bad) == nil, "\(bad)")
        }
        let encoded = try JSONEncoder().encode(MeetingTurnID(5))
        #expect(String(decoding: encoded, as: UTF8.self) == #""t5""#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MeetingTurnID.self, from: Data(#""x5""#.utf8))
        }
    }

    @Test("Speaker labels store as me, them and speaker-<n>")
    func speakerLabelStorage() {
        #expect(MeetingSpeakerLabel.speaker(2).storageKey == "speaker-2")
        #expect(MeetingSpeakerLabel(storageKey: "speaker-2") == .speaker(2))
        #expect(MeetingSpeakerLabel(storageKey: "speaker-") == nil)
        #expect(MeetingSpeakerLabel(storageKey: "priya") == nil)
    }

    @Test("Engine ids keep their stored raw values")
    func engineRawValues() {
        #expect(
            MeetingTextEngineID.allCases.map(\.rawValue) == [
                "nemotron-en", "apple-speech", "whisperkit",
            ])
        #expect(MeetingSpeakerEngineID.allCases.map(\.rawValue) == ["nemotron-3", "speakerkit"])
        #expect(
            MeetingModelID.allCases.map(\.rawValue) == [
                "nemotron-en-1120ms", "whisperkit-large-v3-626mb", "nemotron-3-fast32",
                "speakerkit-pyannote",
            ])
    }

    @Test("Preferences default to Nemotron, Nemotron 3, keep audio, agents off")
    func preferenceDefaults() throws {
        // A path suite name keeps the plist in a temporary folder, never
        // in ~/Library/Preferences (the RafuAppTests `TestDefaultsSuite` rule).
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "rafu-meetings-prefs-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appending(path: "prefs").path
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let reader = UserDefaultsMeetingPreferences(suiteName: suite)
        #expect(
            reader.speechPreferences()
                == MeetingSpeechPreferences(textEngine: .whisperKit, speakerEngine: .nemotron3)
        )
        #expect(reader.microphoneChoice() == .automatic)
        #expect(reader.audioRetention() == .untilDeleted)
        #expect(reader.agentAccess() == .off)

        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("nemotron-en", forKey: MeetingPreferenceKeys.textEngine)
        defaults.set("bogus", forKey: MeetingPreferenceKeys.speakerEngine)
        defaults.set("device:AppleUSBAudioEngine:1", forKey: MeetingPreferenceKeys.microphone)
        defaults.set("days7", forKey: MeetingPreferenceKeys.audioRetention)
        defaults.set("on", forKey: MeetingPreferenceKeys.agentAccess)
        #expect(reader.speechPreferences().textEngine == .nemotronEnglish)
        #expect(reader.speechPreferences().speakerEngine == .nemotron3)
        #expect(reader.microphoneChoice() == .device(uid: "AppleUSBAudioEngine:1"))
        #expect(reader.audioRetention() == .days7)
        #expect(reader.agentAccess() == .on)

        #expect(MeetingPreferenceKeys.textEngine == "meetings.textEngine")
        #expect(MeetingPreferenceKeys.speakerEngine == "meetings.speakerEngine")
        #expect(MeetingPreferenceKeys.microphone == "meetings.microphone")
        #expect(MeetingPreferenceKeys.audioRetention == "meetings.audioRetention")
        #expect(MeetingPreferenceKeys.agentAccess == "meetings.agentAccess")
        #expect(MeetingMicrophoneChoice.resolve(stored: "device:") == .automatic)
    }

    @Test("An audio chunk checks its byte count against its frame count")
    func audioChunkShape() {
        let chunk = MeetingAudioChunk(
            track: .them, samples: Data(count: 320), startTime: 2, frameCount: 160)
        #expect(chunk.isWellFormed)
        #expect(chunk.duration == 0.01)
        let bad = MeetingAudioChunk(
            track: .me, samples: Data(count: 3), startTime: 0, frameCount: 2)
        #expect(!bad.isWellFormed)
        #expect(MeetingAudioFormat.sampleRate == 16_000)
        #expect(MeetingAudioFormat.channelCount == 1)
    }

    @Test("Availability is decided by the macOS version")
    func platformAvailability() {
        if #available(macOS 26, *) {
            #expect(MeetingsAvailability.current == .available)
            #expect(MeetingsAvailability.current.unavailableReason == nil)
        } else {
            #expect(MeetingsAvailability.current == .needsMacOS26)
        }
        #expect(MeetingsAvailability.needsMacOS26.unavailableReason == "Meetings needs macOS 26")
    }
}
