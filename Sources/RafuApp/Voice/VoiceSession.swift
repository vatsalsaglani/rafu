import Foundation
import Observation
import RafuCore

/// Why a voice session closed.
enum VoiceCloseReason: Equatable {
    case user
    case idle
    case remote
    case failure
}

/// Rafu Voice: one GPT-Live session at a time, app-wide. Idle Rafu holds no
/// socket, no engine, no task and no timer; everything below is created by
/// the first key press or blob click and released by `close`.
///
/// Observation exposes small metadata only. The key, audio and transcripts
/// never reach observable state (the timeline keeps at most 120 scalars of
/// the user's own words, in memory, cleared on close).
@MainActor
@Observable
final class VoiceSession {
    static let shared = VoiceSession()

    /// Seams for tests: no network, no microphone, no Keychain.
    struct Dependencies {
        var makeTransport: (_ apiKey: String) -> any VoiceLiveTransport
        var openAIKey: () async throws -> String
        var requestMicrophone: () async -> Bool
        var makeAudio: () -> (any VoiceAudioCapturing, any VoiceAudioPlaying)
        var preferences: VoicePreferences
        var costSuiteName: String?
        /// `nil` resolves the key workspace window through the registry.
        var target: (() -> VoiceTarget?)?
        var workspaces: (() -> [WorkspaceSession])?
        var startTimeout: Duration = .seconds(10)
        var closeTimeout: Duration = .seconds(15)
        /// The Confirm card for a sensitive call. Tests answer it themselves.
        var presentConfirm: VoiceConfirmPresenter = { request, answer in
            VoiceConfirmCard.present(request, answer: answer)
        }
        var confirmTimeout: Duration = VoiceConfirmGate.timeout
        /// With the microphone off and nothing audible for this long, a
        /// session that is not latched stops its audio engine, so the macOS
        /// microphone indicator goes out. The next key press restarts it.
        var engineIdleAfter: Duration = .seconds(10)
        /// Off in tests, which drive `tick(at:)` directly.
        var runsClock = true
        /// The generated-view card implementation (`show_view`). Tests give a
        /// double instead of the process-wide registry.
        var viewHost: @MainActor () -> (any GeneratedViewHost)? = {
            GeneratedViewHostRegistry.shared.host
        }

        static var live: Dependencies {
            Dependencies(
                makeTransport: { URLSessionWebSocketTransport(apiKey: $0) },
                openAIKey: { try await VoiceKeyResolver.openAIKey() },
                requestMicrophone: { await VoiceMicrophonePermission.request() },
                makeAudio: {
                    let audio = VoiceAudioIO()
                    return (audio, audio)
                },
                preferences: VoicePreferences(), costSuiteName: nil)
        }
    }

    // MARK: Observable metadata

    private(set) var machine = VoiceBlobMachine()
    private(set) var personaName = VoicePersona.rafu.name
    private(set) var activeBoardID: CanvasID?
    /// 0…1, written at most about 17 times a second while capturing.
    private(set) var inputLevel = 0.0
    private(set) var timeline = VoiceTimeline()
    private(set) var lastError: String?
    let costStore: VoiceCostStore

    var blobState: VoiceBlobState { machine.state }
    var isMicOpen: Bool { machine.isMicOpen }

    // MARK: Session resources (none while idle)

