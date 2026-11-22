import Foundation
import Synchronization
import Testing

@testable import RafuCore

@Suite("Meeting diagnostics: recorder and queue")
struct MeetingDiagnosticsRecorderTests {
    private func makeWriter(in directory: URL) -> MeetingDiagnosticsFileWriter {
        MeetingDiagnosticsFileWriter(
            directory: directory, flushInterval: .seconds(3600),
            header: { diagnosticsTestHeader.event })
    }

    @Test("10,000 events from 8 tasks: no crash, drops counted, order kept for each task")
    func concurrentQueue() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let recorder = MeetingDiagnosticsRecorder(writer: makeWriter(in: directory))
        let taskCount = 8
        let perTask = 1250

        // Each task records `taskIndex << 32 | sequence` as the journal bytes and
        // times each call with the monotonic clock.
        let durations = await withTaskGroup(of: [Int64].self, returning: [Int64].self) { group in
            for taskIndex in 0..<taskCount {
                group.addTask {
                    var samples: [Int64] = []
                    samples.reserveCapacity(perTask)
                    let clock = ContinuousClock()
                    for sequence in 0..<perTask {
                        let event = MeetingDiagnosticEvent.journalSync(
                            bytes: Int64(taskIndex) << 32 | Int64(sequence), ok: true)
                        let start = clock.now
                        recorder.record(event, meeting: nil)
                        let elapsed = clock.now - start
                        samples.append(
                            elapsed.components.seconds * 1_000_000_000
                                + elapsed.components.attoseconds / 1_000_000_000)
                    }
                    return samples
                }
            }
            var all: [Int64] = []
            for await samples in group { all.append(contentsOf: samples) }
            return all
        }
        await recorder.flush()

        // `record` returns at once: p99 under 1 ms.
        let sorted = durations.sorted()
        #expect(sorted.count == taskCount * perTask)
        let p99 = sorted[Int(Double(sorted.count) * 0.99)]
        #expect(p99 < 1_000_000, "p99 was \(p99) ns")

        let objects = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        var lastSequence: [Int: Int] = [:]
        var written = 0
        var reportedDrops = 0
        for object in objects {
            reportedDrops += object["dropped"] as? Int ?? 0
            guard object["event"] as? String == "journalSync",
                let bytes = object["bytes"] as? Int
            else { continue }
            written += 1
            let task = bytes >> 32
            let sequence = bytes & 0xFFFF_FFFF
            if let last = lastSequence[task] {
                #expect(sequence > last, "task \(task) went backwards")
            }
            lastSequence[task] = sequence
        }
        // Each event was written or counted as dropped, and the lines report the count.
        #expect(written + recorder.droppedEventCount == taskCount * perTask)
        #expect(reportedDrops == recorder.droppedEventCount)
    }

    @Test("A full queue drops the oldest events and counts them")
    func fullQueueDropsOldest() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let recorder = MeetingDiagnosticsRecorder(
            writer: makeWriter(in: directory), logSink: nil, queueCapacity: 8, autostart: false,
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        for frames in 0..<20 {
            recorder.record(.firstBuffer(track: .them, frames: frames), meeting: nil)
        }
        #expect(recorder.droppedEventCount == 12)
        recorder.start()
        await recorder.stop()

        let objects = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        let events = objects.filter { $0["event"] as? String == "firstBuffer" }
        #expect(events.compactMap { $0["frames"] as? Int } == Array(12..<20))
        // The first line that is written reports the drops.
        #expect(events.first?["dropped"] as? Int == 12)
        #expect(events.dropFirst().allSatisfy { $0["dropped"] == nil })
    }

    @Test("A line carries the clock of its meeting: seconds since the meeting's first event")
    func meetingClock() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let steps = SteppingClock()
        let recorder = MeetingDiagnosticsRecorder(
            writer: makeWriter(in: directory), logSink: nil, queueCapacity: 64, autostart: true,
            now: { steps.now() })
        let meeting = MeetingID()
        recorder.record(.recordingResumed, meeting: meeting)
        recorder.record(.recordingPaused, meeting: nil)
        recorder.record(.recordingStopped(recordedSeconds: 3), meeting: meeting)
        await recorder.flush()

        let meetingLines = try DiagnosticsFiles.objects(
            at: directory.appending(path: "\(meeting.uuidString).jsonl"))
        #expect(meetingLines.dropFirst().compactMap { $0["clock"] as? Double } == [0, 2])
        let appLines = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        #expect(appLines.allSatisfy { $0["clock"] == nil })
    }

    @Test("The log sink gets each event, with its meeting")
    func sinkGetsEvents() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let sink = CapturingLogSink()
        let recorder = MeetingDiagnosticsRecorder(
            writer: makeWriter(in: temporary.child("Diagnostics")), logSink: sink)
        let meeting = MeetingID()
        recorder.record(
            .devices(input: MeetingDiagnosticsSamples.airPods, output: nil), meeting: meeting)
        recorder.record(.recordingPaused, meeting: nil)
        await recorder.flush()
        let captured = sink.captured
        #expect(captured.map(\.name) == ["devices", "recordingPaused"])
        #expect(captured[0].meeting == meeting)
        #expect(captured[0].privateText.contains("Test AirPods"))
        #expect(!captured[0].publicText.contains("Test AirPods"))
    }

    @Test("A helper exit is written with its exit code")
    func endEventsFlushAtOnce() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let recorder = MeetingDiagnosticsRecorder(writer: makeWriter(in: directory))
        recorder.record(
            .helperExited(
                mode: .liveText, exitCode: 1, signal: nil, wallSeconds: 1, peakFootprintBytes: nil),
            meeting: nil)
        await recorder.flush()
        let objects = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        #expect(objects.last?["event"] as? String == "helperExited")
        #expect(objects.last?["exitCode"] as? Int == 1)
    }

    @Test("After stop the recorder takes no event and does not crash")
    func afterStop() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let recorder = MeetingDiagnosticsRecorder(writer: makeWriter(in: directory))
        recorder.record(.recordingPaused, meeting: nil)
        await recorder.stop()
        recorder.record(.recordingResumed, meeting: nil)
        await recorder.flush()
        await recorder.stop()
        let objects = try DiagnosticsFiles.objects(at: directory.appending(path: "app.jsonl"))
        #expect(objects.map { $0["event"] as? String } == ["header", "recordingPaused"])
    }

    @Test("Deleting the diagnostics of a meeting removes its file, after queued lines are written")
    func deleteDiagnostics() async throws {
        let temporary = try DiagnosticsTemporaryFolder()
        let directory = temporary.child("Diagnostics")
        let recorder = MeetingDiagnosticsRecorder(writer: makeWriter(in: directory))
        let meeting = MeetingID()
        recorder.record(.recordingPaused, meeting: meeting)
        recorder.record(.recordingPaused, meeting: nil)
        await recorder.deleteDiagnostics(for: meeting)
        #expect(try DiagnosticsFiles.names(in: directory) == ["app.jsonl"])
    }

    @Test("The header names this Mac and this build")
    func currentHeader() {
        let header = MeetingDiagnosticsHeader.current()
        #expect(!header.macOSVersion.isEmpty)
        #expect(header.macModel != "")
        #expect(header.macOSBuild != "")
        #expect(["release", "lightning"].contains(header.rafuVariant))
        guard case .header(_, _, let model, _, _, _, let offset) = header.event else {
            Issue.record("not a header event")
            return
        }
        #expect(model.value == header.macModel)
        #expect(offset == TimeZone.current.secondsFromGMT())
    }
}
