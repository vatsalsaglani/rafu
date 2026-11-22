import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Meetings speech worker live text and engines")
struct MeetingWorkerLiveAndEngineTests {
    static let helper = MeetingWorkerClientTests.helper
    static let gigabyte: Int64 = 1_000_000_000

    static func chunk(_ track: MeetingTrack, second: Int) -> MeetingAudioChunk {
        // 0.5 s of audio; the first sample holds the second number so each
        // frame is recognisable.
        var samples = Data(count: 16_000)
        samples[0] = UInt8(second & 0xFF)
        samples[1] = UInt8(track == .me ? 1 : 2)
        return MeetingAudioChunk(
            track: track, samples: samples, startTime: Double(second) / 2, frameCount: 8_000)
    }

    static func makeHub(
        _ launcher: FakeWorkerLauncher, diagnostics: RecordingDiagnostics = RecordingDiagnostics()
    ) -> (MeetingWorkerLiveHub, MeetingWorkerProcess) {
        let process = MeetingWorkerProcess(
            helperURL: helper, launcher: launcher, diagnostics: diagnostics)
        let hub = MeetingWorkerLiveHub(
            process: process, footprintLimitBytes: gigabyte, diagnostics: diagnostics,
            makeRequest: { () async throws(MeetingWorkerError) -> MeetingWorkerRequest in
                MeetingWorkerRequest(engine: .nemotronEnglish, modelFolder: "/Models/nemotron/rev")
            })
        return (hub, process)
    }

