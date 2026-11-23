import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A feature with a fake recorder, fake engines, a real store at a
/// temporary root, and the session driver.
@MainActor
final class SessionHarness {
    let root: URL
    let store: MeetingStore
    let recorder: SessionFakeRecorder
    let feature: MeetingsFeature
    let probe = TranscribeProbe()
    let nemotron: SessionFakeTextEngine
    let apple: SessionFakeTextEngine
    let whisper: SessionFakeTextEngine
    private(set) var driver: MeetingsSessionDriver?

    init(speakerFails: Bool = false) {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "MeetingsSessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = MeetingStore(
            rootDirectory: root.appending(path: "Library", directoryHint: .isDirectory))
        recorder = SessionFakeRecorder(store: store)
        feature = MeetingsFeature(availability: .available)
        nemotron = SessionFakeTextEngine(.nemotronEnglish, probe: probe)
        apple = SessionFakeTextEngine(.appleSpeech, probe: probe)
        whisper = SessionFakeTextEngine(.whisperKit, probe: probe, supportsLiveText: false)
        feature.register(.store(store))
        feature.register(.recorder(recorder))
        feature.register(.textEngine(nemotron))
        feature.register(.textEngine(apple))
        feature.register(.textEngine(whisper))
        feature.register(.speakerEngine(SessionFakeSpeakerEngine(fails: speakerFails)))
    }

    var session: MeetingsSessionModel { feature.session }

    /// Makes the driver and waits for its scan of interrupted meetings.
    @discardableResult
    func startDriver() async -> MeetingsSessionDriver {
        let made = MeetingsSessionDriver(
            feature: feature, recorder: recorder, feeds: recorder,
            preferences: SessionTestPreferences())
        made.install()
        driver = made
        await made.startupScan?.value
        return made
    }

    func finish() {
        driver?.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func state(of meeting: MeetingID) async -> MeetingState? {
        try? await store.summary(of: meeting)?.state
    }

    func summary(of meeting: MeetingID) async -> MeetingSummaryRecord? {
        try? await store.summary(of: meeting)
    }

    func turns(of meeting: MeetingID) async -> [MeetingTurn] {
        (try? await store.turns(of: meeting, after: nil, limit: 500).turns) ?? []
    }

    /// Record → wait for the recording → returns the meeting.
    func record(_ title: String? = nil) async throws -> MeetingID {
        let before = recorder.startCount
        session.startRecording(title: title)
        try await until("recording") {
            recorder.startCount > before && session.isRecordingOrPaused
                && session.liveMeeting == recorder.meeting
        }
        return try #require(session.liveMeeting)
    }

    func waitReady(_ meeting: MeetingID) async throws {
        try await until("ready") {
            await state(of: meeting) == .ready && session.processing[meeting] == nil
        }
    }
}

@MainActor
@Suite("Meetings session driver")
struct MeetingsSessionDriverTests {
    @Test("Record, live text, Stop, processing → ready")
    func recordToReady() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        #expect(harness.session.isDriverInstalled)

        let meeting = try await harness.record("Standup")
        #expect(harness.session.liveTitle == "Standup")
        try await until("live session") { harness.nemotron.liveSession(.me) != nil }
        let live = try #require(harness.nemotron.liveSession(.me))
        harness.recorder.sendChunk(.me, at: 0.5)
        try await until("audio appended") { live.appendCount > 0 }
        live.input.yield(
            .final(words: [
                MeetingWord(text: "good", start: 1, end: 1.3),
                MeetingWord(text: "morning", start: 1.4, end: 1.8),
            ]))
        try await until("live turn") {
            harness.session.liveTurns.contains { $0.text == "good morning" }
        }
        #expect(harness.session.liveTextEngine == .nemotronEnglish)
        try await until("elapsed") { harness.session.liveElapsed > 0 }

        let revision = harness.session.libraryRevision
        harness.session.stop()
        try await harness.waitReady(meeting)

