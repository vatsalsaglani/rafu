import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

// The first end-to-end acceptance test of Meetings. Synthetic data only: a
// fake recorder (it writes small silent final files and `recording.json` at
// Stop), fake text and speaker engines, a fake Codex process, and the real
// parts in between — the library store, the diagnostics recorder and writer,
// the session driver, the processing runner, the agent runner, the agent
// tool service, the exporters and the interface registration functions.
// No device, no network, no CLI, no model. Each folder is a temporary one.

/// A text engine with scripted words for each track. It can hold
/// `transcribe` until the test opens its gate.
final class AcceptanceTextEngine: MeetingTextEngine {
    let id: MeetingTextEngineID
    let supportsLiveText: Bool
    private let script: [MeetingTrack: [MeetingWord]]
    private let probe: TranscribeProbe
    private let blocks = Mutex(false)
    private let liveSessions = Mutex<[MeetingTrack: SessionFakeLiveSession]>([:])
    private let gate: AsyncStream<Void>
    private let gateInput: AsyncStream<Void>.Continuation

    init(
        _ id: MeetingTextEngineID, script: [MeetingTrack: [MeetingWord]], probe: TranscribeProbe,
        supportsLiveText: Bool = true
    ) {
        self.id = id
        self.script = script
        self.probe = probe
        self.supportsLiveText = supportsLiveText
        (gate, gateInput) = AsyncStream.makeStream(of: Void.self)
    }

    func holdTranscribe() { blocks.withLock { $0 = true } }
    func openGate() {
        blocks.withLock { $0 = false }
        gateInput.finish()
    }
    func liveSession(_ track: MeetingTrack) -> SessionFakeLiveSession? {
        liveSessions.withLock { $0[track] }
    }

    func availability() async -> MeetingEngineAvailability { .ready }

    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        guard supportsLiveText else { throw CocoaError(.featureUnsupported) }
        let made = SessionFakeLiveSession()
        liveSessions.withLock { $0[track] = made }
        return made
    }

    func transcribe(
        _ request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        probe.enter(id, request.track)
        defer { probe.leave() }
        progress(.working(fraction: 0.5))
        if blocks.withLock({ $0 }) {
            for await _ in gate {}
        }
        try Task.checkCancellation()
        return MeetingTrackTranscript(
            track: request.track, words: script[request.track] ?? [], engine: id)
    }
}

/// The synthetic call: a "Me" greeting, the far side's line with the
/// marker word, the same line heard again through the microphone (echo),
/// and one far-side line after a pause (meeting clock 20 s to 25 s).
enum AcceptanceCall {
    static let marker = "Quetzalbird"
    static let pauseEnd: TimeInterval = 25

    static func words(_ text: String, from start: TimeInterval) -> [MeetingWord] {
        text.split(separator: " ").enumerated().map { index, word in
            MeetingWord(
                text: String(word), start: start + Double(index) * 0.3,
                end: start + Double(index) * 0.3 + 0.25)
        }
    }

    static let me =
        words("hello team thanks for joining", from: 1)
        + words("we ship on friday after the \(marker) review", from: 10.05)
    static let them =
        words("we ship on friday after \(marker) review", from: 10)
        + words("see you all next week", from: 30)

    static var script: [MeetingTrack: [MeetingWord]] { [.me: me, .them: them] }

    /// The turns the pipeline builds from this call (one speaker on "Them").
    static var expectedTurns: [MeetingTurn] {
        MeetingTranscriptAssembly.assemble(
            me: MeetingTrackTranscript(track: .me, words: me, engine: .appleSpeech),
            them: MeetingTrackTranscript(track: .them, words: them, engine: .appleSpeech),
            segments: [MeetingSpeakerSegment(speaker: 1, start: 0, end: 60)],
            outputWasSpeakers: true
        ).turns
    }

