import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Meeting recorder with fake sources")
struct MeetingRecorderTests {
    @available(macOS 26, *)
    private static func facts(_ harness: RecorderHarness, _ meeting: MeetingID) async throws
        -> MeetingRecordingFacts
    {
        let folder = try await harness.store.audioFolder(for: meeting)
        let data = try Data(contentsOf: folder.appending(path: MeetingRecordingFacts.fileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingRecordingFacts.self, from: data)
    }

    @available(macOS 26, *)
    private static func collect(_ stream: AsyncStream<MeetingAudioChunk>) async
        -> [MeetingAudioChunk]
    {
        var chunks: [MeetingAudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    @available(macOS 26, *)
    @Test("Start, pause, resume and stop; the audio is kept and the meeting is processing")
    func lifecycle() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        let id = try await recorder.start(title: "Weekly sync")
        #expect(await recorder.state == .recording(id))
        #expect(await recorder.startFacts?.outputWasSpeakers == true)

        await harness.microphone.send(hostTime: RecorderHarness.hostTime(0), count: 16_000)
        await harness.systemAudio.send(hostTime: RecorderHarness.hostTime(0.5), count: 8_000)

        harness.hostClock.set(RecorderHarness.hostTime(2))
        await recorder.pause()
        #expect(await recorder.state == .paused(id))
        #expect(await harness.microphone.stopCount == 1)

        harness.hostClock.set(RecorderHarness.hostTime(5))
        await recorder.resume()
        #expect(await recorder.state == .recording(id))
        #expect(await harness.microphone.startCount == 2)
        await harness.microphone.send(hostTime: RecorderHarness.hostTime(5), count: 16_000)

        harness.hostClock.set(RecorderHarness.hostTime(6))
        await recorder.stop()
        #expect(await recorder.state == .idle)

        let folder = try await harness.store.audioFolder(for: id)
        let me = MeetingJournalLayout.finalAudioFile(.me, in: folder)
        let them = MeetingJournalLayout.finalAudioFile(.them, in: folder)
        #expect(FileManager.default.fileExists(atPath: me.path))
        #expect(FileManager.default.fileExists(atPath: them.path))
        let meBytes = try Data(contentsOf: me).count - MeetingCAFFileWriter.headerSize
        #expect(meBytes == 6 * 16_000 * 2)  // 0-1 s audio, silence, 5-6 s audio
        // The journal is gone after a clean recovery.
        #expect(!MeetingAudioJournalRecovery.hasJournal(in: folder))

        let facts = try await Self.facts(harness, id)
        #expect(facts.spans == [MeetingRecordingSpan(kind: .paused, start: 2, end: 5)])
        #expect(facts.endTime == 6)
        #expect(facts.recordedSeconds == 3)
        #expect(facts.outputWasSpeakers)
        #expect(await harness.store.meetings[id]?.state == .processing)

        let events = harness.diagnostics.recorded
        #expect(events.contains(.recordingPaused))
        #expect(events.contains(.recordingResumed))
        #expect(events.contains(.firstBuffer(track: .me, frames: 16_000)))
        #expect(events.contains(.permissions(microphone: .granted, systemAudio: .unknown)))
        #expect(events.contains { if case .devices = $0 { true } else { false } })
        #expect(events.contains(.microphoneChoice(kind: .automatic, reason: .systemDefault)))
        #expect(events.contains { if case .recordingStopped = $0 { true } else { false } })
    }

    @available(macOS 26, *)
    @Test("Them starts 12.65 s after Me: the chunks are 12.65 s apart on the meeting clock")
    func clockFromHostTimes() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let live = harness.recorder.liveAudio()
        _ = try await harness.recorder.start(title: "Clock")
        await harness.microphone.send(hostTime: RecorderHarness.hostTime(0.16), count: 1_600)
        await harness.systemAudio.send(hostTime: RecorderHarness.hostTime(12.81), count: 1_600)
        harness.hostClock.set(RecorderHarness.hostTime(14))
        await harness.recorder.stop()

        let chunks = await Self.collect(live)
        let me = try #require(chunks.first { $0.track == .me })
        let them = try #require(chunks.first { $0.track == .them })
        #expect(abs(me.startTime - 0.16) < 1e-9)
        #expect(abs(them.startTime - me.startTime - 12.65) < 1e-9)
        #expect(me.isWellFormed && them.isWellFormed)
        #expect(me.frameCount == 1_600)
    }

    @available(macOS 26, *)
    @Test("Two Starts give one session")
    func twoStarts() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        async let first = harness.recorder.start(title: "A")
        async let second = harness.recorder.start(title: "B")
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(await harness.microphone.startCount == 1)
        #expect(await harness.store.meetings.count == 1)
        let third = try await harness.recorder.start(title: "C")
        #expect(third == a)
        await harness.recorder.stop()
    }

