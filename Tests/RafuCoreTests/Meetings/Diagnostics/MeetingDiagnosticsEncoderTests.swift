import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting diagnostics: encoder")
struct MeetingDiagnosticsEncoderTests {
    /// 2023-11-14T22:13:20.250Z
    static let time = Date(timeIntervalSince1970: 1_700_000_000.25)

    /// The line of each event case, for `time` and a clock of 12.65.
    static let goldens: [String: String] = [
        "header":
            #"{"clock":12.65,"event":"header","macModel":"Mac17,13","macOSBuild":"25B78","macOSVersion":"26.1.0","rafuBuild":"42","rafuVariant":"lightning","rafuVersion":"0.1.0-dev","t":"2023-11-14T22:13:20.250Z","timeZoneOffsetSeconds":19800}"#,
        "permissions":
            #"{"clock":12.65,"event":"permissions","microphone":"granted","systemAudio":"denied","t":"2023-11-14T22:13:20.250Z"}"#,
        "devices":
            #"{"clock":12.65,"event":"devices","input.channels":1,"input.name":"Test AirPods","input.rate":24000.0,"input.transport":"blue","input.uid":"AA-BB-CC:input","output.channels":2,"output.name":"MacBook Speakers","output.rate":48000.0,"output.transport":"bltn","output.uid":"BuiltInSpeakerDevice","t":"2023-11-14T22:13:20.250Z"}"#,
        "microphoneChoice":
            #"{"clock":12.65,"event":"microphoneChoice","kind":"automatic","reason":"builtInOverCallHeadset","t":"2023-11-14T22:13:20.250Z"}"#,
        "playingProcesses":
            #"{"bundleIDs":["us.zoom.xos","com.apple.Safari"],"clock":12.65,"count":2,"event":"playingProcesses","t":"2023-11-14T22:13:20.250Z"}"#,
        "coreAudioCall":
            #"{"call":"createProcessTap","clock":12.65,"event":"coreAudioCall","status":-50,"t":"2023-11-14T22:13:20.250Z"}"#,
        "tapFormat":
            #"{"bits":32,"channels":2,"clock":12.65,"event":"tapFormat","interleaved":false,"sampleRate":48000.0,"t":"2023-11-14T22:13:20.250Z"}"#,
        "aggregateDeviceRate":
            #"{"clock":12.65,"event":"aggregateDeviceRate","nominalSampleRate":24000.0,"t":"2023-11-14T22:13:20.250Z"}"#,
        "sampleRateCorrected":
            #"{"clock":12.65,"event":"sampleRateCorrected","from":48000.0,"t":"2023-11-14T22:13:20.250Z","to":24000.0}"#,
        "microphoneFormat":
            #"{"bits":32,"channels":1,"clock":12.65,"event":"microphoneFormat","float32":true,"interleaved":true,"nominalSampleRate":48000.0,"sampleRate":48000.0,"t":"2023-11-14T22:13:20.250Z"}"#,
        "firstBuffer":
            #"{"clock":12.65,"event":"firstBuffer","frames":480,"t":"2023-11-14T22:13:20.250Z","track":"them"}"#,
        "trackFlow":
            #"{"buffers":100,"clock":12.65,"converterErrors":0,"droppedBuffers":1,"event":"trackFlow","frames":48000,"lateBuffers":2,"meanDBFS":-31.5,"peakDBFS":-6.25,"silentBuffers":3,"t":"2023-11-14T22:13:20.250Z","track":"me"}"#,
        "deviceChanged":
            #"{"clock":12.65,"event":"deviceChanged","new":"none","old.channels":1,"old.name":"Test AirPods","old.rate":24000.0,"old.transport":"blue","old.uid":"AA-BB-CC:input","t":"2023-11-14T22:13:20.250Z","track":"me"}"#,
        "recordingPaused":
            #"{"clock":12.65,"event":"recordingPaused","t":"2023-11-14T22:13:20.250Z"}"#,
        "recordingResumed":
            #"{"clock":12.65,"event":"recordingResumed","t":"2023-11-14T22:13:20.250Z"}"#,
        "recordingStopped":
            #"{"clock":12.65,"event":"recordingStopped","recordedSeconds":612.5,"t":"2023-11-14T22:13:20.250Z"}"#,
        "journalSync":
            #"{"bytes":1048576,"clock":12.65,"event":"journalSync","ok":true,"t":"2023-11-14T22:13:20.250Z"}"#,
        "journalRecovery":
            #"{"clock":12.65,"event":"journalRecovery","recoveredSeconds":42.0,"result":"partlyRecovered","t":"2023-11-14T22:13:20.250Z"}"#,
        "textEngineLoaded":
            #"{"clock":12.65,"cold":true,"engine":"nemotron-en","event":"textEngineLoaded","loadMilliseconds":7400,"model":"nemotron-en-1120ms","modelRevision":"0651794847e5","t":"2023-11-14T22:13:20.250Z"}"#,
        "firstLiveText":
            #"{"clock":12.65,"engine":"apple-speech","event":"firstLiveText","ms":4000,"t":"2023-11-14T22:13:20.250Z","track":"them"}"#,
        "liveTextWindow":
            #"{"clock":12.65,"delayMedianMs":2300,"delayP95Ms":3900,"engine":"apple-speech","event":"liveTextWindow","t":"2023-11-14T22:13:20.250Z","track":"me","words":87}"#,
        "liveSessionRestarted":
            #"{"clock":12.65,"engine":"apple-speech","event":"liveSessionRestarted","reason":"routeChange","t":"2023-11-14T22:13:20.250Z","track":"me"}"#,
        "finalTextDone":
            #"{"audioSeconds":600.0,"clock":12.65,"engine":"whisperkit","event":"finalTextDone","t":"2023-11-14T22:13:20.250Z","track":"them","wallSeconds":31.25}"#,
        "engineError":
            #"{"clock":12.65,"code":3,"domain":"com.apple.coreml","engine":"text:whisperkit","event":"engineError","t":"2023-11-14T22:13:20.250Z"}"#,
        "helperStarted":
            #"{"clock":12.65,"engine":"speaker:nemotron-3","event":"helperStarted","mode":"liveText","t":"2023-11-14T22:13:20.250Z"}"#,
        "helperExited":
            #"{"clock":12.65,"event":"helperExited","mode":"finalText","peakFootprintBytes":805306368,"signal":9,"t":"2023-11-14T22:13:20.250Z","wallSeconds":12.5}"#,
        "helperRestarted":
            #"{"clock":12.65,"event":"helperRestarted","mode":"liveText","reason":"memoryPressure","t":"2023-11-14T22:13:20.250Z"}"#,
        "speakersDone":
            #"{"audioSeconds":1500.0,"clock":12.65,"engine":"nemotron-3","event":"speakersDone","modelRevision":"25a90f97f254","segments":118,"speakers":3,"t":"2023-11-14T22:13:20.250Z","wallSeconds":40.0}"#,
        "modelDownloadStarted":
            #"{"clock":12.65,"event":"modelDownloadStarted","expectedBytes":662700000,"model":"whisperkit-large-v3-626mb","t":"2023-11-14T22:13:20.250Z"}"#,
        "modelDownloadFinished":
            #"{"bytes":11534336,"checksum":"matched","clock":12.65,"event":"modelDownloadFinished","install":"installed","model":"speakerkit-pyannote","t":"2023-11-14T22:13:20.250Z","wallSeconds":4.5}"#,
        "libraryWrite":
            #"{"clock":12.65,"event":"libraryWrite","result":"conflict","t":"2023-11-14T22:13:20.250Z"}"#,
        "libraryIndexRebuilt":
            #"{"clock":12.65,"event":"libraryIndexRebuilt","meetings":12,"t":"2023-11-14T22:13:20.250Z","wallMs":85}"#,
        "exportDone":
            #"{"clock":12.65,"event":"exportDone","kind":"diagnostics","t":"2023-11-14T22:13:20.250Z"}"#,
        "agentRun":
            #"{"citations":4,"cli":"claude-code","cliVersion":"2.1.0","clock":12.65,"event":"agentRun","exitCode":0,"failedCitations":1,"outcome":"answered","replyBytes":2048,"t":"2023-11-14T22:13:20.250Z","wallSeconds":18.75}"#,
        "userFacingError":
            #"{"clock":12.65,"code":-10863,"domain":"com.apple.coreaudio","event":"userFacingError","place":"capture","t":"2023-11-14T22:13:20.250Z"}"#,
    ]