        let summary = try #require(await harness.summary(of: meeting))
        #expect(summary.engines.textEngine == .nemotronEnglish)
        #expect(summary.engines.speakerEngine == .nemotron3)
        #expect(summary.duration == 42)
        let turns = await harness.turns(of: meeting)
        #expect(turns.contains { $0.track == .me && $0.text == "hello from me" })
        #expect(turns.contains { $0.track == .them && $0.speaker == .speaker(1) })
        #expect(harness.session.libraryRevision > revision)
        #expect(harness.session.processing.isEmpty)
        #expect(harness.session.liveTurns.isEmpty)
        #expect(harness.session.liveElapsed == 0)
        try await until("live session finished") { live.isFinished }
    }

    @Test("The transcribe calls never overlap, also across two meetings")
    func noOverlap() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        let driver = await harness.startDriver()
        var meetings: [MeetingID] = []
        for title in ["A", "B"] {
            let record = try await harness.store.create(title: title, startDate: Date())
            let folder = try await harness.store.audioFolder(for: record.id)
            for track in MeetingTrack.allCases {
                SessionFakeRecorder.writeFinalFile(
                    MeetingJournalLayout.finalAudioFile(track, in: folder))
            }
            meetings.append(record.id)
        }
        for meeting in meetings { driver.runner.enqueue(meeting) }
        #expect(harness.session.processing[meetings[1]] == .waiting)
        for meeting in meetings { try await harness.waitReady(meeting) }
        #expect(!harness.probe.overlapped)
        #expect(harness.probe.calls(of: .nemotronEnglish) == [.me, .them, .me, .them])
    }

    @Test("The preferred engine throws → both tracks come from Apple speech")
    func fallbackToApple() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        harness.nemotron.setTranscribeFails(true)
        let meeting = try await harness.record()
        harness.session.stop()
        try await harness.waitReady(meeting)
        #expect(harness.probe.calls(of: .appleSpeech) == [.me, .them])
        #expect(await harness.summary(of: meeting)?.engines.textEngine == .appleSpeech)
    }

    @Test("The speaker engine throws → ready, far turns keep the label Them")
    func speakerFailure() async throws {
        let harness = SessionHarness(speakerFails: true)
        defer { harness.finish() }
        await harness.startDriver()
        let meeting = try await harness.record()
        harness.session.stop()
        try await harness.waitReady(meeting)
        let far = await harness.turns(of: meeting).filter { $0.track == .them }
        #expect(!far.isEmpty)
        #expect(far.allSatisfy { $0.speaker == .them })
        #expect(await harness.summary(of: meeting)?.engines.speakerEngine == nil)
    }

    @Test("Cancel during text → failed cancelled; Try again → ready")
    func cancelAndRetry() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        harness.nemotron.setBlocksTranscribe(true)
        let meeting = try await harness.record()
        harness.session.stop()
        try await until("transcribe running") { harness.probe.callCount == 1 }
        harness.session.cancelProcessing(meeting)
        try await until("cancelled") {
            await harness.state(of: meeting) == .failed(reasonCode: "cancelled")
                && harness.session.processing[meeting] == .failed(reasonCode: "cancelled")
        }
        harness.nemotron.openGate()
        harness.session.retryProcessing(meeting)
        try await harness.waitReady(meeting)
    }

    @Test("A start error shows its problem and makes no job")
    func startError() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        harness.recorder.failNextStart(.problem(.missingMicrophonePermission))
        harness.session.startRecording()
        try await until("start failure") {
            harness.session.startFailure == .problem(.missingMicrophonePermission)
        }
        #expect(harness.session.processing.isEmpty)
        #expect(harness.probe.callCount == 0)
        #expect(try await harness.store.list().isEmpty)
    }

    @Test("A no-sound problem shows a warning; sound on Them removes it")
    func warningSetAndClear() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        _ = try await harness.record()
        harness.recorder.send(.problem(.noBuffers))
        try await until("warning") { harness.session.warnings.contains(.themNoSound) }
        harness.recorder.setPeak(.them, -20)
        try await until("warning cleared") { !harness.session.warnings.contains(.themNoSound) }
        try await until("level") { harness.session.levels.them > 0 }
    }

    @Test("Each live engine fails → note, and the recording still runs")
    func liveTextUnavailable() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        harness.nemotron.setLiveFails(true)
        harness.apple.setLiveFails(true)
        let meeting = try await harness.record()
        try await until("note") { harness.session.liveTextNote == "Text comes after Stop" }
        #expect(harness.session.liveTextEngine == nil)
        #expect(harness.session.recorderState == .recording(meeting))
    }

    @Test("A session that stops giving text is made again")
    func liveSessionRestart() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        _ = try await harness.record()
        try await until("live session") { harness.nemotron.liveSession(.them) != nil }
        let first = try #require(harness.nemotron.liveSession(.them))
        first.input.yield(.unavailable(reason: "gone"))
        try await until("new session") {
            harness.nemotron.liveSession(.them).map { $0 !== first } ?? false
        }
        #expect(harness.session.liveTextNote == nil)
    }

    @Test("An interrupted meeting is marked, and processed only after Try again")
    func interruptedMeeting() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        let interrupted = try await harness.store.create(title: "Old", startDate: Date())
        let ready = try await harness.store.create(title: "Done", startDate: Date())
        try await harness.store.setState(.ready, of: ready.id, expectedVersion: ready.version)
        await harness.startDriver()

        #expect(await harness.state(of: interrupted.id) == .failed(reasonCode: "interrupted"))
        #expect(harness.session.processing[interrupted.id] == .failed(reasonCode: "interrupted"))
        #expect(await harness.state(of: ready.id) == .ready)
        #expect(harness.recorder.recoverCalls == [interrupted.id])
        #expect(harness.probe.callCount == 0)

        let folder = try await harness.store.audioFolder(for: interrupted.id)
        SessionFakeRecorder.writeFinalFile(MeetingJournalLayout.finalAudioFile(.me, in: folder))
        harness.session.retryProcessing(interrupted.id)
        try await harness.waitReady(interrupted.id)
        #expect(harness.probe.calls(of: .nemotronEnglish) == [.me])
    }

    @Test("A cut-off recording with no audio and no text is deleted at launch")
    func emptyInterruptedDeleted() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        harness.recorder.setRecoversFromJournal(true)
        let empty = try await harness.store.create(title: "Failed start", startDate: Date())
        await harness.startDriver()

        #expect(await harness.summary(of: empty.id) == nil)
        #expect(harness.recorder.recoverCalls == [empty.id])
        #expect(harness.session.processing[empty.id] == nil)
    }

    @Test("A cut-off recording with a journal is kept, recovered and marked interrupted")
    func journalInterruptedKept() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        harness.recorder.setRecoversFromJournal(true)
        let made = try await harness.store.create(title: "Crash", startDate: Date())
        let folder = try await harness.store.audioFolder(for: made.id)
        let writer = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 1)
        try writer.prepare()
        for index in 0..<10 {
            try writer.append(
                track: .me, samples: [Int16](repeating: 900, count: 1_600),
                startTime: Double(index) * 0.1)
        }
        try writer.flush()
        await harness.startDriver()

        #expect(await harness.state(of: made.id) == .failed(reasonCode: "interrupted"))
        let final = MeetingJournalLayout.finalAudioFile(.me, in: folder)
        let size = try FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int
        #expect((size ?? 0) > MeetingCAFFileWriter.headerSize)
    }

    @Test("An older interrupted meeting with nothing in it is deleted; one with audio is kept")
    func oldInterruptedSwept() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        let interrupted = MeetingState.failed(reasonCode: "interrupted")
        let empty = try await harness.store.create(title: "Empty", startDate: Date())
        try await harness.store.setState(interrupted, of: empty.id, expectedVersion: empty.version)
        let kept = try await harness.store.create(title: "Audio", startDate: Date())
        try await harness.store.setState(interrupted, of: kept.id, expectedVersion: kept.version)
        let folder = try await harness.store.audioFolder(for: kept.id)
        SessionFakeRecorder.writeFinalFile(MeetingJournalLayout.finalAudioFile(.them, in: folder))
        let other = try await harness.store.create(title: "Other failure", startDate: Date())
        try await harness.store.setState(
            .failed(reasonCode: "text-failed"), of: other.id, expectedVersion: other.version)
        await harness.startDriver()

        #expect(await harness.summary(of: empty.id) == nil)
        #expect(await harness.state(of: kept.id) == interrupted)
        #expect(await harness.state(of: other.id) == .failed(reasonCode: "text-failed"))
    }

    @Test("A ready meeting with no audio is never deleted at launch")
    func readyNeverSwept() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        harness.recorder.setRecoversFromJournal(true)
        let ready = try await harness.store.create(title: "Done", startDate: Date())
        try await harness.store.setState(.ready, of: ready.id, expectedVersion: ready.version)
        await harness.startDriver()
        #expect(await harness.state(of: ready.id) == .ready)
    }

    @Test("Delete removes the meeting; delete of the live meeting is refused")
    func deleteMeeting() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        let first = try await harness.record()
        harness.session.stop()
        try await harness.waitReady(first)
        harness.session.windowSelection = first
        harness.session.deleteMeeting(first)
        try await until("deleted") {
            await harness.summary(of: first) == nil && harness.session.windowSelection == nil
        }
        #expect(try await harness.store.list().contains { $0.id == first } == false)

        let live = try await harness.record()
        harness.session.deleteMeeting(live)
        #expect(await harness.summary(of: live) != nil)
    }

    @Test("Make the text again with another engine keeps the meeting ready")
    func remakeText() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        let meeting = try await harness.record()
        harness.session.stop()
        try await harness.waitReady(meeting)
        harness.session.remakeText(meeting, with: .whisperKit)
        try await until("remade") {
            await harness.summary(of: meeting)?.engines.textEngine == .whisperKit
                && harness.session.processing[meeting] == nil
        }
        #expect(await harness.state(of: meeting) == .ready)
        #expect(harness.probe.calls(of: .whisperKit) == [.me, .them])
        #expect(!(await harness.turns(of: meeting)).isEmpty)
    }

    @Test("A second recording starts while a job runs")
    func secondRecordingDuringJob() async throws {
        let harness = SessionHarness()
        defer { harness.finish() }
        await harness.startDriver()
        harness.nemotron.setBlocksTranscribe(true)
        let first = try await harness.record()
        harness.session.stop()
        try await until("job running") { harness.probe.callCount == 1 }

        let second = try await harness.record()
        #expect(second != first)
        #expect(harness.session.processing[first] != nil)
        harness.session.stop()
        try await until("second waits") { harness.session.processing[second] == .waiting }

        harness.nemotron.openGate()
        try await harness.waitReady(first)
        try await harness.waitReady(second)
        #expect(!harness.probe.overlapped)
    }

    @Test("The driver is installed only with a recorder on macOS 26")
    func registration() async throws {
        let unavailable = MeetingsFeature(availability: .needsMacOS26)
        #expect(unavailable.installSessionDriver(preferences: SessionTestPreferences()) == nil)
        #expect(!unavailable.session.isDriverInstalled)
        unavailable.session.startRecording()
        #expect(
            unavailable.session.startFailure == .notAvailable(reason: "Meetings needs macOS 26"))

        let harness = SessionHarness()
        defer { harness.finish() }
        let driver = harness.feature.installSessionDriver(preferences: SessionTestPreferences())
        #expect(driver != nil)
        #expect(harness.session.isDriverInstalled)
        driver?.shutdown()
        MeetingsSessionDrivers.drivers[ObjectIdentifier(harness.feature)] = nil
    }
}
