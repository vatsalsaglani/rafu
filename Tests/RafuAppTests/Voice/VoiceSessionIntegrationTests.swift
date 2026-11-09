import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

// MARK: Fakes

/// A GPT-Live socket that records what Rafu sends and replays scripted
/// server lines. It answers `session.start` and `session.close` like the
/// Phase 0 server. No network.
final class ScriptedLiveTransport: VoiceLiveTransport {
    let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let log = Mutex<[String]>([])
    private let cancelled = Atomic<Bool>(false)
    private let answersStart: Bool

    init(answersStart: Bool = true) {
        self.answersStart = answersStart
        (incoming, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func connect() async throws {}

    func send(_ text: String) async throws {
        log.withLock { $0.append(text) }
        if answersStart, text.contains(#""type":"session.start""#) {
            push(#"{"type":"session.started","session":{"id":"sess_test","expires_at":1}}"#)
        }
        if text.contains(#""type":"session.close""#) {
            push(#"{"type":"session.closed","reason":"close_requested","usage":{"seconds":12}}"#)
        }
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        continuation.finish()
    }

    func push(_ line: String) { continuation.yield(line) }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
    var sent: [String] { log.withLock { $0 } }

    func sent(type: String) -> [String] {
        sent.filter { $0.contains("\"type\":\"\(type)\"") }
    }

    func types() -> [String] {
        sent.compactMap { text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"]
                as? String
        }
    }
}

/// Microphone and speaker fakes. No AVAudioEngine in tests.
@MainActor
final class FakeVoiceAudio: VoiceAudioCapturing, VoiceAudioPlaying {
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var captureStarts = 0
    private(set) var captureStops = 0
    private(set) var enqueued = 0
    private(set) var flushes = 0
    private(set) var playing = false
    var supportsBargeIn = true
    var lastEngineFacts = VoiceEngineFacts(
        voiceProcessing: true, startMS: 42, inputChannels: 9, sampleRate: 48_000)
    /// How many of the next `startCapture` calls throw.
    var failingCaptureStarts = 0
    private(set) var playbackStarts = 0
    private var stats = VoiceCaptureStats()

    var isCapturing: Bool { continuation != nil }

    func startCapture() throws -> AsyncStream<Data> {
        if failingCaptureStarts > 0 {
            failingCaptureStarts -= 1
            throw VoiceAudioError.noInput
        }
        stats = VoiceCaptureStats()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.continuation = continuation
        captureStarts += 1
        return stream
    }

    func stopCapture() {
        continuation?.finish()
        continuation = nil
        captureStops += 1
    }

    func startPlayback() throws {
        playing = true
        playbackStarts += 1
    }
    func enqueue(_ pcm: Data) { enqueued += 1 }
    func flush() { flushes += 1 }
    func stopAll() { playing = false }

    func takeCaptureStats() -> VoiceCaptureStats {
        defer { stats = VoiceCaptureStats() }
        return stats
    }

    func push(_ frame: Data) {
        guard let continuation else { return }
        if case .dropped = continuation.yield(frame) { stats.dropped += 1 }
        stats.yielded += 1
    }
}

/// Stands in for the Confirm card: records each request, and answers when
/// the test says so (or at once with `autoAnswer`).
@MainActor
final class ConfirmProbe {
    private(set) var requests: [VoiceConfirmRequest] = []
    private(set) var dismissals = 0
    var autoAnswer: VoiceConfirmAnswer?
    private var answer: (@MainActor (VoiceConfirmAnswer) -> Void)?

    var presenter: VoiceConfirmPresenter {
        { [self] request, answer in
            requests.append(request)
            self.answer = answer
            if let autoAnswer { answer(autoAnswer) }
            return { [self] in dismissals += 1 }
        }
    }

    /// A click on the card.
    func click(_ value: VoiceConfirmAnswer) { answer?(value) }
}

/// Removes the fixture's temporary workspace.
private final class VoiceScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-voice-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// An open, shown Ensemble with two notes, and a voice session wired to it
/// through fakes.
@MainActor
private struct VoiceFixture {
    let workspace: WorkspaceSession
    let board: CanvasBoardState
    let transport: ScriptedLiveTransport
    let audio = FakeVoiceAudio()
    let confirm = ConfirmProbe()
    let voice: VoiceSession
    let suite: String
    private let scratch = VoiceScratchFolder()

    init(
        key: String? = "test-key", microphone: Bool = true, capDollars: Int? = nil,
        transport: ScriptedLiveTransport = ScriptedLiveTransport(),
        confirmTimeout: Duration = .seconds(30), transcriptDirectory: URL? = nil,
        agentActivity: VoiceAgentActivitySource? = nil
    ) async throws {
        let scratch = scratch
        suite = TestDefaultsSuite.name("dev.rafu.voice-tests")
        if let capDollars {
            UserDefaults(suiteName: suite)?.set(capDollars, forKey: VoicePreferences.monthlyCapKey)
        }
        let workspace = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.voice-restoration"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await workspace.canvas.configure(root: scratch.url))
        let board = try #require(await workspace.canvas.create(title: "Voice test"))
        try board.add(title: "Plan", content: .note(snapshot: "# Plan\n"))
        try board.add(title: "Review", content: .note(snapshot: ""))
        workspace.installCanvasResources(for: board)
        workspace.canvasResources[board.id]?.present(owner: UUID())
        self.workspace = workspace
        self.board = board
        self.transport = transport
        let audio = audio
        var dependencies = VoiceSession.Dependencies(
            makeTransport: { _ in transport },
            openAIKey: {
                guard let key else { throw VoiceError.noOpenAIKey }
                return key
            },
            requestMicrophone: { microphone },
            makeAudio: { (audio, audio) },
            preferences: VoicePreferences(suiteName: suite),
            costSuiteName: suite)
        dependencies.target = { VoiceTarget(session: workspace, board: board) }
        dependencies.workspaces = { [workspace] }
        dependencies.runsClock = false
        dependencies.startTimeout = .seconds(5)
        dependencies.closeTimeout = .seconds(5)
        dependencies.presentConfirm = confirm.presenter
        dependencies.confirmTimeout = confirmTimeout
        dependencies.debugTranscriptDirectory = transcriptDirectory
        if let agentActivity { dependencies.agentActivity = agentActivity }
        voice = VoiceSession(dependencies: dependencies)
    }

    func id(_ title: String) -> String? {
        board.cards.first { $0.title == title }?.id.rawValue.uuidString
    }

    func run(_ name: String, _ arguments: String = "{}") async -> VoiceToolOutcome {
        await VoiceToolExecutor.run(name: name, argumentsJSON: arguments, host: voice)
    }

    /// Opens a latched session and waits until GPT-Live answered.
    func openLatched() async throws {
        voice.toggleLatched()
        try await until { voice.blobState == .listeningLatched }
    }
}

/// Bounded: yields until `condition` holds.
@MainActor
private func until(
    _ label: String = "condition", _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<200_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for \(label)")
    throw CancellationError()
}

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

// MARK: Session protocol

@Suite("Voice session")
@MainActor
struct VoiceSessionIntegrationTests {
    @Test("Hold: session.start, frames while held, mute on release")
    func holdToTalk() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        #expect(voice.blobState == .idle)
        voice.beginHold()
        #expect(voice.blobState == .connecting)
        try await until("listening") { voice.blobState == .listeningHeld }
        let start = try json(try #require(fixture.transport.sent.first))
        #expect(start["type"] as? String == "session.start")
        let session = try #require(start["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-live-1")
        #expect(
            ((session["audio"] as? [String: Any])?["output"] as? [String: Any])?["voice"] as? String
                == "marin")
        let responses = try #require(
            (session["delegation"] as? [String: Any])?["responses"] as? [String: Any])
        #expect(responses["model"] as? String == "gpt-6.1-terra")
        #expect((responses["tools"] as? [Any])?.count == VoiceToolSchema.tools(for: .rafu).count)
        #expect(fixture.audio.playing)
        #expect(fixture.audio.isCapturing)

        for _ in 0..<3 { fixture.audio.push(Data(count: VoiceAudioFormat.inputFrameBytes)) }
        try await until("frames") {
            fixture.transport.sent(type: "session.input_audio.append").count == 3
        }
        voice.endHold()
        #expect(voice.blobState == .thinking)
        #expect(!fixture.audio.isCapturing)
        try await until("mute") {
            !fixture.transport.sent(type: "session.input_audio.mute").isEmpty
        }

        await voice.close()
        #expect(voice.blobState == .idle)
        #expect(fixture.transport.isCancelled)
        #expect(!fixture.audio.playing)
        let types = fixture.transport.types()
        #expect(types.last == "session.close")
    }

    @Test("A function call runs on the board, answers, then sends response.create")
    func functionCallRoundTrip() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"note_create","arguments":"{\"title\":\"Ideas\"}"}}}"#
        )
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.completed","response":{"usage":{"input_tokens":900,"output_tokens":12}}}}"#
        )
        try await until("response.create") {
            !fixture.transport.sent(type: "response.create").isEmpty
        }
        let types = fixture.transport.types()
        let outputIndex = try #require(types.firstIndex(of: "response.item.create"))
        let createIndex = try #require(types.firstIndex(of: "response.create"))
        #expect(outputIndex < createIndex)
        #expect(fixture.transport.sent(type: "response.create").count == 1)
        let output = try json(
            try #require(fixture.transport.sent(type: "response.item.create").first))
        let item = try #require(output["item"] as? [String: Any])
        #expect(item["call_id"] as? String == "call_1")
        #expect((item["output"] as? String)?.contains("\"node_id\"") == true)
        #expect(fixture.board.cards.map(\.title).contains("Ideas"))
        #expect(fixture.board.notice?.message.hasPrefix("Rafu (voice) added Ideas") == true)
        let row = fixture.voice.timeline.rows(lane: .tool).first
        #expect(row?.title == "note_create")
        #expect(row?.detail == "ok")
        await fixture.voice.close()
        // The last session stays readable until the next one opens.
        #expect(fixture.voice.timeline.rows(lane: .tool).first?.title == "note_create")
        fixture.voice.toggleLatched()
        #expect(fixture.voice.timeline.events.isEmpty)
        await fixture.voice.close()
    }

    @Test("Usage updates feed the cost meter")
    func usage() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(#"{"type":"session.usage.updated","usage":{"seconds":30.5}}"#)
        try await until("usage") { fixture.voice.costStore.monthlySeconds == 30.5 }
        await fixture.voice.close()
        #expect(fixture.voice.costStore.monthlySeconds == 30.5)
    }

    @Test("Latched silence: check-in at 45 s, pause at 60 s, close at 90 s")
    func silenceTimers() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        voice.tick(at: .seconds(45))
        #expect(voice.blobState == .checkIn)
        try await until("check-in") {
            !fixture.transport.sent(type: "session.commentary.append").isEmpty
        }
        voice.tick(at: .seconds(60))
        #expect(voice.blobState == .paused)
        #expect(!fixture.audio.isCapturing)
        try await until("mute") {
            !fixture.transport.sent(type: "session.input_audio.mute").isEmpty
        }
        voice.tick(at: .seconds(90))
        try await until("closed") { voice.blobState == .idle }
        #expect(fixture.transport.isCancelled)
    }

    @Test("No OpenAI key: the blob says so and nothing connects")
    func noKey() async throws {
        let fixture = try await VoiceFixture(key: nil)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.beginHold()
        try await until("error") {
            fixture.voice.blobState == .error(VoiceError.noOpenAIKey.blobReason)
        }
        #expect(fixture.transport.sent.isEmpty)
        #expect(!fixture.audio.isCapturing)
        fixture.voice.endHold()
        fixture.voice.dismissError()
        #expect(fixture.voice.blobState == .idle)
    }

    @Test("Microphone denied: nothing opens")
    func microphoneDenied() async throws {
        let fixture = try await VoiceFixture(microphone: false)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.toggleLatched()
        try await until("error") {
            fixture.voice.blobState == .error(VoiceError.microphoneDenied.blobReason)
        }
        #expect(fixture.transport.sent.isEmpty)
        #expect(fixture.audio.captureStarts == 0)
    }

    @Test("The monthly cap blocks a new session")
    func capReached() async throws {
        let fixture = try await VoiceFixture(capDollars: 1)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.costStore.recordUsage(sessionID: "old", seconds: 30 * 60)
        fixture.voice.toggleLatched()
        try await until("error") {
            fixture.voice.blobState == .error(VoiceError.monthlyCapReached.blobReason)
        }
        #expect(fixture.transport.sent.isEmpty)
    }

    @Test("A refused start reports the code and tears down")
    func refusedStart() async throws {
        let transport = ScriptedLiveTransport(answersStart: false)
        let fixture = try await VoiceFixture(transport: transport)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.toggleLatched()
        try await until("start sent") { !transport.sent(type: "session.start").isEmpty }
        transport.push(
            #"{"type":"error","error":{"code":"forbidden","message":"Voice session access denied."}}"#
        )
        try await until("error") {
            fixture.voice.blobState == .error(VoiceError.refused(code: "forbidden").blobReason)
        }
        // The error shows at once; the teardown finishes after it.
        try await until("teardown") { !fixture.audio.playing }
        #expect(transport.isCancelled)
        #expect(transport.sent(type: "session.close").isEmpty)
    }

    @Test("Speech said while connecting goes out after session.started, then mute")
    func earlyRelease() async throws {
        let transport = ScriptedLiveTransport(answersStart: false)
        let fixture = try await VoiceFixture(transport: transport)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.beginHold()
        try await until("capturing") { fixture.audio.isCapturing }
        let frame = Data(count: VoiceAudioFormat.inputFrameBytes)
        fixture.audio.push(frame)
        fixture.audio.push(frame)
        fixture.voice.endHold()
        try await until("start sent") { !transport.sent(type: "session.start").isEmpty }
        #expect(transport.sent(type: "session.input_audio.append").isEmpty)
        transport.push(#"{"type":"session.started","session":{"id":"sess_late"}}"#)
        try await until("mute") { !transport.sent(type: "session.input_audio.mute").isEmpty }
        let types = transport.types()
        let appends = types.indices.filter { types[$0] == "session.input_audio.append" }
        #expect(appends.count == 2)
        #expect(appends.last! < types.lastIndex(of: "session.input_audio.mute")!)
        #expect(fixture.voice.blobState == .paused)
        await fixture.voice.close()
    }

    @Test("A second press while connecting keeps the first press's frames")
    func rePressWhileConnecting() async throws {
        let transport = ScriptedLiveTransport(answersStart: false)
        let fixture = try await VoiceFixture(transport: transport)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let frame = Data(count: VoiceAudioFormat.inputFrameBytes)
        fixture.voice.beginHold()
        try await until("capturing") { fixture.audio.isCapturing }
        fixture.audio.push(frame)
        fixture.audio.push(frame)
        fixture.voice.endHold()
        fixture.voice.beginHold()
        #expect(fixture.audio.isCapturing)
        fixture.audio.push(frame)
        fixture.voice.endHold()
        try await until("start sent") { !transport.sent(type: "session.start").isEmpty }
        transport.push(#"{"type":"session.started","session":{"id":"sess_twice"}}"#)
        try await until("two mutes") { transport.sent(type: "session.input_audio.mute").count == 2 }
        #expect(transport.sent(type: "session.input_audio.append").count == 3)
        await fixture.voice.close()
    }

    @Test("Not latched: the engine stops after a quiet spell and restarts on the next press")
    func engineSuspends() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        voice.beginHold()
        try await until("listening") { voice.blobState == .listeningHeld }
        voice.tick(at: .seconds(30))
        #expect(!voice.isEngineSuspended)
        voice.endHold()
        // The quiet spell counts from real session time; anchor to it.
        voice.tick(at: voice.sessionElapsed + .seconds(5))
        #expect(!voice.isEngineSuspended)
        voice.tick(at: voice.sessionElapsed + .seconds(11))
        #expect(voice.isEngineSuspended)
        #expect(!fixture.audio.playing)
        #expect(voice.blobState.isOpen)
        voice.beginHold()
        #expect(!voice.isEngineSuspended)
        #expect(fixture.audio.playing)
        #expect(fixture.audio.isCapturing)
        voice.endHold()
        voice.tick(at: voice.sessionElapsed + .seconds(30))
        #expect(voice.isEngineSuspended)
        // Audible output restarts it; silence alone does not.
        fixture.transport.push(
            #"{"type":"session.output_audio.delta","delta":"\#(Data(count: 4_800).base64EncodedString())"}"#
        )
        var loud = Data()
        for _ in 0..<2_400 { loud.append(contentsOf: [0x00, 0x10]) }
        fixture.transport.push(
            #"{"type":"session.output_audio.delta","delta":"\#(loud.base64EncodedString())"}"#)
        try await until("restarted") { fixture.audio.playing }
        #expect(fixture.audio.enqueued == 1)
        await voice.close()
    }

    @Test("Latched: the engine never stops for silence")
    func latchedKeepsEngine() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.voice.tick(at: fixture.voice.sessionElapsed + .seconds(20))
        #expect(!fixture.voice.isEngineSuspended)
        #expect(fixture.audio.playing)
        await fixture.voice.close()
    }

    @Test("Quit: terminateNow drops the socket and closes at once")
    func terminateNow() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(#"{"type":"session.usage.updated","usage":{"seconds":4}}"#)
        try await until("usage") { fixture.voice.costStore.monthlySeconds == 4 }
        fixture.voice.terminateNow()
        #expect(fixture.voice.blobState == .idle)
        #expect(!fixture.voice.hasOpenSession)
        #expect(fixture.transport.isCancelled)
        #expect(!fixture.audio.playing)
        #expect(fixture.transport.sent(type: "session.close").isEmpty)
        #expect(fixture.voice.costStore.monthlySeconds == 4)
    }

    @Test("Quit: closeForQuit sends session.close within the limit")
    func closeForQuit() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        await fixture.voice.closeForQuit(limit: .seconds(2))
        #expect(fixture.voice.blobState == .idle)
        #expect(fixture.transport.sent(type: "session.close").count == 1)
        #expect(fixture.transport.isCancelled)
    }

    @Test("A waiting card blocks the clock and closing cancels it")
    func closeCancelsCard() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        let pending = Task { await fixture.run("node_remove", #"{"node_id":"Review"}"#) }
        try await until("card") { fixture.voice.confirmGate.isPending }
        #expect(fixture.voice.blobState == .needsConfirm)
        fixture.voice.tick(at: .seconds(120))
        #expect(fixture.voice.blobState == .needsConfirm)
        await fixture.voice.close()
        #expect(await pending.value.output.contains("cancelled"))
        #expect(fixture.board.cards.count == 2)
    }

    @Test("A socket that drops before start reports Voice disconnected")
    func dropBeforeStart() async throws {
        let transport = ScriptedLiveTransport(answersStart: false)
        let fixture = try await VoiceFixture(transport: transport)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.toggleLatched()
        try await until("start sent") { !transport.sent(type: "session.start").isEmpty }
        transport.cancel()
        try await until("error") {
            fixture.voice.blobState == .error(VoiceError.disconnected.blobReason)
        }
        try await until("teardown") { !fixture.audio.playing }
    }

    @Test("Audible output plays and local speech cuts it")
    func bargeIn() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        var loud = Data()
        for _ in 0..<2_400 { loud.append(contentsOf: [0x00, 0x10]) }
        fixture.transport.push(
            #"{"type":"session.output_audio.delta","delta":"\#(loud.base64EncodedString())"}"#)
        try await until("speaking") { voice.blobState == .speaking }
        #expect(fixture.audio.enqueued == 1)
        var speech = Data()
        for _ in 0..<VoiceAudioFormat.inputFrameSamples { speech.append(contentsOf: [0x00, 0x20]) }
        for _ in 0..<VoiceAudioFormat.localSpeechFrames { fixture.audio.push(speech) }
        try await until("flush") { fixture.audio.flushes == 1 }
        #expect(voice.blobState == .listeningLatched)
        await voice.close()
    }
}