    /// The far-side turn with the ship date: the answer cites it.
    static var shipTurn: MeetingTurnID {
        expectedTurns.first { $0.track == .them && $0.text.contains("friday") }!.id
    }
}

/// A test Meetings feature, composed by hand. Never the shared factory and
/// never `registerBuiltInParts()` (both use the real app-data folders).
@MainActor
final class AcceptanceRig {
    let root: URL
    let diagnosticsDirectory: URL
    let runsRoot: URL
    let runtime: MeetingsDiagnosticsRuntime
    let store: MeetingStore
    let recorder: SessionFakeRecorder
    let feature: MeetingsFeature
    let probe = TranscribeProbe()
    let textEngines: [MeetingTextEngineID: AcceptanceTextEngine]
    let process: FakeAgentProcessRunner
    let agentRunner: MeetingAgentRunner
    var agentAccess: MeetingAgentAccess = .off
    private(set) var driver: MeetingsSessionDriver?

    init(answer: String) {
        root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingsAcceptance-\(UUID().uuidString)", directoryHint: .isDirectory)
        diagnosticsDirectory = root.appending(path: "Diagnostics", directoryHint: .isDirectory)
        runsRoot = root.appending(path: "Runs", directoryHint: .isDirectory)
        runtime = MeetingsDiagnosticsRuntime(directory: diagnosticsDirectory)
        feature = MeetingsFeature(availability: .available)
        feature.register(.diagnosticsRecorder(runtime.recorder))
        // The same layout as the app: Library and Diagnostics are siblings,
        // so the store and the diagnostics writer agree on the files.
        store = MeetingStore(
            rootDirectory: root.appending(path: "Library", directoryHint: .isDirectory),
            snapshotRoot: root.appending(path: "Snapshots", directoryHint: .isDirectory),
            diagnostics: runtime.recorder)
        feature.register(.store(store))
        recorder = SessionFakeRecorder(store: store)
        feature.register(.recorder(recorder))
        var engines: [MeetingTextEngineID: AcceptanceTextEngine] = [:]
        for id in MeetingTextEngineID.allCases {
            let engine = AcceptanceTextEngine(
                id, script: AcceptanceCall.script, probe: probe,
                supportsLiveText: id != .whisperKit)
            engines[id] = engine
            feature.register(.textEngine(engine))
        }
        textEngines = engines
        for id in MeetingSpeakerEngineID.allCases {
            feature.register(.speakerEngine(SessionFakeSpeakerEngine(id)))
        }
        process = FakeAgentProcessRunner([
            .lines(
                [
                    AgentStreamLines.codexThread, AgentStreamLines.codexTurnStarted,
                    AgentStreamLines.codexMessage(answer), AgentStreamLines.codexTurnCompleted,
                ], exit: 0)
        ])
        let store = store
        agentRunner = MeetingAgentRunner(
            store: { store }, diagnostics: runtime.recorder, processRunner: process,
            locator: FakeAgentLocator(), runsRoot: runsRoot, timeLimit: .seconds(30),
            environment: MeetingAgentEnvironment.make(
                path: "/usr/bin:/bin", home: "/Users/test", user: "test"),
            prober: FakeAgentProber())
        // The runner is registered before any view could read it.
        feature.register(.agentRunner(agentRunner))
        feature.registerSettingsParts()
        feature.registerDetailParts()
        feature.registerWindowParts()
        feature.registerWorkspaceParts()
    }

    var session: MeetingsSessionModel { feature.session }

    func toolService() -> MeetingAgentToolService {
        MeetingAgentToolService(
            access: { [unowned self] in agentAccess }, store: { [unowned self] in store })
    }

    @discardableResult
    func startDriver(
        text: MeetingTextEngineID = .nemotronEnglish, speaker: MeetingSpeakerEngineID = .nemotron3
    ) async -> MeetingsSessionDriver {
        let made = MeetingsSessionDriver(
            feature: feature, recorder: recorder, feeds: recorder,
            preferences: SessionTestPreferences(textEngine: text, speakerEngine: speaker))
        made.install()
        driver = made
        await made.startupScan?.value
        return made
    }