    @Test("Live lines go to the session of their track, in order")
    func liveRouting() async throws {
        let launcher = FakeWorkerLauncher(scripts: [nil])
        let (hub, process) = Self.makeHub(launcher)
        let me = MeetingWorkerLiveTextSession(
            hub: hub, track: .me, events: await hub.openSession(for: .me))
        let them = MeetingWorkerLiveTextSession(
            hub: hub, track: .them, events: await hub.openSession(for: .them))
        await hub.waitUntilStarted()
        let connection = await launcher.connection(0)
        #expect(connection.request?.audioFile == nil)
        #expect(launcher.specs.first?.arguments == ["--mode", "live-text", "--protocol", "1"])

        await me.append(Self.chunk(.me, second: 0))
        await them.append(Self.chunk(.them, second: 0))
        let word = MeetingWord(text: "hello", start: 0.1, end: 0.4)
        connection.emit([
            .ready(loadMilliseconds: 110, cold: false),
            .volatile(track: .them, text: "hel", start: 0.1, end: 0.5),
            .final(track: .me, words: [word]),
            .final(track: .them, words: [word]),
        ])
        await me.finish()
        #expect(!connection.isInputClosed)
        await them.finish()
        // Closed now, or right after the hub reads `ready` (the reader runs
        // on its own task).
        await connection.waitForInputClose()
        connection.emit([.final(track: .them, words: [word]), .done(audioSeconds: nil)])
        connection.end(.exited(0))

        var meEvents: [MeetingLiveTextEvent] = []
        for await event in me.events { meEvents.append(event) }
        var themEvents: [MeetingLiveTextEvent] = []
        for await event in them.events { themEvents.append(event) }
        #expect(meEvents == [.final(words: [word])])
        #expect(
            themEvents == [
                .volatile(text: "hel", range: 0.1...0.5), .final(words: [word]),
                .final(words: [word]),
            ])
        #expect(connection.frames.map(\.track) == [.me, .them])
        #expect(await hub.hasEnded)
        #expect(process.registry.count == 0)
    }

    @Test("The footprint guard restarts at the limit and loses no chunk")
    func footprintRestart() async throws {
        let launcher = FakeWorkerLauncher(scripts: [nil, nil])
        let diagnostics = RecordingDiagnostics()
        let (hub, _) = Self.makeHub(launcher, diagnostics: diagnostics)
        let session = MeetingWorkerLiveTextSession(
            hub: hub, track: .them, events: await hub.openSession(for: .them))
        await hub.waitUntilStarted()
        let old = await launcher.connection(0)
        old.emit([.ready(loadMilliseconds: 7_000, cold: true)])
        for second in 0..<3 { await session.append(Self.chunk(.them, second: second)) }

        // The helper reports 1.1 GB: a new helper starts; until it is
        // ready, audio still goes to the old one.
        old.emit([
            .stats(
                peakFootprintBytes: 1_100_000_000, chunkP50Milliseconds: 70,
                chunkP95Milliseconds: 100)
        ])
        let new = await launcher.connection(1)
        await new.waitForRequest()
        await session.append(Self.chunk(.them, second: 3))
        #expect(!old.isInputClosed)

        // The new helper is ready: the next chunk goes to it, and the old
        // one gets the end of input.
        new.emit([.ready(loadMilliseconds: 100, cold: false)])
        await old.waitForInputClose()
        for second in 4..<7 { await session.append(Self.chunk(.them, second: second)) }
        #expect(await hub.restartCount == 1)

        let oldSeconds = old.frames.map { Int($0.samples[0]) }
        let newSeconds = new.frames.map { Int($0.samples[0]) }
        #expect(oldSeconds == [0, 1, 2, 3])
        #expect(newSeconds == [4, 5, 6])
        #expect(new.frames.first?.startTime == 2.0)

        // The old helper's last words still reach the session.
        let late = MeetingWord(text: "late", start: 1.5, end: 1.9)
        old.emit([.final(track: .them, words: [late]), .done(audioSeconds: nil)])
        old.end(.exited(0))
        await session.finish()
        new.emit([.done(audioSeconds: nil)])
        new.end(.exited(0))
        var events: [MeetingLiveTextEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events == [.final(words: [late])])
        #expect(
            diagnostics.recorded.contains(
                .helperRestarted(mode: .liveText, reason: .memoryPressure)))
    }

    @Test("Two failed restarts make live text unavailable; the session ends")
    func twoFailedRestarts() async throws {
        let launcher = FakeWorkerLauncher(scripts: [nil])
        let (hub, _) = Self.makeHub(launcher)
        let session = MeetingWorkerLiveTextSession(
            hub: hub, track: .them, events: await hub.openSession(for: .them))
        await hub.waitUntilStarted()
        let connection = await launcher.connection(0)
        launcher.failNextLaunches(2)
        let over = MeetingWorkerEvent.stats(
            peakFootprintBytes: 1_200_000_000, chunkP50Milliseconds: 80, chunkP95Milliseconds: 110)
        connection.emit([.ready(loadMilliseconds: 100, cold: false), over, over])
        var events: [MeetingLiveTextEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events == [.unavailable(reason: MeetingWorkerLiveHub.unavailableReason)])
        #expect(launcher.specs.count == 3)
        #expect(connection.wasTerminated)
        // The recording goes on: more audio is accepted and dropped quietly.
        await session.append(Self.chunk(.them, second: 9))
        await session.finish()
    }

    @Test("A crashed live helper is started again, once")
    func crashRestart() async throws {
        let launcher = FakeWorkerLauncher(scripts: [nil, nil])
        let (hub, _) = Self.makeHub(launcher)
        let session = MeetingWorkerLiveTextSession(
            hub: hub, track: .me, events: await hub.openSession(for: .me))
        await hub.waitUntilStarted()
        let first = await launcher.connection(0)
        first.emit([.ready(loadMilliseconds: 100, cold: false)])
        first.end(.signalled(9))
        let second = await launcher.connection(1)
        await hub.waitUntilStarted()
        // Audio waits for the new helper's model, then reaches it.
        await session.append(Self.chunk(.me, second: 1))
        #expect(second.frames.isEmpty)
        second.emit([.ready(loadMilliseconds: 90, cold: false)])
        second.end(.signalled(9))
        var events: [MeetingLiveTextEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events == [.unavailable(reason: MeetingWorkerLiveHub.unavailableReason)])
        #expect(second.frames.count == 1)
    }

    @Test("Two tracks that start at once share one live helper")
    func concurrentSessionsShareOneHelper() async throws {
        let launcher = FakeWorkerLauncher(scripts: [nil, nil])
        let folder = URL(fileURLWithPath: "/Models/nemotron-en-1120ms/0651794", isDirectory: true)
        let engine = NemotronTextEngine(
            context: Self.context(launcher, folders: [.nemotronEnglish1120: folder]))
        async let me = engine.makeLiveSession(for: .me)
        async let them = engine.makeLiveSession(for: .them)
        let sessions = try await [me, them]
        let connection = await launcher.connection(0)
        #expect(connection.request?.modelFolder == folder.path)
        for session in sessions { await session.finish() }
        // The model still loads: the input closes after `ready`.
        #expect(!connection.isInputClosed)
        connection.emit([.ready(loadMilliseconds: 7_000, cold: true)])
        await connection.waitForInputClose()
        connection.emit([.done(audioSeconds: nil)])
        connection.end(.exited(0))
        for session in sessions {
            for await _ in session.events {}
        }
        #expect(launcher.specs.count == 1)
    }

    // MARK: Engines

    static func context(
        _ launcher: FakeWorkerLauncher, folders: [MeetingModelID: URL],
        helper: URL? = MeetingWorkerLiveAndEngineTests.helper,
        platform: MeetingsAvailability = .available
    ) -> MeetingWorkerEngineContext {
        MeetingWorkerEngineContext(
            process: MeetingWorkerProcess(helperURL: helper, launcher: launcher),
            locator: FakeModelLocator(folders: folders), diagnostics: NoopMeetingDiagnostics(),
            platform: platform)
    }

    static let whisperFolder = URL(
        fileURLWithPath: "/Models/whisperkit-large-v3-626mb/0f63a78", isDirectory: true)

    @Test("Availability comes from the locator, the helper and the platform")
    func availability() async {
        let launcher = FakeWorkerLauncher()
        let none = Self.context(launcher, folders: [:])
        #expect(
            await WhisperKitTextEngine(context: none).availability()
                == .needsModel([.whisperLargeV3]))
        #expect(
            await NemotronTextEngine(context: none).availability()
                == .needsModel([.nemotronEnglish1120]))
        #expect(
            await Nemotron3SpeakerEngine(context: none).availability()
                == .needsModel([.nemotron3Fast32]))
        #expect(
            await SpeakerKitSpeakerEngine(context: none).availability()
                == .needsModel([.speakerKit]))
        let ready = Self.context(launcher, folders: [.whisperLargeV3: Self.whisperFolder])
        #expect(await WhisperKitTextEngine(context: ready).availability() == .ready)
        let noHelper = Self.context(
            launcher, folders: [.whisperLargeV3: Self.whisperFolder], helper: nil)
        #expect(
            await WhisperKitTextEngine(context: noHelper).availability()
                == .unavailable(reason: MeetingWorkerError.helperMissing.userMessage))
        let old = Self.context(
            launcher, folders: [.whisperLargeV3: Self.whisperFolder], platform: .needsMacOS26)
        #expect(
            await WhisperKitTextEngine(context: old).availability()
                == .unavailable(reason: "Meetings needs macOS 26"))
    }

    @Test("WhisperKit has no live text, and its cold load shows as preparing")
    func whisperKitEngine() async throws {
        let launcher = FakeWorkerLauncher(scripts: [MeetingWorkerClientTests.goodTextScript])
        let engine = WhisperKitTextEngine(
            context: Self.context(launcher, folders: [.whisperLargeV3: Self.whisperFolder]))
        #expect(engine.supportsLiveText == false)
        await #expect(throws: MeetingWorkerError.liveTextNotSupported) {
            try await engine.makeLiveSession(for: .them)
        }
        let log = MeetingWorkerClientTests.ProgressLog()
        let meeting = MeetingID()
        let transcript = try await engine.transcribe(
            MeetingFinalTextRequest(
                meeting: meeting, track: .me,
                audioFile: URL(fileURLWithPath: "/Library/Meetings/m/me.caf")),
            progress: { log.add($0) })
        #expect(log.all.first == .preparingModel)
        #expect(transcript.track == .me)
        #expect(transcript.engine == .whisperKit)
        #expect(transcript.model == .whisperLargeV3)
        #expect(transcript.modelRevision == "0f63a78")
        #expect(transcript.words.count == 3)
        let request = try #require(launcher.connections.first?.request)
        #expect(request.engine == .whisperKit)
        #expect(request.modelFolder == Self.whisperFolder.path)
        #expect(request.audioFile == "/Library/Meetings/m/me.caf")
    }

    @Test("A text engine with no model throws modelMissing and starts nothing")
    func noModel() async {
        let launcher = FakeWorkerLauncher()
        let engine = NemotronTextEngine(context: Self.context(launcher, folders: [:]))
        await #expect(throws: MeetingWorkerError.modelMissing(.nemotronEnglish1120)) {
            try await engine.transcribe(
                MeetingFinalTextRequest(
                    meeting: MeetingID(), track: .them, audioFile: URL(fileURLWithPath: "/a.caf")),
                progress: { _ in })
        }
        await #expect(throws: MeetingWorkerError.modelMissing(.nemotronEnglish1120)) {
            try await engine.makeLiveSession(for: .me)
        }
        #expect(launcher.specs.isEmpty)
    }

    @Test("Speaker engines return the helper's segments")
    func speakerEngines() async throws {
        let segments = [
            MeetingSpeakerSegment(speaker: 1, start: 0, end: 2),
            MeetingSpeakerSegment(speaker: 2, start: 2, end: 3.5),
        ]
        let script: [FakeWorkerStep] = [
            .lines([.preparing, .ready(loadMilliseconds: 300, cold: false), .segments(segments)]),
            .lines([.done(audioSeconds: 3.5)]), .waitForInputClose, .exit(0),
        ]
        let launcher = FakeWorkerLauncher(scripts: [script, script])
        let folders: [MeetingModelID: URL] = [
            .nemotron3Fast32: URL(fileURLWithPath: "/Models/nemotron-3-fast32/25a90f9"),
            .speakerKit: URL(fileURLWithPath: "/Models/speakerkit-pyannote/556fc52"),
        ]
        let context = Self.context(launcher, folders: folders)
        let request = MeetingSpeakerRequest(
            meeting: MeetingID(), audioFile: URL(fileURLWithPath: "/Library/Meetings/m/them.caf"))
        #expect(try await Nemotron3SpeakerEngine(context: context).diarize(request) == segments)
        #expect(try await SpeakerKitSpeakerEngine(context: context).diarize(request) == segments)
        #expect(launcher.connections.map { $0.request?.engine } == [.nemotron3, .speakerKit])
        #expect(
            launcher.specs.allSatisfy { $0.arguments == ["--mode", "speakers", "--protocol", "1"] })
    }

    @MainActor
    @Test("The registration adds the two text engines and the two speaker engines")
    func registration() {
        let feature = MeetingsFeature(availability: .available)
        feature.registerSpeechWorkerParts()
        #expect(Set(feature.textEngines.keys) == [.nemotronEnglish, .whisperKit])
        #expect(Set(feature.speakerEngines.keys) == [.nemotron3, .speakerKit])
        #expect(feature.textEngines[.whisperKit]?.supportsLiveText == false)
        #expect(feature.textEngines[.nemotronEnglish]?.supportsLiveText == true)
    }
}