    @available(macOS 26, *)
    @Test("Stop during starting ends cleanly: no meeting, no source, idle")
    func stopDuringStarting() async throws {
        let permissions = FakePermissions()
        await permissions.closeGate()
        let harness = RecorderHarness(
            permissions: permissions, onStopWhileStarting: { await permissions.openGate() })
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        let start = Task { try await recorder.start(title: "Never") }
        await permissions.waitUntilEntered()
        await recorder.stop()
        await #expect(throws: MeetingRecorderError.cancelled) { try await start.value }
        #expect(await recorder.state == .idle)
        #expect(await harness.store.meetings.isEmpty)
        #expect(await harness.microphone.startCount == 0)
    }

    @available(macOS 26, *)
    @Test("A missing microphone permission is a problem at once, with the pane to open")
    func missingMicrophonePermission() async throws {
        let harness = RecorderHarness(permissions: FakePermissions(microphone: .denied))
        defer { Task { await harness.store.removeAll() } }
        await #expect(throws: MeetingRecorderError.problem(.missingMicrophonePermission)) {
            try await harness.recorder.start(title: "Denied")
        }
        #expect(await harness.recorder.state == .problem(.missingMicrophonePermission))
        #expect(MeetingCaptureProblem.missingMicrophonePermission.settingsPaneURL != nil)
        #expect(await harness.microphone.startCount == 0)