    func finish() async {
        driver?.shutdown()
        await runtime.recorder.flush()
        try? FileManager.default.removeItem(at: root)
    }

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
        let ready = await waitUntil {
            (try? await store.summary(of: meeting)?.state) == .ready
                && session.processing[meeting] == nil
        }
        if !ready {
            let state = try? await store.summary(of: meeting)?.state
            Issue.record(
                "not ready: state \(String(describing: state)), step \(String(describing: session.processing[meeting])), recorder \(session.recorderState), calls \(probe.callCount)"
            )
            throw CancellationError()
        }
    }

    func turns(of meeting: MeetingID) async throws -> [MeetingTurn] {
        try await store.turns(of: meeting, after: nil, limit: 500).turns
    }

    /// Each diagnostics file as text, after a flush.
    func diagnosticsText() async -> [String: String] {
        await runtime.recorder.flush()
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: diagnosticsDirectory.path)) ?? []
        var result: [String: String] = [:]
        for name in names {
            let url = diagnosticsDirectory.appending(path: name)
            result[name] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return result
    }

    func diagnosticsFileExists(for meeting: MeetingID) -> Bool {
        FileManager.default.fileExists(
            atPath: diagnosticsDirectory.appending(path: "\(meeting.uuidString).jsonl").path)
    }
}

/// A presenter that answers the save panel with a fixed place.
@MainActor
private final class AcceptanceExportPresenter: MeetingDiagnosticsExportPresenting {
    let destination: URL
    private(set) var failures: [String] = []

    init(destination: URL) { self.destination = destination }

    func chooseDestination(
        suggestedName: String, message: String, kind: MeetingDiagnosticsExporter.DestinationKind
    ) async -> URL? { destination }
    func offerFolderInstead() async -> Bool { false }
    func showFailure(_ message: String) { failures.append(message) }
}

@MainActor
@Suite("Meetings acceptance: a synthetic call from Record to Delete")
struct MeetingsAcceptanceTests {
    private static func toolCall(_ name: String, _ arguments: [String: Any]) throws
        -> CanvasAgentToolCall
    {
        try CanvasAgentToolCall.parse(tool: name, arguments: arguments)
    }

    @Test("Record → live → pause → resume → stop → ready → ask → rename → export → tools → delete")
    func fullFlow() async throws {
        let shipTurn = AcceptanceCall.shipTurn
        let rig = AcceptanceRig(answer: "We ship on Friday [\(shipTurn.text)].")
        await rig.startDriver()
        #expect(rig.session.isDriverInstalled)
        #expect(rig.session.canStartRecording)
        // The interface hooks of each package are registered.
        #expect(rig.feature.windowView != nil)
        #expect(rig.feature.meetingDetailView != nil)
        #expect(rig.feature.settingsView != nil)
        #expect(rig.feature.modelDownloadSheet != nil)
        #expect(rig.feature.navigatorView != nil)
        #expect(rig.feature.meetingTabBody != nil)
        #expect(rig.feature.welcomeCard != nil)
        #expect(rig.feature.recordButton != nil)
        #expect(rig.feature.agentRunner != nil)

        // Record → live turns in the model.
        rig.recorder.setOutputWasSpeakers(true)
        let meeting = try await rig.record("Weekly sync")
        #expect(rig.session.liveTitle == "Weekly sync")
        let engine = try #require(rig.textEngines[.nemotronEnglish])
        try await until("live session") { engine.liveSession(.them) != nil }
        let live = try #require(engine.liveSession(.them))
        live.input.yield(.final(words: AcceptanceCall.words("we ship on friday", from: 10)))
        try await until("live turn") {
            rig.session.liveTurns.contains { $0.text == "we ship on friday" }
        }
        #expect(rig.session.liveTextEngine == .nemotronEnglish)

        // Pause → resume.
        rig.session.pause()
        try await until("paused") {
            if case .paused(meeting) = rig.session.recorderState { return true }
            return false
        }
        #expect(
            MeetingsMenuState(isAvailable: true, session: rig.session).pauseTitle
                == "Resume Recording")
        rig.session.resume()
        try await until("resumed") { rig.session.recorderState == .recording(meeting) }

