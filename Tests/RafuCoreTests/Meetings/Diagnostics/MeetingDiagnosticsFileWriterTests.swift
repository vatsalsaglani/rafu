import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting diagnostics: file writer")
struct MeetingDiagnosticsFileWriterTests {
    private static let time = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWriter(
        in directory: URL, limits: MeetingDiagnosticsLimits = .standard
    ) -> MeetingDiagnosticsFileWriter {
        MeetingDiagnosticsFileWriter(
            directory: directory, limits: limits, flushInterval: .seconds(3600),
            header: { diagnosticsTestHeader.event }, now: { Self.time })
    }

    private func entry(
        _ meeting: MeetingID?, frames: Int = 1, event: MeetingDiagnosticEvent? = nil
    ) -> MeetingDiagnosticsEntry {
        MeetingDiagnosticsEntry(
            meeting: meeting, event: event ?? .firstBuffer(track: .me, frames: frames),
            time: Self.time, clock: 1.5)
    }

    @Test("The folder is 0700, each file 0600, and each file starts with the header")
    func modesAndHeader() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let writer = makeWriter(in: directory)
        let meeting = MeetingID()
        await writer.append(entry(meeting))
        await writer.append(entry(nil))
        await writer.flush()

        #expect(try DiagnosticsFiles.permissions(of: directory) == 0o700)
        #expect(
            try DiagnosticsFiles.names(in: directory)
                == ["\(meeting.uuidString).jsonl", "app.jsonl"]
                .sorted())
        for name in try DiagnosticsFiles.names(in: directory) {
            #expect(try DiagnosticsFiles.permissions(of: directory.appending(path: name)) == 0o600)
            let objects = try DiagnosticsFiles.objects(at: directory.appending(path: name))
            #expect(objects.count == 2)
            #expect(objects[0]["event"] as? String == "header")
            #expect(objects[0]["macModel"] as? String == "Mac17,13")
            #expect(objects[1]["event"] as? String == "firstBuffer")
        }
    }

    @Test("A second flush appends to the same file with no second header")
    func appendsAcrossFlushes() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let writer = makeWriter(in: directory)
        await writer.append(entry(nil, frames: 1))
        await writer.flush()
        await writer.append(entry(nil, frames: 2))
        await writer.flush()
        let objects = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        #expect(objects.map { $0["event"] as? String } == ["header", "firstBuffer", "firstBuffer"])
        #expect(objects.compactMap { $0["frames"] as? Int } == [1, 2])
    }

    @Test("A file rotates to .1.jsonl at the limit, with a new header, and two files at most")
    func rotation() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let limits = MeetingDiagnosticsLimits(
            rotationBytes: 1500, retainedMeetings: 20, maximumBufferedBytes: 64 * 1024)
        let writer = makeWriter(in: directory, limits: limits)
        let meeting = MeetingID()
        for frames in 1...60 {
            await writer.append(entry(meeting, frames: frames))
            await writer.flush()
        }
        let names = try DiagnosticsFiles.names(in: directory)
        #expect(names == ["\(meeting.uuidString).1.jsonl", "\(meeting.uuidString).jsonl"].sorted())
        for name in names {
            let url = directory.appending(path: name)
            let size = try #require(
                try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
            #expect(size.intValue <= limits.rotationBytes, "\(name)")
            let objects = try DiagnosticsFiles.objects(at: url)
            #expect(objects.first?["event"] as? String == "header", "\(name)")
            #expect(try DiagnosticsFiles.permissions(of: url) == 0o600)
        }
        // The newest lines are in the current file; the last frame is 60.
        let current = try DiagnosticsFiles.objects(
            at: directory.appending(path: "\(meeting.uuidString).jsonl"))
        #expect(current.last?["frames"] as? Int == 60)
    }

    @Test("Rafu keeps the files of the newest 20 meetings and removes the older ones")
    func retention() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let writer = makeWriter(in: directory)
        var meetings: [MeetingID] = []
        let manager = FileManager.default
        for index in 0..<25 {
            let meeting = MeetingID()
            meetings.append(meeting)
            await writer.append(entry(meeting))
            await writer.flush()
            // Dates in the past, in order, so the order does not depend on the file system clock.
            try manager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(index))],
                ofItemAtPath: directory.appending(path: "\(meeting.uuidString).jsonl").path)
        }
        // Retention runs when a new meeting file is first written, so the 5
        // oldest of the 25 are gone and the newest 20 remain.
        let names = try DiagnosticsFiles.names(in: directory)
        #expect(names.count == 20)
        for meeting in meetings.prefix(5) {
            #expect(!names.contains("\(meeting.uuidString).jsonl"))
        }
        for meeting in meetings.suffix(20) {
            #expect(names.contains("\(meeting.uuidString).jsonl"))
        }
    }

    @Test("app.jsonl is never removed by retention")
    func appFileIsKept() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let limits = MeetingDiagnosticsLimits(
            rotationBytes: 2_000_000, retainedMeetings: 2, maximumBufferedBytes: 64 * 1024)
        let writer = makeWriter(in: directory, limits: limits)
        await writer.append(entry(nil))
        await writer.flush()
        for _ in 0..<5 {
            await writer.append(entry(MeetingID()))
            await writer.flush()
        }
        #expect(try DiagnosticsFiles.names(in: directory).contains("app.jsonl"))
    }

    @Test("Deleting a meeting removes its files, rotated ones too, and its waiting lines")
    func deleteMeeting() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let limits = MeetingDiagnosticsLimits(
            rotationBytes: 600, retainedMeetings: 20, maximumBufferedBytes: 64 * 1024)
        let writer = makeWriter(in: directory, limits: limits)
        let doomed = MeetingID()
        let kept = MeetingID()
        for frames in 1...12 {
            await writer.append(entry(doomed, frames: frames))
            await writer.flush()
        }
        await writer.append(entry(kept))
        await writer.flush()
        #expect(try DiagnosticsFiles.names(in: directory).count == 3)

        await writer.append(entry(doomed, frames: 99))  // waits in the buffer
        await writer.delete(meeting: doomed)
        await writer.flush()
        #expect(try DiagnosticsFiles.names(in: directory) == ["\(kept.uuidString).jsonl"])
    }

    @Test("The writer writes only below the injected folder")
    func onlyTheInjectedRoot() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Inner").appending(path: "Diagnostics")
        let writer = makeWriter(in: directory)
        await writer.append(entry(MeetingID()))
        await writer.append(entry(nil))
        await writer.flush()
        await writer.stop()
        #expect(try DiagnosticsFiles.names(in: temporary.url) == ["Inner"])
        #expect(try DiagnosticsFiles.names(in: temporary.child("Inner")) == ["Diagnostics"])
        #expect(try DiagnosticsFiles.permissions(of: directory) == 0o700)
    }

    @Test("A write error is counted, never thrown, and the next line reports it")
    func writeErrorIsCounted() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        // A regular file where the folder should be: each write fails.
        try Data("blocker".utf8).write(to: directory)
        let writer = makeWriter(in: directory)
        await writer.append(entry(nil, frames: 1))
        await writer.append(entry(nil, frames: 2))
        await writer.flush()
        #expect(await writer.unreportedDroppedCount == 2)

        try FileManager.default.removeItem(at: directory)
        await writer.append(entry(nil, frames: 3), queueDropped: 5)
        await writer.flush()
        #expect(await writer.unreportedDroppedCount == 0)
        let objects = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        let line = try #require(objects.first { ($0["frames"] as? Int) == 3 })
        #expect(line["dropped"] as? Int == 7)
    }

    @Test("A full buffer flushes at once")
    func bufferLimitFlushes() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let limits = MeetingDiagnosticsLimits(
            rotationBytes: 2_000_000, retainedMeetings: 20, maximumBufferedBytes: 300)
        let writer = makeWriter(in: directory, limits: limits)
        for frames in 1...10 {
            await writer.append(entry(nil, frames: frames))
        }
        // No explicit flush: the byte limit wrote the buffer.
        let url = directory.appending(path: "app.jsonl")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try DiagnosticsFiles.lines(at: url).count >= 3)
    }

    @Test("The export lists app files and the files of the newest meetings only")
    func exportFileSelection() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let writer = makeWriter(in: directory)
        var meetings: [MeetingID] = []
        for index in 0..<12 {
            let meeting = MeetingID()
            meetings.append(meeting)
            await writer.append(entry(meeting))
            await writer.flush()
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(index))],
                ofItemAtPath: directory.appending(path: "\(meeting.uuidString).jsonl").path)
        }
        await writer.append(entry(nil))
        let files = await writer.exportFiles(newestMeetings: 10).map(\.lastPathComponent)
        #expect(files.count == 11)
        #expect(files.contains("app.jsonl"))
        for meeting in meetings.suffix(10) {
            #expect(files.contains("\(meeting.uuidString).jsonl"))
        }
        for meeting in meetings.prefix(2) {
            #expect(!files.contains("\(meeting.uuidString).jsonl"))
        }
        #expect(
            await writer.exportFiles(newestMeetings: 0).map(\.lastPathComponent) == ["app.jsonl"])
    }
}