    @ObservationIgnored let callerID = UUID()
    @ObservationIgnored let undoLedger = VoiceUndoLedger()
    @ObservationIgnored let confirmGate = VoiceConfirmGate()
    /// "Allow for This Session" grants: tool and Ensemble. Cleared on close.
    @ObservationIgnored private var sessionGrants: Set<String> = []
    /// Backend turns (`session.delegation.created`) in this session. A spoken
    /// `voice_confirm` counts only in a later turn than the card's, so the
    /// backend can never confirm its own call (ADR 0035, decision 9).
    @ObservationIgnored private var delegationCount = 0
    @ObservationIgnored private var cardDelegationIndex = 0
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var client: VoiceLiveClient?
    /// Kept for `terminateNow`, which cannot wait for the client actor.
    @ObservationIgnored private var transport: (any VoiceLiveTransport)?
    @ObservationIgnored private var capture: (any VoiceAudioCapturing)?
    @ObservationIgnored private var playback: (any VoiceAudioPlaying)?
    /// Capture streams not yet handed to a sender (while connecting). A
    /// second press during the connect adds a stream; none is dropped.
    @ObservationIgnored private var pendingFrames: [AsyncStream<Data>] = []
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var callChain: Task<Void, Never>?
    @ObservationIgnored private var startWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var startErrorCode: String?
    @ObservationIgnored private var streamEndedBeforeStart = false
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isClosing = false
    /// Bumped by every open and close, so a stale async step drops its result.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openedAt = ContinuousClock.now
    @ObservationIgnored private var clock = VoiceActivityClock()
    @ObservationIgnored private var inFlightCalls = 0
    @ObservationIgnored private var outputsAwaitingCreate = 0
    @ObservationIgnored private var completedWhileInFlight = false
    @ObservationIgnored private var lastAudibleAt: Duration?
    /// The engine was stopped after a quiet spell (`engineIdleAfter`).
    @ObservationIgnored private(set) var isEngineSuspended = false
    @ObservationIgnored private var lastEngineUse: Duration = .zero
    @ObservationIgnored private var speechFrames = 0
    @ObservationIgnored private var levelFrames = 0
    @ObservationIgnored private var youRow: String?
    @ObservationIgnored private var replyRow: String?
    @ObservationIgnored private var replyCharacters = 0
    @ObservationIgnored private var checkInPending = false
    @ObservationIgnored private weak var lastKeySession: WorkspaceSession?
    /// Function calls whose arguments may stream, by output item id.
    @ObservationIgnored private var argumentStreams: [String: ArgumentStream] = [:]
    @ObservationIgnored private var argumentStreamOrder = 0
    /// How many function calls are tracked now. Tests read it.
    var argumentStreamCount: Int { argumentStreams.count }

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        costStore = VoiceCostStore(suiteName: dependencies.costSuiteName)
    }

    private var persona: VoicePersona {
        VoicePersona.rafu.with(voice: dependencies.preferences.voice)
    }

    private func elapsed() -> Duration { ContinuousClock.now - openedAt }

    /// Time since the session opened. Tests add to it for `tick(at:)`.
    var sessionElapsed: Duration { elapsed() }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(
            duration.components.seconds * 1_000 + duration.components.attoseconds
                / 1_000_000_000_000_000)
    }

    // MARK: Public API

    /// ⌃⌥Space down, or the blob held.
    func beginHold() {
        if case .error = blobState { machine.apply(.reset) }
        let wasOpen = blobState.isOpen
        machine.apply(.holdBegan)
        guard machine.mic == .held else { return }
        if wasOpen {
            clock.noteSpeech(at: elapsed())
            micOpened()
        } else {
            open()
        }
    }

    /// ⌃⌥Space up. The session stays open; the microphone stops.
    func endHold() {
        guard machine.mic == .held else { return }
        machine.apply(.holdEnded)
        youRow = nil
        if isStarted { clock.noteSpeech(at: elapsed()) }
        micClosed()
    }

    /// The blob click and Start/Stop Listening: keep the microphone open
    /// without the key, visibly, until the check-in, a pause, or a click.
    func toggleLatched() {
        if case .error = blobState { machine.apply(.reset) }
        let wasOpen = blobState.isOpen
        machine.apply(.latchToggled)
        let latched = machine.mic == .latched
        if wasOpen {
            clock.setLatched(latched, at: elapsed())
            if latched { micOpened() } else { micClosed() }
        } else if latched {
            open()
        }
    }

    /// Stop Speaking, or a blob click while Rafu speaks. Backend work goes on.
    func stopSpeaking() {
        playback?.flush()
        endReply()
    }

    /// Clears a shown error; the blob returns to idle.
    func dismissError() {
        if case .error = blobState { machine.apply(.reset) }
    }

    /// True while a session holds or is opening a socket.
    var hasOpenSession: Bool { blobState.isOpen || client != nil || openTask != nil }

    /// Closes the session and releases everything it held. `closeTimeout`
    /// bounds the wait for `session.closed` (default: the dependency's 15 s).
    func close(reason: VoiceCloseReason = .user, closeTimeout: Duration? = nil) async {
        guard hasOpenSession else { return }
        generation += 1
        openTask?.cancel()
        openTask = nil
        await teardown(sendClose: isStarted, closeTimeout: closeTimeout)
        if reason != .failure { machine.apply(.closed) }
    }

    /// Quit, from `applicationShouldTerminate`: sends `session.close` and
    /// waits at most `limit`. A send that does not return is cut off by
    /// dropping the socket at the same limit.
    func closeForQuit(limit: Duration = .seconds(2)) async {
        guard hasOpenSession else { return }
        let transport = transport
        let watchdog = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            transport?.cancel()
        }
        await close(reason: .user, closeTimeout: limit)
        watchdog.cancel()
    }

    /// Quit, from `applicationWillTerminate`: synchronous. Stops capture and
    /// playback, drops the socket with a close frame, and books the minutes.
    /// The server ends the session when the socket goes.
    func terminateNow() {
        guard hasOpenSession else { return }
        generation += 1
        openTask?.cancel()
        openTask = nil
        isClosing = true
        resumeStart(false)
        confirmGate.resolve(.cancel)
        stopCapture()
        audioTask?.cancel()
        clockTask?.cancel()
        eventTask?.cancel()
        transport?.cancel()
        playback?.stopAll()
        if let sessionID { costStore.finish(sessionID: sessionID) }
        audioTask = nil
        clockTask = nil
        eventTask = nil
        pendingFrames = []
        releaseSession()
        machine.apply(.closed)
    }

    // MARK: Open

    private func open() {
        generation += 1
        let ticket = generation
        openedAt = ContinuousClock.now
        clock = VoiceActivityClock()
        clock.setLatched(machine.mic == .latched, at: .zero)
        lastError = nil
        timeline.clear()
        openTask = Task { await self.runOpen(ticket) }
    }

    private func runOpen(_ ticket: Int) async {
        let key: String
        do {
            key = try await dependencies.openAIKey()
        } catch {
            return await fail(.noOpenAIKey, ticket: ticket)
        }
        guard ticket == generation else { return }
        guard await dependencies.requestMicrophone() else {
            return await fail(.microphoneDenied, ticket: ticket)
        }
        guard ticket == generation else { return }
        guard costStore.allowsNewSession(cap: dependencies.preferences.monthlyCapDollars) else {
            return await fail(.monthlyCapReached, ticket: ticket)
        }
        let (capture, playback) = dependencies.makeAudio()
        self.capture = capture
        self.playback = playback
        do {
            try playback.startPlayback()
        } catch {
            return await fail(.audioUnavailable, ticket: ticket)
        }
        // Speech said while the socket connects is buffered and sent after
        // `session.started`.
        if machine.mic != .off { startCapture() }
        let transport = dependencies.makeTransport(key)
        self.transport = transport
        let client = VoiceLiveClient(transport: transport, closeTimeout: dependencies.closeTimeout)
        self.client = client
        let events = client.events
        eventTask = Task {
            for await event in events { self.handle(event) }
            self.eventsEnded(ticket)
        }
        let target = voiceTarget()
        activeBoardID = target?.board?.id
        let config = VoiceSessionPlan.start(
            persona: persona, backend: dependencies.preferences.backend,
            tools: VoiceToolSchema.tools(for: .rafu))
        do {
            try await client.start()
            guard ticket == generation else { return await abandon(client, playback) }
            try await client.send(.sessionStart(config))
        } catch {
            return await fail(.disconnected, ticket: ticket)
        }
        guard ticket == generation else { return await abandon(client, playback) }
        guard await waitForStart() else {
            let error: VoiceError =
                startErrorCode.map { .refused(code: $0) }
                ?? (streamEndedBeforeStart ? .disconnected : .startTimedOut)
            return await fail(error, ticket: ticket)
        }
        guard ticket == generation else { return await abandon(client, playback) }
        isStarted = true
        openTask = nil
        machine.apply(.connected)
        if !pendingFrames.isEmpty {
            // Sends what was said while connecting; a stream that already
            // ended (key released early) drains and then mutes.
            startSendingAudio()
        } else {
            try? await client.send(.inputAudioMute)
        }
        if dependencies.runsClock { startClock() }
    }

    /// A close arrived while this open was still connecting, and the
    /// teardown may have run before these objects existed: drop them.
    private func abandon(_ client: VoiceLiveClient, _ playback: any VoiceAudioPlaying) async {
        await client.cancel()
        playback.stopAll()
        if self.client === client {
            stopCapture()
            self.client = nil
            self.capture = nil
            self.playback = nil
            self.transport = nil
            pendingFrames = []
            eventTask?.cancel()
            eventTask = nil
        }
    }

    private func waitForStart() async -> Bool {
        let timeout = dependencies.startTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.resumeStart(false)
        }
        let started = await withCheckedContinuation { waiter in
            if sessionID != nil {
                waiter.resume(returning: true)
            } else if startErrorCode != nil || streamEndedBeforeStart {
                waiter.resume(returning: false)
            } else {
                startWaiter = waiter
            }
        }
        timer.cancel()
        return started
    }

    private func resumeStart(_ value: Bool) {
        let waiter = startWaiter
        startWaiter = nil
        waiter?.resume(returning: value)
    }

    private func fail(_ error: VoiceError, ticket: Int) async {
        guard ticket == generation else { return }
        generation += 1
        openTask = nil
        lastError = error.blobReason
        machine.apply(.failed(error.blobReason))
        await teardown(sendClose: isStarted)
    }

    /// Order: stop capture, close the socket (waiting for `session.closed`),
    /// end the streams, release the engine.
    private func teardown(sendClose: Bool, closeTimeout: Duration? = nil) async {
        isClosing = true
        resumeStart(false)
        // A waiting Confirm card is cancelled; its call then finds the
        // session gone and drops its result.
        confirmGate.resolve(.cancel)
        stopCapture()
        audioTask?.cancel()
        audioTask = nil
        pendingFrames = []
        clockTask?.cancel()
        clockTask = nil
        if let client {
            if sendClose {
                await client.close(timeout: closeTimeout)
            } else {
                await client.cancel()
            }
        }
        eventTask?.cancel()
        eventTask = nil
        playback?.stopAll()
        if let sessionID { costStore.finish(sessionID: sessionID) }
        releaseSession()
    }

    /// Forgets every per-session resource and counter. Idle again after it.
    private func releaseSession() {
        cancelViewStreams()
        callChain = nil
        client = nil
        transport = nil
        capture = nil
        playback = nil
        sessionID = nil
        sessionGrants.removeAll()
        delegationCount = 0
        cardDelegationIndex = 0
        isEngineSuspended = false
        lastEngineUse = .zero
        startErrorCode = nil
        streamEndedBeforeStart = false
        isStarted = false
        inFlightCalls = 0
        outputsAwaitingCreate = 0
        completedWhileInFlight = false
        lastAudibleAt = nil
        checkInPending = false
        youRow = nil
        replyRow = nil
        inputLevel = 0
        timeline.clear()
        isClosing = false
    }

    private func eventsEnded(_ ticket: Int) {
        guard ticket == generation, !isClosing else { return }
        guard isStarted else {
            // Still opening: `runOpen` reports it (a refusal code wins).
            streamEndedBeforeStart = true
            resumeStart(false)
            return
        }
        Task { await self.fail(.disconnected, ticket: ticket) }
    }

    /// Restarts an engine stopped after a quiet spell. False when the audio
    /// device refused; the session then fails like a refused start.
    private func resumeEngineIfSuspended() -> Bool {
        noteEngineUse()
        guard isEngineSuspended, let playback else { return true }
        do {
            try playback.startPlayback()
        } catch {
            Task { await self.fail(.audioUnavailable, ticket: self.generation) }
            return false
        }
        isEngineSuspended = false
        return true
    }

    private func noteEngineUse() { lastEngineUse = max(lastEngineUse, elapsed()) }

    /// Stops the engine in a session that is not latched, after
    /// `engineIdleAfter` with the microphone off, nothing audible, no call
    /// running and no card waiting. The socket and the session stay open.
    private func suspendEngineIfQuiet(at now: Duration) {
        guard !isEngineSuspended, let playback, machine.mic == .off, lastAudibleAt == nil,
            inFlightCalls == 0, !confirmGate.isPending, blobState != .speaking,
            now - lastEngineUse >= dependencies.engineIdleAfter
        else { return }
        stopCapture()
        playback.stopAll()
        isEngineSuspended = true
    }

    // MARK: Microphone

    private func micOpened() {
        guard capture != nil, !isCapturing else { return }
        guard resumeEngineIfSuspended() else { return }
        startCapture()
        if isStarted { startSendingAudio() }
    }

    /// Stops the tap. The stream ends, its buffered frames still go out, and
    /// its sender then sends `mute`, so `mute` never overtakes speech.
    private func micClosed() {
        stopCapture()
        noteEngineUse()
    }

    private func startCapture() {
        guard let capture else { return }
        speechFrames = 0
        guard let stream = try? capture.startCapture() else {
            isCapturing = false
            return
        }
        pendingFrames.append(stream)
        isCapturing = true
    }

    /// One sender per capture stream, chained so the order on the socket is
    /// always unmute, frames, mute.
    private func startSendingAudio() {
        guard !pendingFrames.isEmpty, let client else { return }
        let streams = pendingFrames
        pendingFrames = []
        for stream in streams {
            let previous = audioTask
            audioTask = Task {
                await previous?.value
                try? await client.send(.inputAudioUnmute)
                for await frame in stream {
                    self.handleFrame(frame)
                    try? await client.send(.inputAudioAppend(frame))
                }
                try? await client.send(.inputAudioMute)
            }
        }
    }

    private func stopCapture() {
        if isCapturing { capture?.stopCapture() }
        isCapturing = false
        inputLevel = 0
    }

    private func handleFrame(_ frame: Data) {
        let rms = VoiceAudioLevel.rms(pcm16: frame)
        levelFrames += 1
        if levelFrames % 3 == 0 { inputLevel = VoiceAudioLevel.meterLevel(rms: rms) }
        speechFrames = rms >= VoiceAudioFormat.localSpeechRMS ? speechFrames + 1 : 0
        guard speechFrames >= VoiceAudioFormat.localSpeechFrames else { return }
        clock.noteSpeech(at: elapsed())
        if blobState == .checkIn { machine.apply(.speechDetected) }
        // Barge-in: the user talks over Rafu; cut the reply locally at once.
        if lastAudibleAt != nil, capture?.supportsBargeIn == true {
            playback?.flush()
            endReply()
        }
    }

    // MARK: Events

    private func handle(_ event: VoiceLiveServerEvent) {
        switch event {
        case .sessionStarted(let id, _):
            sessionID = id.isEmpty ? UUID().uuidString : id
            resumeStart(true)
        case .outputAudioDelta(let pcm):
            handleOutputAudio(pcm)
        case .inputTranscriptDelta(let text):
            if let youRow {
                timeline.appendDetail(text, to: youRow)
            } else {
                youRow = timeline.append(
                    lane: .you, startMS: milliseconds(elapsed()), persona: personaName,
                    title: "You", detail: text)
            }
        case .outputTranscriptDelta(let text):
            replyCharacters += text.count
        case .delegationCreated(let id, _):
            youRow = nil
            delegationCount += 1
            // A reply is coming: have the engine ready before its audio.
            _ = resumeEngineIfSuspended()
            clock.noteServerActivity(at: elapsed())
            machine.apply(.delegationStarted)
            timeline.append(
                lane: .delegation, startMS: milliseconds(elapsed()), delegationID: id,
                persona: personaName, title: "Delegation")
        case .functionCallStarted(let itemID, let callID, let name):
            functionCallStarted(itemID: itemID, callID: callID, name: name)
        case .functionCallArgumentsDelta(let itemID, let delta):
            functionCallArgumentsDelta(itemID: itemID, delta: delta)
        case .functionCall(let callID, let name, let arguments):
            let measure = functionCallFinished(callID: callID, name: name)
            runCall(callID: callID, name: name, arguments: arguments, measure: measure)
        case .responseCompleted:
            cancelOrphanViewStreams()
            if inFlightCalls > 0 {
                completedWhileInFlight = true
            } else {
                sendResponseCreateIfNeeded()
            }
        case .usageUpdated(let seconds, _):
            if let sessionID { costStore.recordUsage(sessionID: sessionID, seconds: seconds) }
        case .sessionClosed(_, let seconds):
            if let sessionID, let seconds {
                costStore.recordUsage(sessionID: sessionID, seconds: Double(seconds))
            }
            if !isClosing, isStarted { Task { await self.close(reason: .remote) } }
        case .error(let code, _):
            if !isStarted {
                startErrorCode = code ?? "error"
                resumeStart(false)
            } else if checkInPending {
                // The spoken check-in is untested under Responses delegation;
                // the glyph alone stays (gpt-live-protocol.md).
                checkInPending = false
            } else {
                lastError = "GPT-Live error \(code ?? "unknown")"
            }
        case .commentaryAppended:
            checkInPending = false
        case .sessionUpdated, .other:
            break
        }
    }

    private func handleOutputAudio(_ pcm: Data) {
        let now = elapsed()
        let audible = VoiceAudioLevel.rms(pcm16: pcm) > VoiceAudioFormat.audibleOutputRMS
        // The server streams silence while the session is open; a stopped
        // engine skips it and restarts on the first audible delta.
        if isEngineSuspended {
            guard audible, resumeEngineIfSuspended() else { return }
        }
        playback?.enqueue(pcm)
        if audible {
            noteEngineUse()
            if lastAudibleAt == nil, blobState != .checkIn {
                machine.apply(.replyStarted)
                replyCharacters = 0
                replyRow = timeline.append(
                    lane: .voice, startMS: milliseconds(now), persona: personaName,
                    title: "\(personaName) reply")
            }
            lastAudibleAt = now
            // The check-in's own prompt does not reset the silence clock.
            if blobState != .checkIn { clock.noteServerActivity(at: now) }
        } else if let last = lastAudibleAt, now - last > .milliseconds(600) {
            endReply()
        }
    }

    private func endReply() {
        lastAudibleAt = nil
        if let replyRow {
            timeline.finish(
                replyRow, endMS: milliseconds(elapsed()), detail: "\(replyCharacters) characters")
        }
        replyRow = nil
        machine.apply(.replyEnded)
    }

    // MARK: Tool calls

    /// Calls run one after another, in arrival order: "make three terminals"
    /// then "link them" must not interleave.
    private func runCall(callID: String, name: String, arguments: String, measure: String?) {
        inFlightCalls += 1
        clock.noteServerActivity(at: elapsed())
        noteEngineUse()
        let ticket = generation
        let row = timeline.append(
            lane: .tool, startMS: milliseconds(elapsed()), persona: personaName, title: name)
        if VoiceToolSchema.confirmNames.contains(name) {
            // The answer to a waiting card: run now, not behind that call.
            Task {
                let outcome = await VoiceToolExecutor.run(
                    name: name, argumentsJSON: arguments, callID: callID, host: self)
                await self.finishCall(
                    callID: callID, row: row, outcome: outcome, measure: measure, ticket: ticket)
            }
            return
        }
        let previous = callChain
        callChain = Task {
            await previous?.value
            let outcome = await VoiceToolExecutor.run(
                name: name, argumentsJSON: arguments, callID: callID, host: self)
            await self.finishCall(
                callID: callID, row: row, outcome: outcome, measure: measure, ticket: ticket)
        }
    }

    private func finishCall(
        callID: String, row: String, outcome: VoiceToolOutcome, measure: String?, ticket: Int
    ) async {
        // A skeleton the call did not finish (refused before it reached the
        // view code) never stays on the board.
        if let handle = viewStreamHandle(for: callID) {
            handle.cancel()
            takeViewStreamHandle(for: callID)
        }
        // A call still running when the session closed: the board change
        // stands (like a late MCP approval); its result is dropped.
        guard ticket == generation, let client else { return }
        let detail = measure.map { "\(outcome.summary); \($0)" } ?? outcome.summary
        timeline.finish(row, endMS: milliseconds(elapsed()), detail: detail)
        clock.noteServerActivity(at: elapsed())
        try? await client.send(
            .responseItemCreateFunctionOutput(callID: callID, output: outcome.output))
        guard ticket == generation else { return }
        outputsAwaitingCreate += 1
        inFlightCalls = max(0, inFlightCalls - 1)
        if inFlightCalls == 0, completedWhileInFlight {
            completedWhileInFlight = false
            sendResponseCreateIfNeeded()
        }
    }

    /// `response.create` is mandatory after function outputs (Phase 0); one
    /// per finished response, after all of its calls answered.
    private func sendResponseCreateIfNeeded() {
        guard outputsAwaitingCreate > 0, let client else { return }
        outputsAwaitingCreate = 0
        Task { try? await client.send(.responseCreate) }
    }

    // MARK: View streaming

    /// One function call whose arguments may arrive as deltas. Counts only;
    /// the text is kept only for `show_view`, and only until its skeleton
    /// card starts (at most `titleWindowBytes`).
    private struct ArgumentStream {
        let name: String
        let order: Int
        var callID: String?
        var deltas = 0
        var bytes = 0
        var pending = ""
        var decided = false
        /// The function_call done event arrived. A started call can carry its
        /// `call_id` early, so `callID` alone does not prove the call finished.
        var finished = false
        var handle: (any GeneratedViewStreamHandle)?
    }

    static let maximumArgumentStreams = 16
    /// How much `show_view` text to wait for while looking for the title.
    static let titleWindowBytes = 512

    private func functionCallStarted(itemID: String, callID: String?, name: String) {
        guard argumentStreams[itemID] == nil,
            argumentStreams.count < Self.maximumArgumentStreams
        else { return }
        argumentStreamOrder += 1
        argumentStreams[itemID] = ArgumentStream(
            name: name, order: argumentStreamOrder, callID: callID)
    }

    /// Runs on the main actor at once, not behind the call chain: the
    /// skeleton must appear while the model still speaks.
    private func functionCallArgumentsDelta(itemID: String, delta: String) {
        guard var stream = argumentStreams[itemID] else { return }
        stream.deltas += 1
        stream.bytes += delta.utf8.count
        if stream.name == VoiceToolSchema.showViewName {
            if let handle = stream.handle {
                handle.push(delta)
            } else if !stream.decided {
                stream.pending += delta
                let title = VoiceViewStreamTitle.title(in: stream.pending)
                if title != nil || VoiceViewStreamTitle.isPastTitle(stream.pending)
                    || stream.pending.utf8.count > Self.titleWindowBytes
                {
                    stream.decided = true
                    stream.handle = VoiceToolExecutor.beginShowView(
                        title: title ?? VoiceToolExecutor.defaultViewTitle, host: self)
                    stream.handle?.push(stream.pending)
                    stream.pending = ""
                }
            }
        }
        argumentStreams[itemID] = stream
    }

    /// Matches the finished call to its started item (by call id, else the
    /// oldest unmatched item with the same name) and returns the timeline's
    /// measure: "deltas: N, size". Always present for `show_view`, so the
    /// user can read whether GPT-Live streams arguments.
    private func functionCallFinished(callID: String, name: String) -> String? {
        let itemID =
            argumentStreams.first(where: { $0.value.callID == callID })?.key
            ?? argumentStreams.filter { $0.value.callID == nil && $0.value.name == name }
            .min(by: { $0.value.order < $1.value.order })?.key
        guard let itemID, var stream = argumentStreams[itemID] else {
            return name == VoiceToolSchema.showViewName ? "deltas: 0" : nil
        }
        stream.callID = callID
        stream.finished = true
        if stream.handle == nil {
            argumentStreams.removeValue(forKey: itemID)
        } else {
            argumentStreams[itemID] = stream
        }
        guard stream.deltas > 0 || name == VoiceToolSchema.showViewName else { return nil }
        return "deltas: \(stream.deltas), \(Self.byteText(stream.bytes))"
    }

    private static func byteText(_ bytes: Int) -> String {
        bytes < 1_024
            ? "\(bytes) B" : String(format: "%.1f KiB", Double(bytes) / 1_024)
    }

    /// A response ended without finishing some started call: its skeleton goes.
    private func cancelOrphanViewStreams() {
        for (itemID, stream) in argumentStreams where !stream.finished {
            stream.handle?.cancel()
            argumentStreams.removeValue(forKey: itemID)
        }
    }

    /// Session close or a new session: every skeleton goes; nothing is saved.
    private func cancelViewStreams() {
        for stream in argumentStreams.values { stream.handle?.cancel() }
        argumentStreams.removeAll()
        argumentStreamOrder = 0
    }

    // MARK: Timers

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                } catch {
                    return
                }
                self.tick(at: self.elapsed())
            }
        }
    }

    /// One clock step at `now` (offset from the session start). Tests call it
    /// with chosen instants.
    func tick(at now: Duration) {
        guard isStarted else { return }
        // A waiting Confirm card holds the clock; its own 60 s timeout ends it.
        guard !confirmGate.isPending else { return }
        suspendEngineIfQuiet(at: now)
        switch clock.nextAction(at: now) {
        case .checkIn:
            clock.checkedIn = true
            machine.apply(.checkIn)
            checkInPending = true
            if let client {
                Task {
                    try? await client.send(
                        .commentaryAppend(delegationID: nil, "Shall I keep listening?"))
                }
            }
        case .pause:
            clock.paused = true
            machine.apply(.pause)
            micClosed()
        case .close:
            Task { await self.close(reason: .idle) }
        case nil:
            break
        }
    }

    // MARK: Tool host

    func latchFromTool() {
        guard machine.mic != .latched else { return }
        machine.apply(.latchToggled)
        clock.setLatched(true, at: elapsed())
        micOpened()
    }

    func confirm(_ request: VoiceConfirmRequest) async -> VoiceConfirmAnswer {
        guard !confirmGate.isPending else { return .busy }
        let row = timeline.append(
            lane: .tool, startMS: milliseconds(elapsed()), persona: personaName,
            title: "Confirm \(request.tool.rawValue)")
        machine.apply(.needsConfirm)
        cardDelegationIndex = delegationCount
        let answer = await confirmGate.ask(
            request, timeout: dependencies.confirmTimeout, present: dependencies.presentConfirm)
        machine.apply(.confirmResolved)
        timeline.finish(row, endMS: milliseconds(elapsed()), detail: answer.timelineWord)
        if isStarted { clock.noteServerActivity(at: elapsed()) }
        noteEngineUse()
        return answer
    }

    /// A spoken answer. A cancel counts at once (cancelling is always safe);
    /// a confirmation counts only from a backend turn that started after the
    /// card appeared, that is, after the user spoke. A click on the card goes
    /// straight to the gate and is not affected.
    func resolveConfirm(_ answer: VoiceConfirmAnswer) -> VoiceConfirmResolution {
        guard confirmGate.isPending else { return .nothingPending }
        if answer != .cancel, delegationCount <= cardDelegationIndex { return .notHeard }
        return confirmGate.resolve(answer) ? .resolved : .nothingPending
    }

    func hasSessionGrant(_ key: String) -> Bool { sessionGrants.contains(key) }

    func grantForSession(_ key: String) { sessionGrants.insert(key) }

    func noteBoardEffect(_ title: String, detail: String) {
        let row = timeline.append(
            lane: .board, startMS: milliseconds(elapsed()), persona: personaName, title: title,
            detail: detail)
        timeline.finish(row, endMS: milliseconds(elapsed()))
    }
}