        // Stop → processing → ready.
        rig.session.stop()
        try await until("processing step") {
            if rig.session.processing[meeting] != nil { return true }
            return (try? await rig.store.summary(of: meeting))?.state == .ready
        }
        try await rig.waitReady(meeting)
        #expect(!rig.probe.overlapped)
        let summary = try #require(try await rig.store.summary(of: meeting))
        #expect(summary.engines.textEngine == .nemotronEnglish)
        #expect(summary.engines.speakerEngine == .nemotron3)
        #expect(summary.duration == 42)
        let turns = try await rig.turns(of: meeting)
        #expect(turns == AcceptanceCall.expectedTurns)
        let echo = try #require(turns.first { $0.isEcho })
        #expect(echo.track == .me)
        #expect(echo.text.contains("after the"))
        let ship = try #require(turns.first { $0.id == shipTurn })
        #expect(ship.speaker == .speaker(1))
        // The meeting clock runs through a pause: a word after the pause
        // keeps its engine time, so its turn starts after the pause end.
        let afterPause = try #require(turns.first { $0.text.contains("next week") })
        #expect(afterPause.start >= AcceptanceCall.pauseEnd)

        // Ask through the runner with a fake Codex process.
        let reply = try await rig.agentRunner.ask("When do we ship?", about: meeting, using: .codex)
        #expect(reply.citations.map(\.turn) == [shipTurn])
        let library: any MeetingLibraryServicing = rig.store
        var conversation = try await library.conversation(of: meeting)
        #expect(conversation.map(\.role) == [.question, .answer])
        #expect(conversation.last?.citations.map(\.turn) == [shipTurn])

        // Rename Speaker 1 → Priya; the citation keeps its turn.
        let version = try #require(try await rig.store.summary(of: meeting)).version
        try await rig.store.renameSpeaker(
            .speaker(1), to: "Priya", in: meeting, expectedVersion: version)
        conversation = try await library.conversation(of: meeting)
        #expect(conversation.last?.citations.map(\.turn) == [shipTurn])
        let names = MeetingSpeakerNames(names: try await library.speakerNames(of: meeting))
        let renamed = try #require(try await rig.turns(of: meeting).first { $0.id == shipTurn })
        #expect(names.displayName(for: renamed.speaker) == "Priya")

        // Export Markdown: the name, not the echo line.
        let markdown = try await library.exportMarkdown(
            of: meeting, options: MeetingExportOptions())
        #expect(markdown.contains("Priya"))
        #expect(!markdown.contains("after the \(AcceptanceCall.marker)"))
        #expect(markdown.contains("after \(AcceptanceCall.marker) review"))

        // Export Meeting Diagnostics: the bundle holds this meeting's file.
        let destination = rig.root.appending(path: "Export", directoryHint: .isDirectory)
        let exporter = MeetingDiagnosticsExporter(
            writer: rig.runtime.writer,
            presenter: AcceptanceExportPresenter(destination: destination),
            temporaryDirectory: rig.root,
            zip: { folder, target in try FileManager.default.copyItem(at: folder, to: target) })
        await rig.runtime.recorder.flush()
        #expect(await exporter.export(feature: rig.feature) == .zip)
        let exported = try FileManager.default.subpathsOfDirectory(atPath: destination.path)
        #expect(exported.contains { $0.hasSuffix("\(meeting.uuidString).jsonl") })

