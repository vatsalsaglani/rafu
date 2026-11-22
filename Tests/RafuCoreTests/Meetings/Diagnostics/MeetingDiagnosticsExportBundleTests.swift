import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting diagnostics: export bundle")
struct MeetingDiagnosticsExportBundleTests {
    static let exportDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func context(meetingCount: Int? = 0) -> MeetingDiagnosticsExportContext {
        MeetingDiagnosticsExportContext(
            exportedAt: exportDate, header: diagnosticsTestHeader,
            textEngines: ["apple-speech": "ready", "nemotron-en": "needsModel"],
            speakerEngines: ["nemotron-3": "notRegistered"],
            models: ["nemotron-en-1120ms": "notInstalled"],
            settings: ["textEngine": "nemotron-en", "microphone": "automatic"],
            meetingCount: meetingCount)
    }

    @Test("The bundle name is the local date")
    func bundleName() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(
            MeetingDiagnosticsExportBundle.bundleName(for: Self.exportDate, timeZone: utc)
                == "Rafu Meeting Diagnostics 2023-11-14")
    }

    @Test("An export with zero meetings is a zip with header.json only")
    func zeroMeetings() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let name = MeetingDiagnosticsExportBundle.bundleName(for: Self.exportDate)
        let built = try await MeetingDiagnosticsExportBundle.assemble(
            name: name, context: Self.context(), files: [],
            temporaryDirectory: temporary.url)
        defer { try? FileManager.default.removeItem(at: built.parent) }
        #expect(try DiagnosticsFiles.permissions(of: built.folder) == 0o700)
        #expect(try DiagnosticsFiles.names(in: built.folder) == ["header.json"])

        let zip = temporary.child("export.zip")
        try await MeetingDiagnosticsExportBundle.zip(folder: built.folder, to: zip)
        let unzipped = temporary.child("unzipped")
        try DiagnosticsFiles.unzip(zip, into: unzipped)
        let files = DiagnosticsFiles.allFiles(below: unzipped)
        #expect(files.map(\.lastPathComponent) == ["header.json"])
        #expect(files.first?.deletingLastPathComponent().lastPathComponent == name)

        let header = try #require(files.first)
        let decoded = try JSONDecoder().decode(
            MeetingDiagnosticsExportContext.self, from: Data(contentsOf: header))
        #expect(decoded.header == diagnosticsTestHeader)
        #expect(decoded.meetingCount == 0)
        #expect(decoded.textEngines["nemotron-en"] == "needsModel")
        #expect(decoded.formatVersion == 1)
    }

    @Test("The bundle holds header.json and a copy of each diagnostics file")
    func withFiles() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let writer = MeetingDiagnosticsFileWriter(
            directory: directory, flushInterval: .seconds(3600),
            header: { diagnosticsTestHeader.event })
        let meeting = MeetingID()
        await writer.append(
            MeetingDiagnosticsEntry(
                meeting: meeting, event: .recordingPaused, time: Self.exportDate, clock: 1))
        await writer.append(
            MeetingDiagnosticsEntry(
                meeting: nil, event: .recordingResumed, time: Self.exportDate, clock: nil))
        let files = await writer.exportFiles(newestMeetings: 10)
        let built = try await MeetingDiagnosticsExportBundle.assemble(
            name: "Bundle", context: Self.context(meetingCount: 1), files: files,
            temporaryDirectory: temporary.url)
        defer { try? FileManager.default.removeItem(at: built.parent) }
        #expect(
            try DiagnosticsFiles.names(in: built.folder)
                == ["\(meeting.uuidString).jsonl", "app.jsonl", "header.json"].sorted())
    }

    @Test("A zip that cannot be written throws, and the caller removes the temporary folder")
    func zipFailure() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let built = try await MeetingDiagnosticsExportBundle.assemble(
            name: "Bundle", context: Self.context(), files: [], temporaryDirectory: temporary.url)
        // A regular file where the zip's folder should be: `ditto` cannot write there.
        let blocker = temporary.child("blocker")
        try Data("x".utf8).write(to: blocker)
        let missingFolder = blocker.appending(path: "x.zip")
        await #expect(throws: MeetingDiagnosticsExportBundle.ExportError.self) {
            try await MeetingDiagnosticsExportBundle.zip(folder: built.folder, to: missingFolder)
        }
        try FileManager.default.removeItem(at: built.parent)
        #expect(try DiagnosticsFiles.names(in: temporary.url) == ["blocker"])
    }

    @Test("A failed build leaves no temporary folder")
    func failedBuildCleansUp() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let missing = temporary.child("missing.jsonl")
        await #expect(throws: (any Error).self) {
            _ = try await MeetingDiagnosticsExportBundle.assemble(
                name: "Bundle", context: Self.context(), files: [missing],
                temporaryDirectory: temporary.url)
        }
        #expect(try DiagnosticsFiles.names(in: temporary.url).isEmpty)
    }

    @Test("An engine's own reason text is not exported, only a fixed word")
    func availabilityWords() {
        #expect(MeetingDiagnosticsExportContext.word(for: .ready) == "ready")
        #expect(
            MeetingDiagnosticsExportContext.word(for: .needsModel([.nemotronEnglish1120]))
                == "needsModel")
        #expect(
            MeetingDiagnosticsExportContext.word(for: .unavailable(reason: "ZEBRAQUARTZ"))
                == "unavailable")
    }
}