        // Not asked yet: Start asks, and a refusal is the same problem.
        let notAsked = RecorderHarness(
            permissions: FakePermissions(microphone: .notDetermined, allowOnRequest: false))
        defer { Task { await notAsked.store.removeAll() } }
        await #expect(throws: MeetingRecorderError.problem(.missingMicrophonePermission)) {
            try await notAsked.recorder.start(title: "Refused")
        }
    }

    @available(macOS 26, *)
    @Test("A failed call-audio tap fails the start and removes the meeting")
    func tapFailureFailsStart() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        await harness.systemAudio.failNextStarts([
            .failed(call: .createProcessTap, status: -50)
        ])
        await #expect(throws: MeetingRecorderError.problem(.deviceLost)) {
            try await harness.recorder.start(title: "No tap")
        }
        #expect(await harness.store.meetings.isEmpty)
        #expect(await harness.microphone.stopCount == 1)
    }

    @available(macOS 26, *)
    @Test("No microphone buffers for 5 s stops the recording with a problem")
    func microphoneSilenceIsAProblem() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        _ = try await recorder.start(title: "Dead mic")
        await recorder.tick(now: 4.9)
        #expect(await recorder.state.meeting != nil)
        await recorder.tick(now: 5)
        await recorder.stop()  // waits for the stop that the fault started
        #expect(await recorder.state == .problem(.noBuffers))
        await recorder.dismissProblem()
        #expect(await recorder.state == .idle)
    }

    /// Sends one "Me" block at `second` and waits until the recorder took
    /// it (its chunk is on the live stream).
    @available(macOS 26, *)
    private static func feedMicrophone(
        _ harness: RecorderHarness, at second: Double,
        live: inout AsyncStream<MeetingAudioChunk>.Iterator
    ) async {
        harness.monotonic.set(second)
        await harness.microphone.send(hostTime: RecorderHarness.hostTime(second), count: 1_600)
        _ = await live.next()
    }

    @available(macOS 26, *)
    private static func captureReports(_ harness: RecorderHarness) -> [Int] {
        harness.diagnostics.recorded.compactMap {
            if case .userFacingError(.capture, _, let code) = $0 { code } else { nil }
        }
    }

    @available(macOS 26, *)
    @Test("No Them buffers while nothing plays is not a problem")
    func themQuietIsFine() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        var live = recorder.liveAudio().makeAsyncIterator()
        let id = try await recorder.start(title: "Quiet")
        harness.playing.set([])
        for second in stride(from: 0.0, through: 20, by: 4) {
            await Self.feedMicrophone(harness, at: second, live: &live)
            await recorder.tick(now: second + 0.5)
        }
        #expect(await recorder.state == .recording(id))
        #expect(Self.captureReports(harness).isEmpty)
        await recorder.stop()
        #expect(await recorder.state == .idle)
    }

    @available(macOS 26, *)
    @Test("Them: 5 s of no buffers while another app plays is reported; Me keeps recording")
    func themNoBuffersWhilePlaying() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        var live = recorder.liveAudio().makeAsyncIterator()
        let id = try await recorder.start(title: "Playing")
        harness.playing.set(["us.zoom.xos"])
        await Self.feedMicrophone(harness, at: 0, live: &live)
        await recorder.tick(now: 0.5)
        await Self.feedMicrophone(harness, at: 4, live: &live)
        await recorder.tick(now: 4.5)
        #expect(Self.captureReports(harness).isEmpty)
        await Self.feedMicrophone(harness, at: 5.4, live: &live)
        await recorder.tick(now: 5.5)
        #expect(Self.captureReports(harness) == [MeetingCaptureProblem.noBuffers.code])
        #expect(await recorder.state == .recording(id))
        await recorder.stop()
    }

    @available(macOS 26, *)
    @Test("Them: exact silence while another app plays is reported as a missing grant")
    func themSilentWhilePlaying() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        var live = recorder.liveAudio().makeAsyncIterator()
        let id = try await recorder.start(title: "Silent tap")
        harness.playing.set(["com.google.Chrome"])
        for second in stride(from: 0.0, through: 6, by: 1) {
            await Self.feedMicrophone(harness, at: second, live: &live)
            await harness.systemAudio.send(
                hostTime: RecorderHarness.hostTime(second), count: 1_600, value: 0)
            _ = await live.next()
            await recorder.tick(now: second + 0.1)
        }
        #expect(
            Self.captureReports(harness)
                == [MeetingCaptureProblem.missingSystemAudioPermission.code])
        #expect(await recorder.state == .recording(id))
        await recorder.stop()
    }

    @available(macOS 26, *)
    @Test("Device loss: the lost track is rebuilt with a gap span; the other track keeps going")
    func deviceLoss() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        var live = recorder.liveAudio().makeAsyncIterator()
        let id = try await recorder.start(title: "Switch")
        var themStarts = harness.systemAudio.starts.makeAsyncIterator()
        #expect(await themStarts.next() == 1)

        await harness.microphone.send(hostTime: RecorderHarness.hostTime(0), count: 16_000)
        await harness.systemAudio.send(hostTime: RecorderHarness.hostTime(0), count: 16_000)
        var chunks: [MeetingAudioChunk] = []
        for _ in 0..<2 { if let chunk = await live.next() { chunks.append(chunk) } }
        harness.hostClock.set(RecorderHarness.hostTime(3))
        await harness.systemAudio.interrupt()
        #expect(await themStarts.next() == 2)  // rebuilt
        harness.hostClock.set(RecorderHarness.hostTime(4))
        await harness.systemAudio.send(hostTime: RecorderHarness.hostTime(4), count: 16_000)
        await harness.microphone.send(hostTime: RecorderHarness.hostTime(1), count: 16_000)
        harness.hostClock.set(RecorderHarness.hostTime(5))
        await recorder.stop()
        #expect(await recorder.state == .idle)

        let facts = try await Self.facts(harness, id)
        let gap = try #require(facts.spans.first { $0.kind == .gap(.them) })
        #expect(gap.start == 3)
        #expect(gap.end != nil)
        #expect(await harness.microphone.startCount == 1)
        #expect(
            harness.diagnostics.recorded.contains {
                if case .deviceChanged(.them, _, .some) = $0 { true } else { false }
            })
        while let chunk = await live.next() { chunks.append(chunk) }
        #expect(chunks.filter { $0.track == .me }.count == 2)
        #expect(chunks.filter { $0.track == .them }.map(\.startTime).sorted() == [0, 4])
    }

    @available(macOS 26, *)
    @Test("A microphone that cannot be opened again stops the recording; the audio is kept")
    func microphoneLost() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        let recorder = harness.recorder
        let id = try await recorder.start(title: "Lost")
        await harness.microphone.send(hostTime: RecorderHarness.hostTime(0), count: 16_000)
        await harness.microphone.failNextStarts([.noDevice, .noDevice])
        var iterator = recorder.events.makeAsyncIterator()
        // The rebuild fails twice and starts the stop.
        await harness.microphone.interrupt()
        while let event = await iterator.next() {
            if event == .stopped(id) { break }
        }
        await recorder.stop()
        #expect(await recorder.state == .problem(.deviceLost))
        let folder = try await harness.store.audioFolder(for: id)
        #expect(
            FileManager.default.fileExists(
                atPath: MeetingJournalLayout.finalAudioFile(.me, in: folder).path))
    }

    @available(macOS 26, *)
    @Test("Without a library the start fails and the recorder stays idle")
    func noLibrary() async {
        let harness = RecorderHarness(storeAvailable: false)
        await #expect(throws: MeetingRecorderError.noLibrary) {
            try await harness.recorder.start(title: "x")
        }
        #expect(await harness.recorder.state == .idle)
    }

    @available(macOS 26, *)
    @Test("States stream: a new reader gets the current state first")
    func statesStream() async throws {
        let harness = RecorderHarness()
        defer { Task { await harness.store.removeAll() } }
        var states = harness.recorder.states.makeAsyncIterator()
        #expect(await states.next() == .idle)
        let id = try await harness.recorder.start(title: "s")
        #expect(await states.next() == .starting)
        #expect(await states.next() == .recording(id))
        await harness.recorder.stop()
        #expect(await states.next() == .stopping(id))
        #expect(await states.next() == .idle)
    }
}