        // The agent tool: refused with the switch off, the turns with it on.
        let service = rig.toolService()
        let read = try Self.toolCall("meeting_read", ["meeting_id": meeting.uuidString])
        let refused = await service.perform(read)
        #expect(refused.error == MeetingAgentAccessGate.refusalMessage)
        rig.agentAccess = .on
        let allowed = await service.perform(read)
        #expect(allowed.toolResult?.meeting?.turns?.isEmpty == false)

        // Delete: the store, the diagnostics file and the tool forget it.
        #expect(rig.diagnosticsFileExists(for: meeting))
        rig.session.deleteMeeting(meeting)
        try await until("deleted") { (try? await rig.store.summary(of: meeting)) == nil }
        try await until("diagnostics deleted") { !rig.diagnosticsFileExists(for: meeting) }
        let gone = await service.perform(read)
        #expect(gone.error == MeetingAgentAccessGate.noSuchMeetingMessage)
        #expect(try await rig.store.list().isEmpty)
        await rig.finish()
    }

    @Test(
        "Each pair of text engine and speaker engine makes the meeting and is recorded",
        arguments: MeetingTextEngineID.allCases)
    func enginePairs(text: MeetingTextEngineID) async throws {
        for speaker in MeetingSpeakerEngineID.allCases {
            let rig = AcceptanceRig(answer: "")
            await rig.startDriver(text: text, speaker: speaker)
            let meeting = try await rig.record()
            rig.session.stop()
            try await rig.waitReady(meeting)
            let summary = try #require(try await rig.store.summary(of: meeting))
            #expect(summary.engines.textEngine == text, "\(text) \(speaker)")
            #expect(summary.engines.speakerEngine == speaker, "\(text) \(speaker)")
            #expect(rig.probe.calls(of: text) == [.me, .them])
            await rig.finish()
        }
    }

    @Test("A second recording starts while the first is processing; the queued one shows a step")
    func secondRecordingWhileProcessing() async throws {
        let rig = AcceptanceRig(answer: "")
        await rig.startDriver()
        let engine = try #require(rig.textEngines[.nemotronEnglish])
        engine.holdTranscribe()

        let first = try await rig.record("First")
        rig.session.stop()
        try await until("first runs") { rig.probe.callCount == 1 }
        let second = try await rig.record("Second")
        rig.session.stop()
        try await until("second waits") { rig.session.processing[second] == .waiting }

        // A queued meeting is "Processing", never "Stopped — try again".
        let queued = try #require(try await rig.store.summary(of: second))
        #expect(
            MeetingsWindowPresentation.status(
                for: queued, recorderState: rig.session.recorderState,
                step: rig.session.processing[second]) == .processing)
        guard
            case .running = MeetingsWindowPresentation.processingDisplay(
                state: queued.state, step: rig.session.processing[second])
        else {
            Issue.record("a queued meeting must show a running step")
            return
        }

        engine.openGate()
        try await rig.waitReady(first)
        try await rig.waitReady(second)
        #expect(!rig.probe.overlapped)
        await rig.finish()
    }

    @Test("A stale live state does not skip a meeting that the driver saw stop")
    func staleLiveStateDoesNotSkip() async throws {
        // The recorder state and the recorder events come on two streams,
        // read by two tasks. Under load the `.stopped` event can be handled
        // while the session still shows the meeting as recording; the job
        // then skipped the meeting and left it in processing with no step.
        let rig = AcceptanceRig(answer: "")
        let made = try await rig.store.create(title: "Quick stop", startDate: Date())
        let folder = try await rig.store.audioFolder(for: made.id)
        for track in MeetingTrack.allCases {
            SessionFakeRecorder.writeFinalFile(
                MeetingJournalLayout.finalAudioFile(track, in: folder))
        }
        try await rig.store.setState(.processing, of: made.id, expectedVersion: made.version)
        rig.session.recorderState = .recording(made.id)
        let runner = MeetingProcessingRunner(
            feature: rig.feature, session: rig.session, preferences: SessionTestPreferences())
        #expect(runner.isLiveMeeting(made.id))
        runner.isLiveMeeting = { _ in false }
        runner.enqueue(made.id)
        try await rig.waitReady(made.id)
        #expect(rig.probe.callCount == 2)
        runner.cancelAll()
        await rig.finish()
    }

    @Test("An interrupted meeting shows try again and is ready after Retry")
    func interruptedMeeting() async throws {
        let rig = AcceptanceRig(answer: "")
        let made = try await rig.store.create(
            title: "Cut off", startDate: Date().addingTimeInterval(-60))
        let folder = try await rig.store.audioFolder(for: made.id)
        for track in MeetingTrack.allCases {
            SessionFakeRecorder.writeFinalFile(
                MeetingJournalLayout.finalAudioFile(track, in: folder))
        }
        #expect(try await rig.store.summary(of: made.id)?.state == .recording)

        await rig.startDriver()
        let failed = try #require(try await rig.store.summary(of: made.id))
        #expect(failed.state == .failed(reasonCode: MeetingProcessingFailure.interrupted))
        #expect(
            MeetingsWindowPresentation.status(
                for: failed, recorderState: rig.session.recorderState,
                step: rig.session.processing[made.id])?.word == "Stopped — try again")

        rig.session.retryProcessing(made.id)
        try await rig.waitReady(made.id)
        #expect(try await rig.turns(of: made.id).isEmpty == false)
        await rig.finish()
    }

    @Test(
        "A marker word in speech, title, name, question and answer is in no diagnostics file and no CLI argument"
    )
    func markerNeverLeaks() async throws {
        let marker = AcceptanceCall.marker
        let rig = AcceptanceRig(answer: "\(marker) ships Friday [\(AcceptanceCall.shipTurn.text)].")
        await rig.startDriver()
        let meeting = try await rig.record("Plan \(marker)")
        rig.session.stop()
        try await rig.waitReady(meeting)
        let version = try #require(try await rig.store.summary(of: meeting)).version
        try await rig.store.renameSpeaker(
            .speaker(1), to: "Ana \(marker)", in: meeting, expectedVersion: version)
        let reply = try await rig.agentRunner.ask(
            "Did \(marker) say when?", about: meeting, using: .codex)
        #expect(reply.text.contains(marker))

        let files = await rig.diagnosticsText()
        #expect(!files.isEmpty)
        for (name, text) in files {
            #expect(!text.contains(marker), "\(name)")
            #expect(!text.lowercased().contains(marker.lowercased()), "\(name)")
        }
        #expect(!rig.process.starts.isEmpty)
        for start in rig.process.starts {
            let visible =
                (start.spec.arguments + start.spec.environment.keys
                + start.spec.environment.values).joined(separator: " ")
            #expect(!visible.contains(marker))
        }
        await rig.finish()
    }

    @Test(
        "A meeting has no workspace field: a workspace window during the recording changes nothing")
    func noWorkspaceField() async throws {
        let rig = AcceptanceRig(answer: "")
        await rig.startDriver()
        let meeting = try await rig.record("Solo")
        let file = rig.root.appending(path: "Library").appending(path: meeting.uuidString)
            .appending(path: "meeting.json")
        let before = try Self.keys(of: file)

        let workspace = WorkspaceSession()
        workspace.switchNavigator(to: .meetings)
        workspace.openMeetingTab(meeting)
        let after = try Self.keys(of: file)
        #expect(before == after)
        #expect(!before.contains { $0.lowercased().contains("workspace") })

        rig.session.stop()
        try await rig.waitReady(meeting)
        let ready = try Self.keys(of: file)
        #expect(!ready.contains { $0.lowercased().contains("workspace") })
        await rig.finish()
    }

    private static func keys(of file: URL) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return Set((object as? [String: Any])?.keys ?? [:].keys)
    }
}