// MARK: Tools and policy

@Suite("Voice tool executor")
@MainActor
struct VoiceToolExecutorTests {
    @Test("Ask runs an edit with the Rafu (voice) notice and badge; voice_undo reverts it")
    func askEditAndUndo() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        #expect(fixture.board.agentControlMode == .ask)
        let created = await fixture.run("note_create", #"{"title":"Plan B"}"#)
        #expect(!created.isError)
        #expect(fixture.board.cards.count == 3)
        let card = try #require(fixture.board.cards.last)
        let record = CanvasAgentProvenanceStore.shared.record(for: card.id, now: Date())
        #expect(record?.agentName == "Rafu (voice)")
        #expect(record?.cli == nil)
        #expect(record?.symbol == "waveform")
        #expect(
            CanvasAgentCenter.shared.log(for: fixture.board.id).last?.agent == "Rafu (voice)")
        let undone = await fixture.run("voice_undo")
        #expect(!undone.isError)
        #expect(fixture.board.cards.count == 2)
        let again = await fixture.run("voice_undo")
        #expect(again.output.contains("nothing_to_undo"))
    }

    @Test("voice_undo never undoes the user's own later edit")
    func undoRespectsLaterEdits() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = await fixture.run("note_create", #"{"title":"Voice note"}"#)
        try fixture.board.add(title: "Mine", content: .note(snapshot: ""))
        let refused = await fixture.run("voice_undo")
        #expect(refused.output.contains("nothing_to_undo"))
        #expect(fixture.board.cards.map(\.title).contains("Mine"))
        #expect(fixture.board.cards.map(\.title).contains("Voice note"))
    }

    @Test("Off denies an edit, reads still work")
    func offIsReadOnly() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.board.setAgentControlMode(.off)
        let denied = await fixture.run("note_create", #"{"title":"Blocked"}"#)
        #expect(denied.output.contains("agent_control_off"))
        #expect(fixture.board.cards.count == 2)
        let read = await fixture.run("note_read", #"{"node_id":"Plan"}"#)
        #expect(read.output.contains("# Plan"))
        #expect(read.summary.hasSuffix("7 bytes"))
        let tidy = await fixture.run("view_tidy")
        #expect(tidy.output.contains("agent_control_off"))
    }

    @Test("Ask: a removal waits on a destructive Confirm card; Cancel keeps the node")
    func confirmCancelAndAllow() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.confirm.autoAnswer = .cancel
        let cancelled = await fixture.run("node_remove", #"{"node_id":"Review"}"#)
        #expect(cancelled.output.contains("\"cancelled\""))
        #expect(fixture.board.cards.count == 2)
        let request = try #require(fixture.confirm.requests.first)
        #expect(request.tool == .nodeRemove)
        #expect(request.isDestructive)
        #expect(!request.offersSessionGrant)
        #expect(request.actionTitle == "Remove")
        #expect(request.message.contains("Voice test"))
        #expect(fixture.confirm.dismissals == 1)
        #expect(
            CanvasAgentCenter.shared.log(for: fixture.board.id).last?.outcome
                == "Cancelled by the user")

        fixture.confirm.autoAnswer = .allowOnce
        let removed = await fixture.run("node_remove", #"{"node_id":"Review"}"#)
        #expect(!removed.isError)
        #expect(fixture.board.cards.map(\.title) == ["Plan"])
        #expect(fixture.confirm.requests.count == 2)
    }

    @Test("A spoken voice_confirm in a later user turn resolves the waiting card")
    func spokenConfirm() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        let idle = await fixture.run("voice_confirm")
        #expect(idle.output.contains("nothing_pending"))
        let pending = Task { await fixture.run("node_remove", #"{"node_id":"Review"}"#) }
        try await until("card") { fixture.voice.confirmGate.isPending }
        // A second sensitive call while one waits does not stack a card.
        let busy = await fixture.run(
            "edge_remove", #"{"edge_id":"\#(UUID().uuidString)"}"#)
        #expect(busy.output.contains("confirm_busy"))
        // The user speaks: GPT-Live starts a new backend turn.
        fixture.transport.push(
            #"{"type":"session.delegation.created","delegation":{"id":"del_yes","target":"responses"}}"#
        )
        try await until("turn") {
            fixture.voice.timeline.rows(lane: .delegation).count == 1
        }
        let spoken = await fixture.run("voice_confirm", #"{"always":true}"#)
        #expect(!spoken.isError)
        let removal = await pending.value
        #expect(!removal.isError)
        #expect(fixture.board.cards.count == 1)
        #expect(fixture.confirm.dismissals == 1)
        // "always" never grants a removal.
        let request = try #require(fixture.confirm.requests.first)
        #expect(!fixture.voice.hasSessionGrant(request.grantKey))
        let none = await fixture.run("voice_cancel")
        #expect(none.output.contains("nothing_pending"))
        await fixture.voice.close()
    }

    @Test("The backend cannot confirm its own call in the same turn; a cancel counts")
    func sameTurnConfirmRefused() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(
            #"{"type":"session.delegation.created","delegation":{"id":"del_1","target":"responses"}}"#
        )
        try await until("turn") { fixture.voice.timeline.rows(lane: .delegation).count == 1 }
        let pending = Task { await fixture.run("node_remove", #"{"node_id":"Review"}"#) }
        try await until("card") { fixture.voice.confirmGate.isPending }
        let selfConfirm = await fixture.run("voice_confirm")
        #expect(selfConfirm.output.contains("not_heard"))
        #expect(fixture.voice.confirmGate.isPending)
        #expect(fixture.board.cards.count == 2)
        let cancel = await fixture.run("voice_cancel")
        #expect(!cancel.isError)
        #expect(await pending.value.output.contains("cancelled"))
        #expect(fixture.board.cards.count == 2)
        await fixture.voice.close()
    }

    @Test("Without a window for the card, a sensitive call is refused at once")
    func noWindowRefuses() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let gate = VoiceConfirmGate()
        let call = try CanvasAgentToolCall.parse(
            tool: "node_remove", arguments: ["node_id": UUID().uuidString])
        let answer = await gate.ask(
            VoiceConfirmRequest(call: call, board: fixture.board), timeout: .seconds(30),
            present: { _, _ in nil })
        #expect(answer == .noWindow)
        #expect(!gate.isPending)
    }

    @Test("Voice may type into a terminal card the user made: Allow, and Ask after Confirm")
    func voiceTypesIntoUserTerminal() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        // A card with no live group: nothing starts, but the creator rule is
        // checked first, so the error shows which rule stopped the call.
        try fixture.board.add(title: "Shell", content: .terminal(groupID: TerminalGroupID()))
        let creatorError = "type only into terminals you created"
        fixture.board.setAgentControlMode(.allow)
        let allowed = await fixture.run("terminal_send", #"{"node_id":"Shell","text":"hi"}"#)
        #expect(!allowed.output.contains(creatorError))
        #expect(allowed.output.contains("no connected agent"))
        #expect(fixture.confirm.requests.isEmpty)
        fixture.board.setAgentControlMode(.ask)
        fixture.confirm.autoAnswer = .allowOnce
        let asked = await fixture.run("terminal_send", #"{"node_id":"Shell","text":"hi"}"#)
        #expect(!asked.output.contains(creatorError))
        #expect(fixture.confirm.requests.map(\.tool) == [.terminalSend])
        // An MCP agent keeps the creator rule.
        let card = try #require(fixture.board.cards.first { $0.title == "Shell" })
        let agent = CanvasAgentCaller(
            session: fixture.workspace, board: fixture.board, card: card,
            controllerID: UUID(), provider: "claude", sendMessage: { _, _ in .init() })
        var send = CanvasAgentToolCall(tool: .terminalSend)
        send.nodeID = card.id.rawValue.uuidString
        send.text = "hi"
        let refused = await CanvasAgentActions.perform(send, caller: agent)
        #expect(refused.error?.contains(creatorError) == true)
    }

    @Test("An unanswered card times out and nothing runs")
    func confirmTimeout() async throws {
        let fixture = try await VoiceFixture(confirmTimeout: .milliseconds(50))
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let outcome = await fixture.run("node_remove", #"{"node_id":"Review"}"#)
        #expect(outcome.output.contains("confirm_timeout"))
        #expect(fixture.board.cards.count == 2)
        #expect(fixture.confirm.dismissals == 1)
    }

    @Test("Allow runs a sensitive call with the badge and no card; Off denies it")
    func allowAndOffSensitive() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.board.setAgentControlMode(.off)
        let denied = await fixture.run("node_remove", #"{"node_id":"Review"}"#)
        #expect(denied.output.contains("agent_control_off"))
        fixture.board.setAgentControlMode(.allow)
        let removed = await fixture.run("node_remove", #"{"node_id":"Review"}"#)
        #expect(!removed.isError)
        #expect(fixture.board.cards.count == 1)
        #expect(fixture.confirm.requests.isEmpty)
        for name in ["handoff_to_agent", "work_order_create", "view_find", "plan_preview"] {
            #expect(
                await fixture.run(name).output.contains("needs_phase_2"), Comment(rawValue: name))
        }
    }

    @Test("Session grants: once for a removal, kept for other tools until close")
    func sessionGrants() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let gate = VoiceConfirmGate()
        let probe = ConfirmProbe()
        probe.autoAnswer = .allowForSession
        let export = try CanvasAgentToolCall.parse(tool: "export", arguments: ["format": "png"])
        let exportRequest = VoiceConfirmRequest(call: export, board: fixture.board)
        #expect(!exportRequest.isDestructive)
        #expect(await gate.ask(exportRequest, present: probe.presenter) == .allowForSession)
        let removal = try CanvasAgentToolCall.parse(
            tool: "node_remove", arguments: ["node_id": UUID().uuidString])
        let removalRequest = VoiceConfirmRequest(call: removal, board: fixture.board)
        #expect(await gate.ask(removalRequest, present: probe.presenter) == .allowOnce)
        #expect(!gate.isPending)

        try await fixture.openLatched()
        fixture.voice.grantForSession(exportRequest.grantKey)
        #expect(fixture.voice.hasSessionGrant(exportRequest.grantKey))
        await fixture.voice.close()
        #expect(!fixture.voice.hasSessionGrant(exportRequest.grantKey))
    }

    @Test("The card's buttons: Remove is destructive and never the default")
    func cardActions() throws {
        let fixture = VoiceConfirmCard.self
        let removal = try CanvasAgentToolCall.parse(
            tool: "edge_remove", arguments: ["edge_id": UUID().uuidString])
        let start = try CanvasAgentToolCall.parse(
            tool: "terminal_start", arguments: ["node_id": UUID().uuidString])
        let board = CanvasBoardState(document: CanvasDocument(title: "Cards"))
        let destructive = fixture.actions(
            for: VoiceConfirmRequest(call: removal, board: board), answer: { _ in })
        #expect(destructive.map(\.title) == ["Remove"])
        #expect(destructive.first?.isDestructive == true)
        #expect(RafuConfirmPopup.defaultActionIndex(destructive, preferred: "Remove") == nil)
        let plain = fixture.actions(
            for: VoiceConfirmRequest(call: start, board: board), answer: { _ in })
        #expect(plain.map(\.title) == ["Allow for This Session", "Allow Once"])
        #expect(RafuConfirmPopup.defaultActionIndex(plain, preferred: "Allow Once") == 1)
    }

    @Test("The rate limit applies to voice changes")
    func rateLimit() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        for _ in 0..<30 { _ = CanvasAgentCenter.shared.admit(fixture.voice.callerID) }
        let limited = await fixture.run("note_create", #"{"title":"Flood"}"#)
        #expect(limited.output.contains("rate_limited"))
        #expect(fixture.board.cards.count == 2)
        let read = await fixture.run("note_read", #"{"node_id":"Plan"}"#)
        #expect(!read.isError)
    }

    @Test("A voice change lands with the set-down ring and a Board effects row")
    func landingAndBoardLane() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = await fixture.run("note_create", #"{"title":"Landed"}"#)
        let card = try #require(fixture.board.cards.first { $0.title == "Landed" })
        #expect(fixture.board.landing?.ids == [card.id])
        let effect = try #require(fixture.voice.timeline.rows(lane: .board).last)
        #expect(effect.title == "Voice test")
        #expect(effect.detail == "1 added")
        _ = await fixture.run("node_update", #"{"node_id":"Plan","title":"Plan A"}"#)
        #expect(fixture.voice.timeline.rows(lane: .board).last?.detail == "1 changed")
    }

    @Test("Titles and \"this\" resolve; a shared prefix asks instead of guessing")
    func targets() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let written = await fixture.run(
            "note_write", #"{"node_id":"plan","mode":"append","text":"- step"}"#)
        #expect(!written.isError)
        let review = try #require(fixture.board.cards.first { $0.title == "Review" })
        fixture.board.select([review.id])
        let renamed = await fixture.run("node_update", #"{"node_id":"this","title":"Backend"}"#)
        #expect(!renamed.isError)
        #expect(fixture.board.cards.contains { $0.title == "Backend" })
        try fixture.board.add(title: "Plan two", content: .note(snapshot: ""))
        let ambiguous = await fixture.run("note_read", #"{"node_id":"Pla"}"#)
        #expect(ambiguous.output.contains("ambiguous"))
        let linked = await fixture.run(
            "edge_create", #"{"from":"Plan","to":"Backend","kind":"relationship"}"#)
        #expect(!linked.isError)
        #expect(fixture.board.connections.count == 1)
        #expect(
            fixture.board.notice?.message
                == "Rafu (voice): \(CanvasAgentTool.edgeCreate.actionTitle)")
    }

    @Test("Describe returns the whole board without terminal tails outside Allow")
    func describe() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let described = await fixture.run("ensemble_describe")
        let object = try json(described.output)
        #expect(object["ensemble"] as? String == "Voice test")
        #expect((object["nodes"] as? [Any])?.count == 2)
        #expect(object["persona"] as? String == "Rafu")
        #expect(object["terminal_tails"] == nil)
        let other = await fixture.run("ensemble_describe", #"{"ensemble":"voice"}"#)
        #expect(!other.isError)
        let missing = await fixture.run("ensemble_describe", #"{"ensemble":"Payments"}"#)
        #expect(missing.output.contains("not_found"))
    }

    @Test("Orchestrator tools read across windows")
    func orchestrator() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let list = try json(await fixture.run("list_ensembles").output)
        let open = try #require(list["open"] as? [[String: Any]])
        #expect(open.first?["title"] as? String == "Voice test")
        #expect(open.first?["visible"] as? Bool == true)
        let summary = try json(await fixture.run("cross_board_summary").output)
        #expect((summary["ensembles"] as? [Any])?.count == 1)
        let status = try json(await fixture.run("voice_status").output)
        #expect(status["backend"] as? String == "gpt-6.1-terra")
        #expect(status["ensemble"] as? String == "Voice test")
        let unknown = await fixture.run("rm_rf")
        #expect(unknown.output.contains("unknown_tool"))
        let bad = await fixture.run("note_create", "not json")
        #expect(bad.output.contains("invalid_arguments"))
    }

    @Test("voice_latch keeps the microphone open")
    func latchTool() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.voice.beginHold()
        try await until { fixture.voice.blobState == .listeningHeld }
        _ = await fixture.run("voice_latch")
        fixture.voice.endHold()
        #expect(fixture.voice.machine.mic == .latched)
        #expect(fixture.audio.isCapturing)
        await fixture.voice.close()
    }
}

// MARK: Argument cleanup, failure text and the debug transcript

@Suite("Voice arguments and debug transcript")
@MainActor
struct VoiceArgumentsAndTranscriptTests {
    @Test("Empty optional values go, agent names map, an absolute cwd in the root goes relative")
    func cleanedArguments() {
        let root = URL(fileURLWithPath: "/Users/me/project", isDirectory: true)
        let cleaned = VoiceToolExecutor.cleanedArguments(
            [
                "prompt": "", "title": "  ", "near": "", "cwd": NSNull(), "command": [String](),
                "agent": "Claude Code", "text": "",
            ], workspaceRoot: root)
        #expect(Set(cleaned.keys) == ["agent", "text"])
        #expect(cleaned["agent"] as? String == "claude")
        #expect(cleaned["text"] as? String == "")
        func cwd(_ value: String) -> String? {
            VoiceToolExecutor.cleanedArguments(["cwd": value], workspaceRoot: root)["cwd"]
                as? String
        }
        #expect(cwd("/Users/me/project") == ".")
        #expect(cwd("/Users/me/project/") == ".")
        #expect(cwd("/Users/me/project/sub/dir") == "sub/dir")
        #expect(cwd("/Users/me/project-two") == "/Users/me/project-two")
        #expect(cwd("/etc") == "/etc")
        #expect(cwd("src") == "src")
        let agents = ["claude-code", "Codex CLI", "cursor agent", "Claude", "my-tool"].map {
            VoiceToolExecutor.cleanedArguments(["agent": $0], workspaceRoot: nil)["agent"]
                as? String
        }
        #expect(agents == ["claude", "codex", "cursor-agent", "claude", "my-tool"])
        let unrooted = VoiceToolExecutor.cleanedArguments(["cwd": "/tmp"], workspaceRoot: nil)
        #expect(unrooted["cwd"] as? String == "/tmp")
    }

    @Test("Voice drops link always and x, y when both are zero, except for node_update")
    func cleanedArgumentsDropLinkAndZeroPosition() {
        let create = VoiceToolExecutor.cleanedArguments(
            ["agent": "claude", "link": true, "x": 0, "y": 0], workspaceRoot: nil,
            tool: "terminal_create")
        #expect(Set(create.keys) == ["agent"])
        let placed = VoiceToolExecutor.cleanedArguments(
            ["x": 0, "y": 240.5], workspaceRoot: nil, tool: "note_create")
        #expect(placed["x"] as? Int == 0)
        #expect(placed["y"] as? Double == 240.5)
        let moved = VoiceToolExecutor.cleanedArguments(
            ["node_id": "a", "x": 0, "y": 0.0], workspaceRoot: nil, tool: "node_update")
        #expect(Set(moved.keys) == ["node_id", "x", "y"])
        let linkOff = VoiceToolExecutor.cleanedArguments(["link": false], workspaceRoot: nil)
        #expect(linkOff.isEmpty)
    }

    @Test("terminal_create with the backend's empty fields and \"Claude Code\" is accepted")
    func terminalCreateFromVoice() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        fixture.board.setAgentControlMode(.allow)
        let outcome = await CanvasTerminalStarter.$confirmSteps.withValue(1) {
            await fixture.run(
                "terminal_create",
                #"{"agent":"Claude Code","title":"Claude","prompt":"","near":"","cwd":null,"command":[]}"#
            )
        }
        #expect(!outcome.output.contains("invalid_arguments"), Comment(rawValue: outcome.output))
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        #expect(fixture.board.cards.contains { $0.title == "Claude" })
    }

    @Test("A failed call shows its code and Rafu's message on the timeline")
    func failureMessageOnTimeline() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_w","name":"node_update","arguments":"{\"node_id\":\"Plan\",\"width\":5}"}}}"#
        )
        try await until("output") {
            !fixture.transport.sent(type: "response.item.create").isEmpty
        }
        let row = try #require(fixture.voice.timeline.rows(lane: .tool).first)
        #expect(row.detail.hasPrefix(#"invalid_arguments: Invalid value for "width""#))
        await fixture.voice.close()
    }

    @Test("No debug transcript unless the user turns it on")
    func transcriptOffByDefault() async throws {
        let folder = TranscriptFolder()
        let fixture = try await VoiceFixture(transcriptDirectory: folder.url)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"note_create","arguments":"{\"title\":\"Ideas\"}"}}}"#
        )
        try await until("output") {
            !fixture.transport.sent(type: "response.item.create").isEmpty
        }
        await fixture.voice.close()
        #expect(fixture.voice.lastDebugTranscript == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test("The debug transcript keeps turns and calls, never the key, in a 0600 file")
    func transcriptOn() async throws {
        let folder = TranscriptFolder()
        let fixture = try await VoiceFixture(
            key: VoiceDebugTranscriptTests.fakeKey, transcriptDirectory: folder.url)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        UserDefaults(suiteName: fixture.suite)?.set(
            true, forKey: VoicePreferences.debugTranscriptKey)
        try await fixture.openLatched()
        fixture.transport.push(#"{"type":"session.input_transcript.delta","delta":"start a "}"#)
        fixture.transport.push(#"{"type":"session.input_transcript.delta","delta":"note"}"#)
        fixture.transport.push(
            #"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"note_create","arguments":"{\"title\":\"Ideas\"}"}}}"#
        )
        try await until("output") {
            !fixture.transport.sent(type: "response.item.create").isEmpty
        }
        fixture.transport.push(#"{"type":"session.output_transcript.delta","delta":"Done."}"#)
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.completed","response":{}}}"#)
        try await until("response.create") {
            !fixture.transport.sent(type: "response.create").isEmpty
        }
        await fixture.voice.close()
        let transcript = try #require(fixture.voice.lastDebugTranscript)
        await transcript.drained()
        let text = try String(contentsOf: transcript.fileURL, encoding: .utf8)
        #expect(!text.contains(VoiceDebugTranscriptTests.fakeKey))
        #expect(!text.contains("Authorization"))
        let lines = try VoiceDebugTranscriptTests.lines(transcript.fileURL)
        let types = lines.compactMap { $0["type"] as? String }
        for type in [
            "session_opened", "session_started", "user_said", "delegation", "call", "call_result",
            "rafu_said", "session_closed",
        ] {
            #expect(types.contains(type), Comment(rawValue: type))
        }
        #expect(
            lines.first { $0["type"] as? String == "user_said" }?["text"] as? String
                == "start a note")
        let call = try #require(lines.first { $0["type"] as? String == "call" })
        #expect(call["arguments"] as? String == #"{"title":"Ideas"}"#)
        let result = try #require(lines.first { $0["type"] as? String == "call_result" })
        #expect(result["summary"] as? String == "ok")
        #expect(result["is_error"] as? Bool == false)
        #expect(try VoiceDebugTranscriptTests.mode(transcript.fileURL) == 0o600)
    }

    // MARK: Transcript turns and remote close

    /// Opens a latched session with the debug transcript on.
    private func transcriptFixture() async throws -> (VoiceFixture, TranscriptFolder) {
        let folder = TranscriptFolder()
        let fixture = try await VoiceFixture(transcriptDirectory: folder.url)
        UserDefaults(suiteName: fixture.suite)?.set(
            true, forKey: VoicePreferences.debugTranscriptKey)
        try await fixture.openLatched()
        return (fixture, folder)
    }

    /// Waits until every pushed event ran (an error marker is the last one),
    /// closes, and returns the `user_said` / `rafu_said` lines in file order.
    private func spoken(_ fixture: VoiceFixture) async throws -> [(String, String)] {
        fixture.transport.push(#"{"type":"error","error":{"code":"marker","message":"m"}}"#)
        try await until("marker") { fixture.voice.lastError == "GPT-Live error marker" }
        await fixture.voice.close()
        let transcript = try #require(fixture.voice.lastDebugTranscript)
        await transcript.drained()
        return try VoiceDebugTranscriptTests.lines(transcript.fileURL).compactMap { line in
            guard let type = line["type"] as? String, type == "user_said" || type == "rafu_said",
                let text = line["text"] as? String
            else { return nil }
            return (type, text)
        }
    }

    @Test("The transcript keeps turns in speaking order: user, Rafu, user, Rafu")
    func transcriptOrder() async throws {
        let (fixture, folder) = try await transcriptFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let transport = fixture.transport
        transport.push(
            #"{"type":"session.input_transcript.delta","delta":"start a ","start_ms":0,"end_ms":300}"#
        )
        transport.push(
            #"{"type":"session.input_transcript.delta","delta":"note","start_ms":300,"end_ms":600}"#
        )
        transport.push(#"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        transport.push(
            #"{"type":"session.output_transcript.delta","delta":"Done. ","start_ms":1000,"end_ms":1300}"#
        )
        transport.push(
            #"{"type":"session.output_transcript.delta","delta":"It is ready.","start_ms":1300,"end_ms":1700}"#
        )
        transport.push(
            #"{"type":"response.event","event":{"type":"response.completed","response":{}}}"#)
        transport.push(
            #"{"type":"session.input_transcript.delta","delta":"thanks","start_ms":5000,"end_ms":5400}"#
        )
        transport.push(#"{"type":"session.delegation.created","delegation":{"id":"del_2"}}"#)
        transport.push(
            #"{"type":"session.output_transcript.delta","delta":"You are welcome.","start_ms":6000,"end_ms":6500}"#
        )
        let lines = try await spoken(fixture)
        #expect(lines.map(\.0) == ["user_said", "rafu_said", "user_said", "rafu_said"])
        #expect(
            lines.map(\.1) == ["start a note", "Done. It is ready.", "thanks", "You are welcome."])
    }

    @Test("A long pause inside one stream starts a new turn")
    func transcriptGaps() async throws {
        let (fixture, folder) = try await transcriptFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let transport = fixture.transport
        for (delta, start, end) in [
            ("one", 0, 400), ("two", 2_000, 2_400), ("three", 2_500, 2_800),
        ] {
            transport.push(
                #"{"type":"session.input_transcript.delta","delta":"\#(delta)","start_ms":\#(start),"end_ms":\#(end)}"#
            )
        }
        for (delta, start, end) in [("a", 0, 300), ("b", 1_600, 1_900), ("c", 2_000, 2_200)] {
            transport.push(
                #"{"type":"session.output_transcript.delta","delta":"\#(delta)","start_ms":\#(start),"end_ms":\#(end)}"#
            )
        }
        let lines = try await spoken(fixture)
        #expect(lines.filter { $0.0 == "user_said" }.map(\.1) == ["one", "twothree"])
        #expect(lines.filter { $0.0 == "rafu_said" }.map(\.1) == ["a", "bc"])
    }

    @Test("Reply words that arrive after response.completed stay in the same reply")
    func transcriptReplyTail() async throws {
        let (fixture, folder) = try await transcriptFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let transport = fixture.transport
        var loud = Data()
        for _ in 0..<2_400 { loud.append(contentsOf: [0x00, 0x10]) }
        transport.push(
            #"{"type":"session.output_audio.delta","delta":"\#(loud.base64EncodedString())"}"#)
        transport.push(#"{"type":"session.output_transcript.delta","delta":"Done."}"#)
        transport.push(
            #"{"type":"response.event","event":{"type":"response.completed","response":{}}}"#)
        transport.push(#"{"type":"session.output_transcript.delta","delta":" Tail."}"#)
        let lines = try await spoken(fixture)
        #expect(lines.map(\.1) == ["Done. Tail."])
    }

    @Test("A server close shows its reason as an error; the user's own close does not")
    func remoteCloseReason() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        fixture.transport.push(#"{"type":"session.closed","reason":"expired"}"#)
        let message = "The voice service closed the session (expired)."
        try await until("error") { fixture.voice.blobState == .error(message) }
        #expect(fixture.voice.lastError == message)
        fixture.voice.dismissError()
        #expect(fixture.voice.blobState == .idle)

        let quiet = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(quiet.suite) }
        try await quiet.openLatched()
        quiet.transport.push(#"{"type":"session.closed","reason":"close_requested"}"#)
        try await until("closed") { quiet.voice.blobState == .idle }
        #expect(quiet.voice.lastError == nil)
    }

    @Test("The close message cuts a long or odd reason to 40 plain characters")
    func remoteCloseMessage() {
        #expect(VoiceSession.remoteCloseMessage("user") == nil)
        #expect(VoiceSession.remoteCloseMessage("close_requested") == nil)
        #expect(VoiceSession.remoteCloseMessage(nil) == "The voice service closed the session.")
        let long = VoiceSession.remoteCloseMessage(String(repeating: "x", count: 90) + "\n<b>")
        #expect(
            long == "The voice service closed the session (\(String(repeating: "x", count: 40))).")
        #expect(
            VoiceSession.remoteCloseMessage("bad\n<script>")
                == "The voice service closed the session (badscript).")
    }
}

// MARK: Turns Rafu did not hear

/// A held or latched turn that got no reply must not leave the blob on
/// Thinking with the microphone off (the first-press "stuck on Thinking").
@Suite("Voice silent turns")
@MainActor
struct VoiceSilentTurnTests {
    private static var silence: Data { Data(count: VoiceAudioFormat.inputFrameBytes) }

    /// 480 samples at 0x2000: about 8,200 RMS, well above the speech level.
    private static var speech: Data {
        var frame = Data()
        for _ in 0..<VoiceAudioFormat.inputFrameSamples { frame.append(contentsOf: [0x00, 0x20]) }
        return frame
    }

    /// A fixture with the debug transcript on.
    private func fixture(
        transport: ScriptedLiveTransport = ScriptedLiveTransport()
    ) async throws -> (VoiceFixture, TranscriptFolder) {
        let folder = TranscriptFolder()
        let fixture = try await VoiceFixture(transport: transport, transcriptDirectory: folder.url)
        UserDefaults(suiteName: fixture.suite)?.set(
            true, forKey: VoicePreferences.debugTranscriptKey)
        return (fixture, folder)
    }

    /// Holds after the connect, sends `frames`, and releases.
    private func hold(_ fixture: VoiceFixture, frames: [Data]) async throws {
        let voice = fixture.voice
        voice.beginHold()
        try await until("listening") { voice.blobState == .listeningHeld }
        for frame in frames { fixture.audio.push(frame) }
        try await until("frames") {
            fixture.transport.sent(type: "session.input_audio.append").count >= frames.count
        }
        voice.endHold()
        #expect(voice.blobState == .thinking)
    }

    private func transcriptLines(_ fixture: VoiceFixture) async throws -> [[String: Any]] {
        await fixture.voice.close()
        let transcript = try #require(fixture.voice.lastDebugTranscript)
        await transcript.drained()
        return try VoiceDebugTranscriptTests.lines(transcript.fileURL)
    }

    private func rows(_ voice: VoiceSession, _ title: String) -> [VoiceTimelineEvent] {
        voice.timeline.rows(lane: .voice).filter { $0.title == title }
    }

    @Test("A held turn with no speech goes to Paused with a hint, one row and one silent_turn")
    func silentHeldTurn() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        try await hold(fixture, frames: Array(repeating: Self.silence, count: 3))
        await voice.audioSender?.value
        #expect(voice.blobState == .paused)
        #expect(!voice.isMicOpen)
        #expect(voice.hint == VoiceSession.silentTurnHint)
        let row = try #require(rows(voice, "Rafu did not hear you").first)
        #expect(rows(voice, "Rafu did not hear you").count == 1)
        #expect(row.detail == VoiceSession.silentTurnHint)
        // The next press clears the hint. The session closes while held, so
        // this second stream never decides anything.
        voice.beginHold()
        #expect(voice.hint == nil)
        let lines = try await transcriptLines(fixture)
        let silent = lines.filter { $0["type"] as? String == "silent_turn" }
        #expect(silent.count == 1)
        #expect(silent.first?["frames"] as? Int == 3)
        #expect(silent.first?["max_rms"] as? Int == 0)
        #expect(silent.first?["held_ms"] is Int)
        let turn = try #require(lines.first { $0["type"] as? String == "turn_audio" })
        #expect(turn["held"] as? Bool == true)
        #expect(turn["heard_speech"] as? Bool == false)
        #expect(turn["frames"] as? Int == 3)
        #expect(turn["loud_frames"] as? Int == 0)
        #expect(turn["buffered_before_start"] as? Int == 0)
        #expect(turn["unmute_ms"] is Int)
        #expect(turn["mute_ms"] is Int)
        let engine = try #require(lines.first { $0["type"] as? String == "audio_engine" })
        #expect(engine["input_channels"] as? Int == 9)
        #expect(engine["start_ms"] as? Int == 42)
        // No words in any diagnostic line.
        for line in lines {
            let type = line["type"] as? String ?? ""
            guard ["turn_audio", "silent_turn", "audio_engine"].contains(type) else { continue }
            #expect(line["text"] == nil)
        }
    }

    @Test("A held turn with speech stays on Thinking; with no server event it pauses after 8 s")
    func spokenTurnTimesOut() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        try await hold(fixture, frames: Array(repeating: Self.speech, count: 3))
        await voice.audioSender?.value
        #expect(voice.blobState == .thinking)
        #expect(voice.hint == nil)
        voice.tick(at: voice.sessionElapsed + .seconds(5))
        #expect(voice.blobState == .thinking)
        voice.tick(at: voice.sessionElapsed + .seconds(9))
        #expect(voice.blobState == .paused)
        #expect(voice.hint == VoiceSession.silentTurnHint)
        #expect(rows(voice, "Rafu did not hear anything").count == 1)
        #expect(rows(voice, "Rafu did not hear you").isEmpty)
        let lines = try await transcriptLines(fixture)
        let turn = try #require(lines.first { $0["type"] as? String == "turn_audio" })
        #expect(turn["heard_speech"] as? Bool == true)
        #expect(turn["loud_frames"] as? Int == 3)
        #expect((turn["max_rms"] as? Int ?? 0) > Int(VoiceAudioFormat.localSpeechRMS))
        let timeout = try #require(lines.first { $0["type"] as? String == "no_response" })
        #expect(timeout["had_delegation"] as? Bool == false)
        #expect((timeout["after_ms"] as? Int ?? 0) >= 9_000)
        #expect(!lines.contains { $0["type"] as? String == "silent_turn" })
    }

    @Test("Frames said while connecting and released before the start: Paused, no silent row")
    func releasedWhileConnecting() async throws {
        let transport = ScriptedLiveTransport(answersStart: false)
        let (fixture, folder) = try await fixture(transport: transport)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        voice.beginHold()
        try await until("capturing") { fixture.audio.isCapturing }
        fixture.audio.push(Self.silence)
        fixture.audio.push(Self.silence)
        voice.endHold()
        try await until("start sent") { !transport.sent(type: "session.start").isEmpty }
        transport.push(#"{"type":"session.started","session":{"id":"sess_late"}}"#)
        try await until("mute") { !transport.sent(type: "session.input_audio.mute").isEmpty }
        await voice.audioSender?.value
        #expect(voice.blobState == .paused)
        #expect(voice.hint == nil)
        #expect(rows(voice, "Rafu did not hear you").isEmpty)
        let lines = try await transcriptLines(fixture)
        let turn = try #require(lines.first { $0["type"] as? String == "turn_audio" })
        #expect(turn["buffered_before_start"] as? Int == 2)
        #expect(turn["frames"] as? Int == 2)
        #expect(!lines.contains { $0["type"] as? String == "silent_turn" })
    }

    @Test("A server transcript during the hold stops the silent rule")
    func serverHeardTheTurn() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        voice.beginHold()
        try await until("listening") { voice.blobState == .listeningHeld }
        for _ in 0..<3 { fixture.audio.push(Self.silence) }
        fixture.transport.push(#"{"type":"session.input_transcript.delta","delta":"hey"}"#)
        try await until("you row") { !voice.timeline.rows(lane: .you).isEmpty }
        voice.endHold()
        await voice.audioSender?.value
        #expect(voice.blobState == .thinking)
        #expect(voice.hint == nil)
        #expect(rows(voice, "Rafu did not hear you").isEmpty)
        await voice.close()
    }

    @Test("A latched stream never triggers the silent rule")
    func latchedStream() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        try await fixture.openLatched()
        for _ in 0..<3 { fixture.audio.push(Self.silence) }
        fixture.transport.push(
            #"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        try await until("thinking") { voice.blobState == .thinking }
        voice.toggleLatched()
        #expect(!voice.isMicOpen)
        await voice.audioSender?.value
        #expect(voice.blobState == .thinking)
        #expect(voice.hint == nil)
        #expect(rows(voice, "Rafu did not hear you").isEmpty)
        await voice.close()
    }

    @Test("After a delegation the limit is 20 s, and the row says No reply")
    func delegationExtendsLimit() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        try await hold(fixture, frames: Array(repeating: Self.speech, count: 3))
        await voice.audioSender?.value
        fixture.transport.push(
            #"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        try await until("delegation") { !voice.timeline.rows(lane: .delegation).isEmpty }
        #expect(voice.blobState == .thinking)
        voice.tick(at: voice.sessionElapsed + .seconds(9))
        #expect(voice.blobState == .thinking)
        voice.tick(at: voice.sessionElapsed + .seconds(21))
        #expect(voice.blobState == .paused)
        #expect(voice.hint == VoiceSession.noReplyHint)
        #expect(rows(voice, "No reply").count == 1)
        // A late reply still plays and clears the hint.
        var loud = Data()
        for _ in 0..<2_400 { loud.append(contentsOf: [0x00, 0x10]) }
        fixture.transport.push(
            #"{"type":"session.output_audio.delta","delta":"\#(loud.base64EncodedString())"}"#)
        try await until("speaking") { voice.blobState == .speaking }
        #expect(voice.hint == nil)
        let lines = try await transcriptLines(fixture)
        let timeout = try #require(lines.first { $0["type"] as? String == "no_response" })
        #expect(timeout["had_delegation"] as? Bool == true)
    }

    @Test("A waiting card and a running call hold the limit; the confirmed path then times out")
    func confirmHoldsTheLimit() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        let voice = fixture.voice
        try await fixture.openLatched()
        fixture.transport.push(
            #"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        fixture.transport.push(
            #"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"node_remove","arguments":"{\"node_id\":\"Review\"}"}}}"#
        )
        try await until("card") { voice.confirmGate.isPending }
        #expect(voice.blobState == .needsConfirm)
        voice.tick(at: voice.sessionElapsed + .seconds(30))
        #expect(voice.blobState == .needsConfirm)
        fixture.confirm.click(.cancel)
        try await until("output") {
            !fixture.transport.sent(type: "response.item.create").isEmpty
        }
        try await until("call done") { voice.runningCalls == 0 }
        #expect(voice.blobState == .thinking)
        voice.tick(at: voice.sessionElapsed + .seconds(9))
        #expect(voice.blobState == .thinking)
        voice.tick(at: voice.sessionElapsed + .seconds(21))
        #expect(voice.blobState == .listeningLatched)
        #expect(rows(voice, "No reply").count == 1)
        await voice.close()
    }

    @Test("A capture that does not start is retried once on a fresh engine")
    func captureRetry() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        fixture.audio.failingCaptureStarts = 1
        try await fixture.openLatched()
        #expect(fixture.audio.isCapturing)
        #expect(fixture.audio.playbackStarts == 2)
        #expect(rows(fixture.voice, "Microphone did not start").isEmpty)
        await fixture.voice.close()
    }

    @Test("A capture that fails twice shows a row and a capture_failed entry")
    func captureFails() async throws {
        let (fixture, folder) = try await fixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        _ = folder
        fixture.audio.failingCaptureStarts = 2
        try await fixture.openLatched()
        #expect(!fixture.audio.isCapturing)
        #expect(rows(fixture.voice, "Microphone did not start").count == 1)
        let lines = try await transcriptLines(fixture)
        let failure = try #require(lines.first { $0["type"] as? String == "capture_failed" })
        #expect((failure["domain"] as? String)?.contains("VoiceAudioError") == true)
        #expect(failure["code"] is Int)
        #expect(lines.count(where: { $0["type"] as? String == "audio_engine" }) == 2)
    }
}

// MARK: Agent updates

/// Stands in for the hook store: one counter to observe and the signals.
@MainActor
@Observable
private final class FakeAgentActivity {
    var revision = 0
    @ObservationIgnored var signals: [VoiceAgentSignal] = []
    /// How often the session read the signals: a scan happened.
    @ObservationIgnored private(set) var signalReads = 0

    var source: VoiceAgentActivitySource {
        VoiceAgentActivitySource(
            revision: { self.revision },
            signals: { _ in
                self.signalReads += 1
                return self.signals
            })
    }

    /// The agent's state changed: new signals, and the counter moves.
    func publish(_ signals: [VoiceAgentSignal]) {
        self.signals = signals
        revision += 1
    }

    static func signal(
        _ card: String, title: String = "Build", agent: String = "Claude Code",
        state: AgentSessionState, reply: UUID? = nil, row: UUID = UUID(), preview: String? = nil
    ) -> VoiceAgentSignal {
        VoiceAgentSignal(
            cardID: card, title: title, agent: agent, sessionRowID: row, state: state,
            replyEventID: reply, preview: preview)
    }
}

@Suite("Voice agent updates in a session")
@MainActor
struct VoiceAgentUpdateSessionTests {
    private func commentary(_ fixture: VoiceFixture) throws -> [String] {
        try fixture.transport.sent(type: "session.commentary.append").map {
            try #require(try json($0)["content"] as? String)
        }
    }

    @Test("A reply gives exactly one commentary, after the quiet gate")
    func replySpeaksOnce() async throws {
        let fake = FakeAgentActivity()
        let row = UUID()
        fake.signals = [FakeAgentActivity.signal("n1", state: .working, row: row)]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        #expect(voice.isObservingAgents)
        fake.publish([
            FakeAgentActivity.signal(
                "n1", state: .finished, reply: UUID(), row: row,
                preview: "Fixed the login bug. Added a test.")
        ])
        try await until("queued") { voice.queuedAgentUpdates == 1 }
        // The session just opened: local speech is too recent.
        #expect(fixture.transport.sent(type: "session.commentary.append").isEmpty)
        voice.tick(at: .seconds(5))
        try await until("commentary") {
            fixture.transport.sent(type: "session.commentary.append").count == 1
        }
        #expect(voice.queuedAgentUpdates == 0)
        voice.tick(at: .seconds(6))
        voice.tick(at: .seconds(30))
        await voice.close()
        let spoken = try commentary(fixture)
        #expect(spoken == ["Claude Code in “Build” is done. It says: Fixed the login bug."])
        // No backend turn and no instruction.
        #expect(fixture.transport.sent(type: "response.create").isEmpty)
        #expect(fixture.transport.sent(type: "session.instructions.append").isEmpty)
        let row1 = voice.timeline.rows(lane: .board).first { $0.title == "Agent update" }
        #expect(row1?.detail.contains("Claude Code in") == true)
    }

    @Test("A reply that existed when the session opened is not announced")
    func baseline() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [FakeAgentActivity.signal("n1", state: .finished, reply: UUID())]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        try await fixture.openLatched()
        // The same reply seen again (the counter moved for another card).
        let readsBefore = fake.signalReads
        fake.publish(fake.signals)
        try await until("scanned") { fake.signalReads > readsBefore }
        fixture.voice.tick(at: .seconds(5))
        #expect(fixture.voice.queuedAgentUpdates == 0)
        await fixture.voice.close()
        #expect(fixture.transport.sent(type: "session.commentary.append").isEmpty)
    }

    @Test("Approval and waiting are spoken; two agents share one sentence")
    func coalescesTwoAgents() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [
            FakeAgentActivity.signal("n1", state: .working),
            FakeAgentActivity.signal("n2", title: "Tests", agent: "Codex", state: .working),
        ]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        fake.publish([
            FakeAgentActivity.signal("n1", state: .finished, reply: UUID()),
            FakeAgentActivity.signal(
                "n2", title: "Tests", agent: "Codex", state: .waitingForPermission),
        ])
        try await until("queued") { voice.queuedAgentUpdates == 2 }
        voice.tick(at: .seconds(5))
        try await until("commentary") {
            fixture.transport.sent(type: "session.commentary.append").count == 1
        }
        await voice.close()
        #expect(
            try commentary(fixture)
                == ["Claude Code in “Build” is done. Codex in “Tests” needs your approval."])
    }

    @Test("No update while a Confirm card waits")
    func heldByConfirm() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [FakeAgentActivity.signal("n1", state: .working)]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        let call = Task { await fixture.run("node_remove", #"{"node_id":"Review"}"#) }
        try await until("card") { fixture.confirm.requests.count == 1 }
        fake.publish([FakeAgentActivity.signal("n1", state: .finished, reply: UUID())])
        try await until("queued") { voice.queuedAgentUpdates == 1 }
        voice.tick(at: .seconds(5))
        #expect(voice.queuedAgentUpdates == 1)
        #expect(fixture.transport.sent(type: "session.commentary.append").isEmpty)
        fixture.confirm.click(.cancel)
        _ = await call.value
        await voice.close()
        #expect(fixture.transport.sent(type: "session.commentary.append").isEmpty)
    }

    @Test("No update while local speech is heard; it waits for a later tick")
    func heldBySpeech() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [FakeAgentActivity.signal("n1", state: .working)]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        var speech = Data()
        for _ in 0..<VoiceAudioFormat.inputFrameSamples { speech.append(contentsOf: [0x00, 0x20]) }
        let frames = VoiceAudioFormat.localSpeechFrames + 1
        for _ in 0..<frames { fixture.audio.push(speech) }
        try await until("frames") {
            fixture.transport.sent(type: "session.input_audio.append").count == frames
        }
        fake.publish([FakeAgentActivity.signal("n1", state: .finished, reply: UUID())])
        try await until("queued") { voice.queuedAgentUpdates == 1 }
        // The speech was noted a moment ago: this instant is inside 1.5 s of it.
        voice.tick(at: voice.sessionElapsed)
        #expect(voice.queuedAgentUpdates == 1)
        voice.tick(at: voice.sessionElapsed + .seconds(5))
        #expect(voice.queuedAgentUpdates == 0)
        try await until("commentary") {
            fixture.transport.sent(type: "session.commentary.append").count == 1
        }
        await voice.close()
    }

    @Test("Settings off: nothing is said and the queue is dropped")
    func toggledOff() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [FakeAgentActivity.signal("n1", state: .working)]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        UserDefaults(suiteName: fixture.suite)?.set(false, forKey: VoicePreferences.agentUpdatesKey)
        try await fixture.openLatched()
        let readsBefore = fake.signalReads
        fake.publish([FakeAgentActivity.signal("n1", state: .finished, reply: UUID())])
        // The observer read the change; with the setting off it drops the news.
        try await until("scanned") { fake.signalReads > readsBefore }
        voice.tick(at: .seconds(5))
        #expect(voice.queuedAgentUpdates == 0)
        await voice.close()
        #expect(fixture.transport.sent(type: "session.commentary.append").isEmpty)
    }

    @Test("Close stops the observer; a later change queues nothing")
    func closeStopsObserving() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [FakeAgentActivity.signal("n1", state: .working)]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        #expect(voice.isObservingAgents)
        await voice.close()
        #expect(!voice.isObservingAgents)
        fake.publish([FakeAgentActivity.signal("n1", state: .finished, reply: UUID())])
        await Task.yield()
        await Task.yield()
        #expect(voice.queuedAgentUpdates == 0)
        #expect(fixture.transport.sent(type: "session.commentary.append").isEmpty)
    }

    @Test("A spoken update does not hold the session open")
    func updateDoesNotResetIdleClock() async throws {
        let fake = FakeAgentActivity()
        fake.signals = [FakeAgentActivity.signal("n1", state: .working)]
        let fixture = try await VoiceFixture(agentActivity: fake.source)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let voice = fixture.voice
        try await fixture.openLatched()
        fake.publish([FakeAgentActivity.signal("n1", state: .finished, reply: UUID())])
        try await until("queued") { voice.queuedAgentUpdates == 1 }
        voice.tick(at: .seconds(5))
        try await until("commentary") {
            fixture.transport.sent(type: "session.commentary.append").count == 1
        }
        // The server speaks the update.
        var loud = Data()
        for _ in 0..<2_400 { loud.append(contentsOf: [0x00, 0x10]) }
        fixture.transport.push(
            #"{"type":"session.output_audio.delta","delta":"\#(loud.base64EncodedString())"}"#)
        try await until("speaking") { voice.blobState == .speaking }
        // 90 s after the open, with no word from the user: the session closes.
        voice.tick(at: .seconds(90))
        try await until("closed") { voice.blobState == .idle }
    }
}
