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
/// the user's own words, in memory, cleared on close). Only the opt-in debug
/// transcript (`VoiceDebugTranscript`) writes words to disk.
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
        /// Thinking with no server event since it began (or since the
        /// newest one): back to listening or Paused after this.
        var thinkingNoHearLimit: Duration = .seconds(8)
        /// Thinking after a delegation or a call result, with no reply.
        var thinkingNoReplyLimit: Duration = .seconds(20)
        /// Off in tests, which drive `tick(at:)` directly.
        var runsClock = true
        /// The generated-view card implementation (`show_view`). Tests give a
        /// double instead of the process-wide registry.
        var viewHost: @MainActor () -> (any GeneratedViewHost)? = {
            GeneratedViewHostRegistry.shared.host
        }
        /// Where the opt-in debug transcript goes. `nil` means
        /// `VoiceDebugTranscript.defaultDirectory()`.
        var debugTranscriptDirectory: URL? = nil

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
    /// A short tip after a turn Rafu did not hear or answer. Cleared by the
    /// next press, a reply, a delegation, or close.
    private(set) var hint: String?
    let costStore: VoiceCostStore

    static let silentTurnHint = "Hold ⌃⌥Space while you talk, or choose Start Listening."
    static let noReplyHint = "No reply. Hold ⌃⌥Space and try again."

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
    @ObservationIgnored private var pendingFrames: [VoiceCaptureTurn] = []
    /// The stream the tap feeds now; nil while the microphone is off.
    @ObservationIgnored private var currentTurn: VoiceCaptureTurn?
    /// Server events that show the turn was heard or answered. A held turn
    /// with no local speech pauses only if this did not move since it began.
    @ObservationIgnored private var serverEventCount = 0
    /// While Thinking: the newest server event (or the entry), the entry,
    /// and what the server did so far. `tick(at:)` ends a stalled Thinking.
    @ObservationIgnored private var thinkingSince: Duration?
    @ObservationIgnored private var thinkingStartedAt: Duration = .zero
    @ObservationIgnored private var thinkingHadDelegation = false
    @ObservationIgnored private var thinkingHadServerEvent = false
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
    /// Calls not yet answered. Tests read it.
    var runningCalls: Int { inFlightCalls }
    /// How many function calls are tracked now. Tests read it.
    var argumentStreamCount: Int { argumentStreams.count }
    /// The opt-in debug transcript of the open session; nil when off.
    @ObservationIgnored private var transcript: VoiceDebugTranscript?
    /// The newest transcript, kept after close so tests can await its drain.
    @ObservationIgnored private(set) var lastDebugTranscript: VoiceDebugTranscript?
    /// The current user turn and Rafu reply, collected only while a
    /// transcript is on, and written as one entry each.
    @ObservationIgnored private var userUtterance = ""
    @ObservationIgnored private var replyText = ""
    /// The `end_ms` of the newest transcript delta of each stream.
    @ObservationIgnored private var lastInputEndMS: Int?
    @ObservationIgnored private var lastOutputEndMS: Int?
    /// Why the server closed the session; read by `close` for the error text.
    @ObservationIgnored private var remoteCloseReason: String?

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
        hint = nil
        if case .error = blobState { apply(.reset) }
        let wasOpen = blobState.isOpen
        apply(.holdBegan)
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
        apply(.holdEnded)
        youRow = nil
        if isStarted { clock.noteSpeech(at: elapsed()) }
        micClosed()
    }

    /// The blob click and Start/Stop Listening: keep the microphone open
    /// without the key, visibly, until the check-in, a pause, or a click.
    func toggleLatched() {
        hint = nil
        if case .error = blobState { apply(.reset) }
        let wasOpen = blobState.isOpen
        apply(.latchToggled)
        let latched = machine.mic == .latched
        // A held stream that becomes latched is no longer a push-to-talk turn.
        if latched { currentTurn?.audio.held = false }
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
        if case .error = blobState { apply(.reset) }
    }

    /// True while a session holds or is opening a socket.
    var hasOpenSession: Bool { blobState.isOpen || client != nil || openTask != nil }

    /// Closes the session and releases everything it held. `closeTimeout`
    /// bounds the wait for `session.closed` (default: the dependency's 15 s).
    func close(reason: VoiceCloseReason = .user, closeTimeout: Duration? = nil) async {
        guard hasOpenSession else { return }
        transcript?.record(.sessionClosed(reason: "\(reason)"))
        let serverReason = remoteCloseReason
        remoteCloseReason = nil
        generation += 1
        openTask?.cancel()
        openTask = nil
        await teardown(sendClose: isStarted, closeTimeout: closeTimeout)
        if reason == .failure { return }
        if reason == .remote, let message = Self.remoteCloseMessage(serverReason) {
            lastError = message
            apply(.failed(message))
        } else {
            apply(.closed)
        }
    }

    /// What the user reads when the server ends the session. The user's own
    /// close and the answer to it say nothing. The reason is cut to 40 plain
    /// characters: it is server text.
    nonisolated static func remoteCloseMessage(_ reason: String?) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- .")
        let plain = String((reason ?? "").filter { allowed.contains($0) }.prefix(40))
        guard plain != "user", plain != "close_requested" else { return nil }
        return plain.isEmpty
            ? "The voice service closed the session."
            : "The voice service closed the session (\(plain))."
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
        // The drain cannot be awaited here; the last lines may be lost at quit.
        transcript?.record(.sessionClosed(reason: "quit"))
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
        apply(.closed)
    }

    // MARK: Open

    private func open() {
        generation += 1
        let ticket = generation
        openedAt = ContinuousClock.now
        clock = VoiceActivityClock()
        clock.setLatched(machine.mic == .latched, at: .zero)
        lastError = nil
        remoteCloseReason = nil
        timeline.clear()
        startTranscript()
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
        recordEngine()
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
        // Frames the open stream yielded so far were said before the start.
        if let turn = currentTurn {
            turn.take(capture.takeCaptureStats(), beforeStart: true)
        }
        apply(.connected)
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
        transcript?.record(.sessionFailed(reason: error.blobReason))
        generation += 1
        openTask = nil
        lastError = error.blobReason
        apply(.failed(error.blobReason))
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
        endTranscript()
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
        isClosing = false
        hint = nil
        currentTurn = nil
        serverEventCount = 0
        thinkingSince = nil
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
        recordEngine()
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

    /// Starts the tap. A failure restarts the engine and tries once more;
    /// a second failure shows a row and leaves the microphone off. Before
    /// this, a failed start said nothing and the blob still showed Listening.
    private func startCapture() {
        guard let capture else { return }
        speechFrames = 0
        let stream: AsyncStream<Data>
        do {
            stream = try capture.startCapture()
        } catch {
            do {
                stream = try retryCapture(capture)
            } catch {
                isCapturing = false
                let failure = error as NSError
                transcript?.record(.captureFailed(domain: failure.domain, code: failure.code))
                let row = timeline.append(
                    lane: .voice, startMS: milliseconds(elapsed()), persona: personaName,
                    title: "Microphone did not start")
                timeline.finish(row, endMS: milliseconds(elapsed()))
                return
            }
        }
        let turn = VoiceCaptureTurn(
            frames: stream, held: machine.mic == .held, openedAt: elapsed(),
            eventMark: serverEventCount)
        currentTurn = turn
        pendingFrames.append(turn)
        isCapturing = true
    }

    /// A fresh engine, then the tap again.
    private func retryCapture(_ capture: any VoiceAudioCapturing) throws -> AsyncStream<Data> {
        if let playback {
            playback.stopAll()
            do {
                try playback.startPlayback()
            } catch {
                // The next press restarts the engine.
                isEngineSuspended = true
                throw error
            }
            recordEngine()
        }
        return try capture.startCapture()
    }

    private func recordEngine() {
        guard let transcript, let capture else { return }
        transcript.record(.audioEngine(capture.lastEngineFacts))
    }

    /// One sender per capture stream, chained so the order on the socket is
    /// always unmute, frames, mute. Each sender counts speech in its own
    /// stream, so the decision for a held turn waits until the frames
    /// buffered before `session.started` went out.
    private func startSendingAudio() {
        guard !pendingFrames.isEmpty, let client else { return }
        let turns = pendingFrames
        pendingFrames = []
        let ticket = generation
        for turn in turns {
            let previous = audioTask
            audioTask = Task {
                await previous?.value
                try? await client.send(.inputAudioUnmute)
                turn.audio.unmuteMS = self.milliseconds(self.elapsed())
                for await frame in turn.frames {
                    turn.note(rms: self.handleFrame(frame))
                    try? await client.send(.inputAudioAppend(frame))
                }
                try? await client.send(.inputAudioMute)
                turn.audio.muteMS = self.milliseconds(self.elapsed())
                self.turnFinished(turn, ticket: ticket)
            }
        }
    }

    /// The newest sender; it waits for the ones before it. Tests await it
    /// instead of sleeping.
    var audioSender: Task<Void, Never>? { audioTask }

    /// Records the turn's numbers. A held turn with no local speech and no
    /// server event since it began cannot get a reply: the blob would stay
    /// on Thinking with the microphone off, and words said then are lost.
    /// It goes to Paused with a hint instead.
    private func turnFinished(_ turn: VoiceCaptureTurn, ticket: Int) {
        guard ticket == generation else { return }
        transcript?.record(.turnAudio(turn.audio))
        guard turn.audio.held, !turn.audio.heardSpeech, blobState == .thinking,
            machine.mic == .off, serverEventCount == turn.eventMark
        else { return }
        apply(.noResponse)
        showNoResponse(title: "Rafu did not hear you", hint: Self.silentTurnHint)
        transcript?.record(
            .silentTurn(
                frames: turn.audio.frames, maxRMS: turn.audio.maxRMS,
                heldMS: milliseconds((turn.closedAt ?? elapsed()) - turn.openedAt)))
    }

    private func showNoResponse(title: String, hint: String) {
        self.hint = hint
        let row = timeline.append(
            lane: .voice, startMS: milliseconds(elapsed()), persona: personaName, title: title,
            detail: hint)
        timeline.finish(row, endMS: milliseconds(elapsed()))
    }

    private func stopCapture() {
        if isCapturing {
            capture?.stopCapture()
            if let turn = currentTurn {
                if let capture { turn.take(capture.takeCaptureStats(), beforeStart: !isStarted) }
                turn.closedAt = elapsed()
            }
        }
        currentTurn = nil
        isCapturing = false
        inputLevel = 0
    }

    /// Updates the meter and the shared speech run; returns the frame's RMS.
    private func handleFrame(_ frame: Data) -> Double {
        let rms = VoiceAudioLevel.rms(pcm16: frame)
        levelFrames += 1
        if levelFrames % 3 == 0 { inputLevel = VoiceAudioLevel.meterLevel(rms: rms) }
        speechFrames = rms >= VoiceAudioFormat.localSpeechRMS ? speechFrames + 1 : 0
        guard speechFrames >= VoiceAudioFormat.localSpeechFrames else { return rms }
        clock.noteSpeech(at: elapsed())
        if blobState == .checkIn { apply(.speechDetected) }
        // Barge-in: the user talks over Rafu; cut the reply locally at once.
        if lastAudibleAt != nil, capture?.supportsBargeIn == true {
            playback?.flush()
            endReply()
        }
        return rms
    }

    // MARK: Events

    private func handle(_ event: VoiceLiveServerEvent) {
        switch event {
        case .sessionStarted(let id, _):
            sessionID = id.isEmpty ? UUID().uuidString : id
            transcript?.record(.sessionStarted(id: id))
            resumeStart(true)
        case .outputAudioDelta(let pcm):
            handleOutputAudio(pcm)
        case .inputTranscriptDelta(let text, let startMS, let endMS):
            noteServerTurnEvent()
            if transcript != nil {
                noteInputTranscript(text, startMS: startMS, endMS: endMS)
            }
            if let youRow {
                timeline.appendDetail(text, to: youRow)
            } else {
                youRow = timeline.append(
                    lane: .you, startMS: milliseconds(elapsed()), persona: personaName,
                    title: "You", detail: text)
            }
        case .outputTranscriptDelta(let text, let startMS, let endMS):
            replyCharacters += text.count
            if transcript != nil {
                noteOutputTranscript(text, startMS: startMS, endMS: endMS)
            }
        case .delegationCreated(let id, let target):
            flushTranscriptText()
            transcript?.record(.delegation(id: id, target: target))
            youRow = nil
            hint = nil
            noteServerTurnEvent(delegation: true)
            delegationCount += 1
            // A reply is coming: have the engine ready before its audio.
            _ = resumeEngineIfSuspended()
            clock.noteServerActivity(at: elapsed())
            apply(.delegationStarted)
            timeline.append(
                lane: .delegation, startMS: milliseconds(elapsed()), delegationID: id,
                persona: personaName, title: "Delegation")
        case .functionCallStarted(let itemID, let callID, let name):
            noteServerTurnEvent(delegation: true)
            functionCallStarted(itemID: itemID, callID: callID, name: name)
        case .functionCallArgumentsDelta(let itemID, let delta):
            noteServerTurnEvent(delegation: true)
            functionCallArgumentsDelta(itemID: itemID, delta: delta)
        case .functionCall(let callID, let name, let arguments):
            noteServerTurnEvent(delegation: true)
            let measure = functionCallFinished(callID: callID, name: name)
            runCall(callID: callID, name: name, arguments: arguments, measure: measure)
        case .responseCompleted:
            noteServerTurnEvent()
            // Transcript deltas trail the audio by a fraction of a second.
            // While the reply is still audible `endReply` writes it.
            if lastAudibleAt == nil { flushReply() }
            cancelOrphanViewStreams()
            if inFlightCalls > 0 {
                completedWhileInFlight = true
            } else {
                sendResponseCreateIfNeeded()
            }
        case .usageUpdated(let seconds, _):
            if let sessionID { costStore.recordUsage(sessionID: sessionID, seconds: seconds) }
        case .sessionClosed(let reason, let seconds):
            transcript?.record(.sessionClosed(reason: reason ?? "remote"))
            if let sessionID, let seconds {
                costStore.recordUsage(sessionID: sessionID, seconds: Double(seconds))
            }
            if !isClosing, isStarted {
                remoteCloseReason = reason
                Task { await self.close(reason: .remote) }
            }
        case .error(let code, let message):
            transcript?.record(.serverError(code: code, message: message))
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
            noteServerTurnEvent()
            if lastAudibleAt == nil, blobState != .checkIn {
                hint = nil
                apply(.replyStarted)
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

    /// Moves the Thinking limit forward. A delegation or a call means a reply
    /// is being made, so the longer limit applies.
    private func noteServerTurnEvent(delegation: Bool = false) {
        serverEventCount += 1
        guard thinkingSince != nil else { return }
        thinkingSince = elapsed()
        thinkingHadServerEvent = true
        if delegation { thinkingHadDelegation = true }
    }

    private func endReply() {
        lastAudibleAt = nil
        if let replyRow {
            timeline.finish(
                replyRow, endMS: milliseconds(elapsed()), detail: "\(replyCharacters) characters")
        }
        replyRow = nil
        flushReply()
        apply(.replyEnded)
    }

    // MARK: Tool calls

    /// Calls run one after another, in arrival order: "make three terminals"
    /// then "link them" must not interleave.
    private func runCall(callID: String, name: String, arguments: String, measure: String?) {
        transcript?.record(.call(callID: callID, name: name, arguments: arguments))
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
                    callID: callID, name: name, row: row, outcome: outcome, measure: measure,
                    ticket: ticket)
            }
            return
        }
        let previous = callChain
        callChain = Task {
            await previous?.value
            let outcome = await VoiceToolExecutor.run(
                name: name, argumentsJSON: arguments, callID: callID, host: self)
            await self.finishCall(
                callID: callID, name: name, row: row, outcome: outcome, measure: measure,
                ticket: ticket)
        }
    }

    private func finishCall(
        callID: String, name: String, row: String, outcome: VoiceToolOutcome, measure: String?,
        ticket: Int
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
        transcript?.record(
            .callResult(
                callID: callID, name: name, summary: outcome.summary, message: outcome.message,
                output: outcome.output, isError: outcome.isError))
        // A failure shows Rafu's own message ("invalid_arguments: ..."); the
        // timeline cuts the line to 120 scalars.
        let base = outcome.message.map { "\(outcome.summary): \($0)" } ?? outcome.summary
        let detail = measure.map { "\(base); \($0)" } ?? base
        timeline.finish(row, endMS: milliseconds(elapsed()), detail: detail)
        clock.noteServerActivity(at: elapsed())
        noteServerTurnEvent(delegation: true)
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

    // MARK: Debug transcript

    private func startTranscript() {
        endTranscript()
        guard dependencies.preferences.keepsDebugTranscript else { return }
        let directory =
            dependencies.debugTranscriptDirectory ?? VoiceDebugTranscript.defaultDirectory()
        let transcript = VoiceDebugTranscript(directory: directory)
        self.transcript = transcript
        lastDebugTranscript = transcript
        let preferences = dependencies.preferences
        transcript.record(
            .sessionOpened(
                persona: persona.name, backend: preferences.backend.rawValue,
                voice: preferences.voice.rawValue))
    }

    /// Writes what is left and ends the stream; the drain closes the file.
    private func endTranscript() {
        flushTranscriptText()
        transcript?.finish()
        transcript = nil
        userUtterance = ""
        replyText = ""
        lastInputEndMS = nil
        lastOutputEndMS = nil
    }

    /// The reply goes first: a reply still pending belongs to the turn
    /// before the user words that are pending now.
    private func flushTranscriptText() {
        flushReply()
        flushUserTurn()
    }

    private func flushUserTurn() {
        guard !userUtterance.isEmpty else { return }
        transcript?.record(.userSaid(userUtterance))
        userUtterance = ""
    }

    /// A pause longer than this inside the transcript text starts a new turn
    /// (server `start_ms` against the last `end_ms`).
    private static let userTurnGapMS = 1_500
    private static let replyGapMS = 1_200

    private func noteInputTranscript(_ text: String, startMS: Int?, endMS: Int?) {
        if let startMS, let last = lastInputEndMS, startMS - last > Self.userTurnGapMS {
            flushUserTurn()
        }
        // The reply to the turn before is complete once the user speaks again.
        if userUtterance.isEmpty { flushReply() }
        Self.append(text, to: &userUtterance)
        if let endMS { lastInputEndMS = endMS }
    }

    private func noteOutputTranscript(_ text: String, startMS: Int?, endMS: Int?) {
        if let startMS, let last = lastOutputEndMS, startMS - last > Self.replyGapMS {
            flushReply()
        }
        Self.append(text, to: &replyText)
        if let endMS { lastOutputEndMS = endMS }
    }

    private func flushReply() {
        guard !replyText.isEmpty else { return }
        transcript?.record(.rafuSaid(replyText))
        replyText = ""
    }

    /// Appends up to `maximumFieldBytes`; the transcript cuts the rest anyway.
    private static func append(_ text: String, to buffer: inout String) {
        guard buffer.utf8.count < VoiceDebugTranscript.maximumFieldBytes else { return }
        buffer += text
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
        endThinkingIfStalled(at: now)
        suspendEngineIfQuiet(at: now)
        switch clock.nextAction(at: now) {
        case .checkIn:
            clock.checkedIn = true
            apply(.checkIn)
            checkInPending = true
            if let client {
                Task {
                    try? await client.send(
                        .commentaryAppend(delegationID: nil, "Shall I keep listening?"))
                }
            }
        case .pause:
            clock.paused = true
            apply(.pause)
            micClosed()
        case .close:
            Task { await self.close(reason: .idle) }
        case nil:
            break
        }
    }

    /// The safety net for a Thinking that no reply ends: 8 s with no server
    /// event, 20 s after a delegation or a call result. A running call or a
    /// waiting card holds it. Nothing is cancelled on the server.
    private func endThinkingIfStalled(at now: Duration) {
        guard blobState == .thinking, let since = thinkingSince, inFlightCalls == 0,
            !confirmGate.isPending
        else { return }
        let limit =
            thinkingHadDelegation
            ? dependencies.thinkingNoReplyLimit : dependencies.thinkingNoHearLimit
        guard now - since >= limit else { return }
        let heard = thinkingHadServerEvent
        let hadDelegation = thinkingHadDelegation
        let afterMS = milliseconds(now - thinkingStartedAt)
        apply(.noResponse)
        showNoResponse(
            title: heard ? "No reply" : "Rafu did not hear anything",
            hint: heard ? Self.noReplyHint : Self.silentTurnHint)
        transcript?.record(.noResponse(afterMS: afterMS, hadDelegation: hadDelegation))
    }

    /// Every blob transition goes through here, so the Thinking limit starts
    /// on entry from any path and stops on exit.
    private func apply(_ event: VoiceBlobEvent) {
        let wasThinking = blobState == .thinking
        machine.apply(event)
        guard blobState == .thinking else {
            thinkingSince = nil
            return
        }
        guard !wasThinking else { return }
        let now = elapsed()
        thinkingSince = now
        thinkingStartedAt = now
        // Only a released key enters Thinking before the server did anything.
        thinkingHadDelegation = event != .holdEnded
        thinkingHadServerEvent = event != .holdEnded
    }

    // MARK: Tool host

    func latchFromTool() {
        guard machine.mic != .latched else { return }
        currentTurn?.audio.held = false
        apply(.latchToggled)
        clock.setLatched(true, at: elapsed())
        micOpened()
    }

    func confirm(_ request: VoiceConfirmRequest) async -> VoiceConfirmAnswer {
        guard !confirmGate.isPending else { return .busy }
        let row = timeline.append(
            lane: .tool, startMS: milliseconds(elapsed()), persona: personaName,
            title: "Confirm \(request.tool.rawValue)")
        apply(.needsConfirm)
        cardDelegationIndex = delegationCount
        let answer = await confirmGate.ask(
            request, timeout: dependencies.confirmTimeout, present: dependencies.presentConfirm)
        apply(.confirmResolved)
        transcript?.record(.confirm(tool: request.tool.rawValue, answer: answer.timelineWord))
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

/// One capture stream and the numbers its sender collects. Main actor only.
final class VoiceCaptureTurn {
    let frames: AsyncStream<Data>
    let openedAt: Duration
    /// `serverEventCount` when the stream began.
    let eventMark: Int
    var closedAt: Duration?
    var audio: VoiceDebugTranscript.TurnAudio
    /// Consecutive frames at or above the speech level.
    private var run = 0

    init(frames: AsyncStream<Data>, held: Bool, openedAt: Duration, eventMark: Int) {
        self.frames = frames
        self.openedAt = openedAt
        self.eventMark = eventMark
        audio = VoiceDebugTranscript.TurnAudio(held: held)
    }

    /// The same rule as the barge-in check, for this stream only.
    func note(rms: Double) {
        audio.frames += 1
        audio.maxRMS = max(audio.maxRMS, Int(rms))
        let loud = rms >= VoiceAudioFormat.localSpeechRMS
        if loud { audio.loudFrames += 1 }
        run = loud ? run + 1 : 0
        if run >= VoiceAudioFormat.localSpeechFrames { audio.heardSpeech = true }
    }

    func take(_ stats: VoiceCaptureStats, beforeStart: Bool) {
        audio.dropped += stats.dropped
        if beforeStart { audio.bufferedBeforeStart += stats.yielded }
    }
}