    @Test("Each event case has a golden line, and the line matches")
    func goldenLines() {
        for sample in MeetingDiagnosticsSamples.all() {
            let line = MeetingDiagnosticsEncoder.line(
                for: sample.event, time: Self.time, clock: 12.65)
            #expect(Self.goldens[sample.name] == line, "\(sample.name)")
        }
    }

    @Test("A new event case without a sample or a golden line fails this test")
    func everyCaseHasASampleAndAGolden() throws {
        let names = try Self.eventCaseNames()
        #expect(names.count >= 34)
        let sampled = Set(MeetingDiagnosticsSamples.all().map(\.name))
        #expect(sampled == Set(names), "samples and contract cases differ")
        #expect(Set(Self.goldens.keys) == Set(names), "golden lines and contract cases differ")
        // The description names each event with its case name.
        for sample in MeetingDiagnosticsSamples.all() {
            #expect(sample.event.diagnosticDescription.name == sample.name)
        }
    }

    @Test("A line has sorted keys, the time, the clock and the event name")
    func lineShape() throws {
        let line = MeetingDiagnosticsEncoder.line(
            for: .firstBuffer(track: .them, frames: 480), time: Self.time, clock: 12.65)
        #expect(
            line
                == #"{"clock":12.65,"event":"firstBuffer","frames":480,"t":"2023-11-14T22:13:20.250Z","track":"them"}"#
        )
        let noClock = MeetingDiagnosticsEncoder.line(
            for: .recordingPaused, time: Self.time, clock: nil)
        #expect(noClock == #"{"event":"recordingPaused","t":"2023-11-14T22:13:20.250Z"}"#)
        let dropped = MeetingDiagnosticsEncoder.line(
            for: .recordingPaused, time: Self.time, clock: 1, dropped: 7)
        #expect(dropped.contains(#""dropped":7"#))
        let none = MeetingDiagnosticsEncoder.line(
            for: .recordingPaused, time: Self.time, clock: 1, dropped: 0)
        #expect(!none.contains("dropped"))
    }

    @Test("Each line is one valid JSON object with no newline")
    func linesAreValidJSON() throws {
        for sample in MeetingDiagnosticsSamples.all() {
            let line = MeetingDiagnosticsEncoder.line(
                for: sample.event, time: Self.time, clock: 3)
            #expect(!line.contains("\n"), "\(sample.name)")
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let dictionary = try #require(object as? [String: Any])
            #expect(dictionary["event"] as? String == sample.name)
            #expect(dictionary["t"] as? String != nil)
        }
    }

    @Test("No event field uses a key that a line reserves")
    func noReservedKeyInFields() {
        for sample in MeetingDiagnosticsSamples.all() {
            for field in sample.event.diagnosticDescription.fields {
                #expect(
                    !MeetingDiagnosticDescription.reservedKeys.contains(field.key),
                    "\(sample.name): \(field.key)")
            }
        }
    }

    @Test("A path or URL in a text value is replaced, and control characters are escaped")
    func textSafety() throws {
        let event = MeetingDiagnosticEvent.playingProcesses(bundleIDs: [
            "/Users/test/Meetings/audio-me.caf", "file:///private/tmp/x", "~/Desktop/x",
            "com.example.ok",
        ])
        let line = MeetingDiagnosticsEncoder.line(for: event, time: Self.time, clock: nil)
        #expect(!line.contains("/Users"))
        #expect(!line.contains("file:"))
        #expect(!line.contains("Desktop"))
        #expect(line.contains("com.example.ok"))
        #expect(line.contains(MeetingDiagnosticsEncoder.removedPathText))

        let quoted = MeetingDiagnosticEvent.userFacingError(
            place: .library, domain: MeetingDiagnosticString("a\"b\\c"), code: 1)
        let quotedLine = MeetingDiagnosticsEncoder.line(for: quoted, time: Self.time, clock: nil)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(quotedLine.utf8)) as? [String: Any])
        #expect(object["domain"] as? String == #"a"b\c"#)
    }

    @Test("A number that is not finite is null, and a negative zero is zero")
    func numbers() {
        let event = MeetingDiagnosticEvent.recordingStopped(recordedSeconds: .nan)
        #expect(
            MeetingDiagnosticsEncoder.line(for: event, time: Self.time, clock: nil)
                .contains(#""recordedSeconds":null"#))
        let zero = MeetingDiagnosticEvent.recordingStopped(recordedSeconds: -0.0004)
        #expect(
            MeetingDiagnosticsEncoder.line(for: zero, time: Self.time, clock: nil)
                .contains(#""recordedSeconds":0.0"#))
    }

    @Test("A four-character code prints as text, or as hex when it is not printable")
    func fourCharacterCodes() {
        #expect(MeetingDiagnosticEvent.fourCharacterCode(0x626C_7565) == "blue")
        #expect(MeetingDiagnosticEvent.fourCharacterCode(0x0000_0001) == "0x1")
    }

    @Test("The log text keeps device names and bundle ids private")
    func logTextSplitsByPrivacy() {
        let device = MeetingDiagnosticEvent.devices(
            input: MeetingDiagnosticsSamples.airPods, output: nil)
        let text = MeetingDiagnosticLogText(device.diagnosticDescription)
        #expect(!text.publicText.contains("Test AirPods"))
        #expect(text.privateText.contains("Test AirPods"))
        #expect(text.publicText.contains("input.rate=24000.0"))
        #expect(text.publicText.contains("output=none"))
    }

    // MARK: Source of the contract

    /// The case names of `MeetingDiagnosticEvent`, read from the contract.
    private static func eventCaseNames(file: StaticString = #filePath) throws -> [String] {
        let source = try String(
            contentsOf: repositoryRoot(file: file)
                .appending(path: "Sources/RafuCore/Meetings/Contracts/MeetingDiagnostics.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "public enum MeetingDiagnosticEvent"))
        let end = try #require(source.range(of: "public protocol MeetingDiagnosticsRecording"))
        let body = source[start.upperBound..<end.lowerBound]
        var names: [String] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            let rest = trimmed.dropFirst("case ".count)
            names.append(String(rest.prefix { $0.isLetter || $0.isNumber }))
        }
        return names
    }

    static func repositoryRoot(file: StaticString = #filePath) -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path)
        {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }
}
