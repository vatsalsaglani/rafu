import Foundation
import Testing

@testable import RafuCore

/// A synthetic meeting whose text, title, speaker name, question, answer and
/// audio file name each hold a marker word.
private struct SyntheticMeeting {
    static let marker = "ZEBRAQUARTZ"

    let id = MeetingID()
    let speechText = "we should ship the \(marker) release before friday"
    let title = "\(marker) planning call"
    let speakerName = "\(marker) Smith"
    let question = "What did \(marker) Smith promise?"
    let answer = "\(marker) Smith promised the release on friday."
    let audioPath = "/Users/test/Library/Application Support/Rafu/Meetings/\(marker)-me.caf"

    /// Numbers that the library and the engines would report about this
    /// meeting. These are the only values that reach the diagnostics.
    var wordCount: Int { speechText.split(separator: " ").count }
    var titleBytes: Int { title.utf8.count }
    var answerBytes: Int { answer.utf8.count }
    var audioBytes: Int64 { Int64(audioPath.utf8.count) }

    /// Every sample event case, with the numbers of this meeting where a
    /// count is allowed, and a hostile string in each string slot that a
    /// careless caller could misuse: the audio path as a bundle id.
    func events() -> [MeetingDiagnosticEvent] {
        var events = MeetingDiagnosticsSamples.all().map(\.event)
        events.append(contentsOf: [
            .liveTextWindow(
                engine: .appleSpeech, track: .me, delayMedianMilliseconds: 2000,
                delayP95Milliseconds: 3000, words: wordCount),
            .libraryWrite(result: .written, code: titleBytes),
            .agentRun(
                cli: .codex, cliVersion: "0.171.0", exitCode: 0, wallSeconds: 9,
                replyBytes: answerBytes, citations: 1, failedCitations: 0, outcome: .answered),
            .journalSync(bytes: audioBytes, ok: true),
            .playingProcesses(bundleIDs: [MeetingDiagnosticString(audioPath)]),
            .userFacingError(
                place: .agent, domain: MeetingDiagnosticString(audioPath), code: 1),
        ])
        return events
    }
}

@Suite("Meeting diagnostics: privacy")
struct MeetingDiagnosticsPrivacyTests {
    private static let marker = SyntheticMeeting.marker

    private func contains(marker: String, in url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        return data.range(of: Data(marker.utf8)) != nil
    }

    @Test(
        "The marker word is in no diagnostics file, no header.json, no zip content and no log text")
    func markerNeverAppears() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let writer = MeetingDiagnosticsFileWriter(
            directory: directory, flushInterval: .seconds(3600),
            header: { MeetingDiagnosticsHeader.current().event })
        let sink = CapturingLogSink()
        let recorder = MeetingDiagnosticsRecorder(writer: writer, logSink: sink)
        let meeting = SyntheticMeeting()

        // Every event case, for the meeting and for no meeting.
        let events = meeting.events()
        #expect(events.count >= 34)
        for event in events {
            recorder.record(event, meeting: meeting.id)
            recorder.record(event, meeting: nil)
        }
        await recorder.flush()

        // 1. The diagnostics files.
        let files = await writer.exportFiles(newestMeetings: 10)
        #expect(files.count == 2)
        for file in files {
            #expect(try !contains(marker: Self.marker, in: file), "\(file.lastPathComponent)")
            // Each file really holds the events.
            #expect(try DiagnosticsFiles.lines(at: file).count >= events.count)
        }

        // 2. The log text, public and private.
        let captured = sink.captured
        #expect(captured.count == events.count * 2)
        for item in captured {
            #expect(!item.name.contains(Self.marker))
            #expect(!item.publicText.contains(Self.marker), "\(item.name)")
            #expect(!item.privateText.contains(Self.marker), "\(item.name)")
        }
        // The hostile path never reaches the private text either.
        #expect(captured.allSatisfy { !$0.privateText.contains("/Users/") })

        // 3. header.json and the zip, unzipped.
        let context = MeetingDiagnosticsExportContext(
            exportedAt: Date(), header: .current(),
            textEngines: ["apple-speech": "ready"], speakerEngines: [:], models: [:],
            settings: ["textEngine": "nemotron-en", "microphone": "automatic"], meetingCount: 1)
        let name = MeetingDiagnosticsExportBundle.bundleName(for: Date())
        let built = try await MeetingDiagnosticsExportBundle.assemble(
            name: name, context: context, files: files, temporaryDirectory: temporary.url)
        defer { try? FileManager.default.removeItem(at: built.parent) }
        let zip = temporary.child("export.zip")
        try await MeetingDiagnosticsExportBundle.zip(folder: built.folder, to: zip)
        let unzipped = temporary.child("unzipped")
        try DiagnosticsFiles.unzip(zip, into: unzipped)

        let extracted = DiagnosticsFiles.allFiles(below: unzipped)
        #expect(
            extracted.map(\.lastPathComponent).sorted()
                == (files.map(\.lastPathComponent) + ["header.json"]).sorted())
        for file in extracted {
            #expect(try !contains(marker: Self.marker, in: file), "\(file.lastPathComponent)")
        }
        // The marker is a real search term: it is found in a control file.
        let control = temporary.child("control.txt")
        try Data("a \(Self.marker) b".utf8).write(to: control)
        #expect(try contains(marker: Self.marker, in: control))
    }

    @Test("The synthetic meeting carries the marker in each private field")
    func syntheticMeetingHoldsTheMarker() {
        let meeting = SyntheticMeeting()
        for text in [
            meeting.speechText, meeting.title, meeting.speakerName, meeting.question,
            meeting.answer, meeting.audioPath,
        ] {
            #expect(text.contains(Self.marker))
        }
    }

    @Test("A device name is allowed in the log and in the file (the user's requirement)")
    func deviceNamesAreAllowed() throws {
        let line = MeetingDiagnosticsEncoder.line(
            for: .devices(input: MeetingDiagnosticsSamples.airPods, output: nil),
            time: Date(timeIntervalSince1970: 0), clock: nil)
        #expect(line.contains("Test AirPods"))
    }
}
