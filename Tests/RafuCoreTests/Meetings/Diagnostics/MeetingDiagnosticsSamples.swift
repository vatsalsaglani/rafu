import Foundation

@testable import RafuCore

/// One sample of each `MeetingDiagnosticEvent` case, keyed by case name.
/// `MeetingDiagnosticsEncoderTests` checks that each case has a sample and a
/// golden line; the marker-word test feeds all of them through the recorder.
enum MeetingDiagnosticsSamples {
    static let airPods = MeetingAudioDeviceFacts(
        name: "Test AirPods", uid: "AA-BB-CC:input", transportType: 0x626C_7565,
        nominalSampleRate: 24000, channelCount: 1)
    static let speakers = MeetingAudioDeviceFacts(
        name: "MacBook Speakers", uid: "BuiltInSpeakerDevice", transportType: 0x626C_746E,
        nominalSampleRate: 48000, channelCount: 2)

    /// Case name → a sample event, built from numbers, enums and the two
    /// devices above.
    static func all() -> [(name: String, event: MeetingDiagnosticEvent)] {
        [
            (
                "header",
                .header(
                    macOSVersion: "26.1.0", macOSBuild: "25B78", macModel: "Mac17,13",
                    rafuVersion: "0.1.0-dev", rafuBuild: "42", rafuVariant: "lightning",
                    timeZoneOffsetSeconds: 19800)
            ),
            ("permissions", .permissions(microphone: .granted, systemAudio: .denied)),
            ("devices", .devices(input: airPods, output: speakers)),
            (
                "microphoneChoice",
                .microphoneChoice(kind: .automatic, reason: .builtInOverCallHeadset)
            ),
            (
                "playingProcesses",
                .playingProcesses(bundleIDs: ["us.zoom.xos", "com.apple.Safari"])
            ),
            ("coreAudioCall", .coreAudioCall(.createProcessTap, status: -50)),
            (
                "tapFormat",
                .tapFormat(
                    MeetingTapFormat(
                        sampleRate: 48000, channelCount: 2, bitsPerChannel: 32,
                        isInterleaved: false))
            ),
            ("aggregateDeviceRate", .aggregateDeviceRate(nominalSampleRate: 24000)),
            ("sampleRateCorrected", .sampleRateCorrected(from: 48000, to: 24000)),
            ("firstBuffer", .firstBuffer(track: .them, frames: 480)),
            (
                "trackFlow",
                .trackFlow(
                    track: .me,
                    counters: MeetingTrackFlowCounters(
                        buffers: 100, frames: 48000, silentBuffers: 3, droppedBuffers: 1,
                        lateBuffers: 2, peakLevelDBFS: -6.25, meanLevelDBFS: -31.5,
                        converterErrors: 0))
            ),
            ("deviceChanged", .deviceChanged(track: .me, old: airPods, new: nil)),
            ("recordingPaused", .recordingPaused),
            ("recordingResumed", .recordingResumed),
            ("recordingStopped", .recordingStopped(recordedSeconds: 612.5)),
            ("journalSync", .journalSync(bytes: 1_048_576, ok: true)),
            ("journalRecovery", .journalRecovery(result: .partlyRecovered, recoveredSeconds: 42)),
            (
                "textEngineLoaded",
                .textEngineLoaded(
                    engine: .nemotronEnglish, model: .nemotronEnglish1120,
                    modelRevision: "0651794847e5", loadMilliseconds: 7400, isCold: true)
            ),
            (
                "firstLiveText",
                .firstLiveText(engine: .appleSpeech, track: .them, milliseconds: 4000)
            ),
            (
                "liveTextWindow",
                .liveTextWindow(
                    engine: .appleSpeech, track: .me, delayMedianMilliseconds: 2300,
                    delayP95Milliseconds: 3900, words: 87)
            ),
            (
                "liveSessionRestarted",
                .liveSessionRestarted(engine: .appleSpeech, track: .me, reason: .routeChange)
            ),
            (
                "finalTextDone",
                .finalTextDone(
                    engine: .whisperKit, track: .them, audioSeconds: 600, wallSeconds: 31.25)
            ),
            (
                "engineError",
                .engineError(engine: .text(.whisperKit), domain: "com.apple.coreml", code: 3)
            ),
            ("helperStarted", .helperStarted(mode: .liveText, engine: .speaker(.nemotron3))),
            (
                "helperExited",
                .helperExited(
                    mode: .finalText, exitCode: nil, signal: 9, wallSeconds: 12.5,
                    peakFootprintBytes: 805_306_368)
            ),
            ("helperRestarted", .helperRestarted(mode: .liveText, reason: .memoryPressure)),
            (
                "speakersDone",
                .speakersDone(
                    engine: .nemotron3, modelRevision: "25a90f97f254", audioSeconds: 1500,
                    wallSeconds: 40, speakerCount: 3, segmentCount: 118)
            ),
            (
                "modelDownloadStarted",
                .modelDownloadStarted(model: .whisperLargeV3, expectedBytes: 662_700_000)
            ),
            (
                "modelDownloadFinished",
                .modelDownloadFinished(
                    model: .speakerKit, bytes: 11_534_336, wallSeconds: 4.5,
                    checksum: .matched, install: .installed)
            ),
            ("libraryWrite", .libraryWrite(result: .conflict, code: nil)),
            ("libraryIndexRebuilt", .libraryIndexRebuilt(meetings: 12, wallMilliseconds: 85)),
            ("exportDone", .exportDone(kind: .diagnostics)),
            (
                "agentRun",
                .agentRun(
                    cli: .claudeCode, cliVersion: "2.1.0", exitCode: 0, wallSeconds: 18.75,
                    replyBytes: 2048, citations: 4, failedCitations: 1, outcome: .answered)
            ),
            (
                "userFacingError",
                .userFacingError(place: .capture, domain: "com.apple.coreaudio", code: -10863)
            ),
        ]
    }
}