extension VoiceConfirmAnswer {
    /// The timeline's word for an answer.
    var timelineWord: String {
        switch self {
        case .allowOnce: "allowed once"
        case .allowForSession: "allowed for the session"
        case .cancel: "cancelled"
        case .timedOut: "timed out"
        case .busy: "busy"
        case .noWindow: "no window"
        }
    }
}

extension VoiceSession: VoiceToolHost {
    var voicePreferences: VoicePreferences { dependencies.preferences }

    /// The key workspace window and its Ensemble. With no key window (only
    /// the notch strip in front), the last key window still counts.
    func voiceTarget() -> VoiceTarget? {
        if let target = dependencies.target {
            let resolved = target()
            activeBoardID = resolved?.board?.id
            return resolved
        }
        let snapshots = WorkspaceWindowRegistry.shared.sessionSnapshots()
        if let key = snapshots.first(where: \.isKeyWindow)?.session { lastKeySession = key }
        let remembered = lastKeySession.flatMap { session in
            snapshots.contains { $0.session === session } ? session : nil
        }
        guard let session = remembered ?? snapshots.first?.session else {
            activeBoardID = nil
            return nil
        }
        let board =
            session.selectedCanvas
            ?? session.canvas.boards.values.first {
                session.canvasResources[$0.id]?.isPresented == true
            }
        activeBoardID = board?.id
        return VoiceTarget(session: session, board: board)
    }

