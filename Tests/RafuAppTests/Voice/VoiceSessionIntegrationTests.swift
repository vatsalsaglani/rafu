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

    var isCapturing: Bool { continuation != nil }

    func startCapture() throws -> AsyncStream<Data> {
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

    func startPlayback() throws { playing = true }
    func enqueue(_ pcm: Data) { enqueued += 1 }
    func flush() { flushes += 1 }
    func stopAll() { playing = false }

    func push(_ frame: Data) { continuation?.yield(frame) }
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
    let voice: VoiceSession
    let suite: String
    private let scratch = VoiceScratchFolder()

    init(
        key: String? = "test-key", microphone: Bool = true, capDollars: Int? = nil,
        transport: ScriptedLiveTransport = ScriptedLiveTransport()
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
        #expect(fixture.voice.timeline.events.isEmpty)
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

    @Test("Sensitive tools answer needs_phase_2 in Ask and Allow")
    func sensitiveWaits() async throws {
        let fixture = try await VoiceFixture()
        defer { TestDefaultsSuite.remove(fixture.suite) }
        for mode in [CanvasAgentControlMode.ask, .allow] {
            fixture.board.setAgentControlMode(mode)
            let removal = await fixture.run("node_remove", #"{"node_id":"Review"}"#)
            #expect(removal.output.contains("needs_phase_2"), "\(mode)")
            let start = await fixture.run(
                "terminal_create", #"{"title":"Agent","agent":"claude"}"#)
            #expect(start.output.contains("needs_phase_2"), "\(mode)")
        }
        #expect(fixture.board.cards.count == 2)
        for name in ["handoff_to_agent", "work_order_create", "view_find", "voice_confirm"] {
            #expect(
                await fixture.run(name).output.contains("needs_phase_2"), Comment(rawValue: name))
        }
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