    var generatedViewHost: (any GeneratedViewHost)? { dependencies.viewHost() }

    func viewStreamHandle(for callID: String) -> (any GeneratedViewStreamHandle)? {
        argumentStreams.values.first { $0.callID == callID }?.handle
    }

    func takeViewStreamHandle(for callID: String) {
        guard let itemID = argumentStreams.first(where: { $0.value.callID == callID })?.key
        else { return }
        argumentStreams.removeValue(forKey: itemID)
    }

    func voiceWorkspaces() -> [WorkspaceSession] {
        if let workspaces = dependencies.workspaces { return workspaces() }
        return WorkspaceWindowRegistry.shared.sessionSnapshots().map(\.session)
    }

    func voiceStatus() -> VoiceJSON {
        let preferences = dependencies.preferences
        let board = voiceTarget()?.board
        var status: [String: VoiceJSON] = [
            "persona": .string(personaName),
            "backend": .string(preferences.backend.rawValue),
            "voice": .string(preferences.voice.rawValue),
            "month_minutes": .number((costStore.monthlySeconds / 60 * 10).rounded() / 10),
            "month_cost_usd": .number((costStore.monthlyCost * 100).rounded() / 100),
            "monthly_cap_usd": .number(preferences.monthlyCapDollars),
            "session_seconds": .integer(Int(elapsed().components.seconds)),
            "microphone": .string(machine.isMicOpen ? "open" : "off"),
        ]
        if let board {
            status["ensemble"] = .string(CanvasAgentText.singleLine(board.title, limit: 80))
            status["agent_control"] = .string(board.agentControlMode.rawValue)
        }
        return .object(status)
    }
}
