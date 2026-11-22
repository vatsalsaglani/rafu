import Foundation
import RafuCore

/// Drives `MeetingsSessionModel` from the real parts: the recorder, the
/// live text engines and the processing queue. It installs the session
/// handlers. Nothing at audio rate runs on the main actor: levels 10 times
/// a second, live turns about 3 times a second, progress 5 times a second.
final class MeetingsSessionDriver {
    /// The timer step of the levels and the warning rules.
    static let tick: Duration = .milliseconds(100)
    /// Ticks between two elapsed-time updates (0.5 s).
    static let elapsedTicks = 5
    /// Ticks between two live-turn updates (0.3 s; at most 4 a second).
    static let turnTicks = 3
    static let liveTurnLimit = 200

    private weak var feature: MeetingsFeature?
    let session: MeetingsSessionModel
    let runner: MeetingProcessingRunner
    private let recorder: any MeetingRecorderControlling
    private let feeds: (any MeetingsRecorderFeeds)?
    private let preferences: any MeetingPreferencesReading
    private let createdAt = Date()

    private var live: MeetingsLiveText?
    /// The meeting of the running recording, from `.started` until `.stopped`.
    private var activeMeeting: MeetingID?
    /// Meetings whose `.stopped` event was handled. A start result that
    /// comes later (a busy main actor) must not make one live again.
    private var stoppedMeetings: Set<MeetingID> = []
    private var isStarting = false
    private var controlChain: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// The scan for interrupted meetings at start; tests await it.
    private(set) var startupScan: Task<Void, Never>?
    private var previousState: MeetingRecorderState = .idle
    private var rules = MeetingLiveWarningRules()
    private var recordedBefore: Duration = .zero
    private var runningSince: ContinuousClock.Instant?

    init(
        feature: MeetingsFeature, recorder: any MeetingRecorderControlling,
        feeds: (any MeetingsRecorderFeeds)?,
        preferences: any MeetingPreferencesReading = UserDefaultsMeetingPreferences()
    ) {
        self.feature = feature
        self.session = feature.session
        self.recorder = recorder
        self.feeds = feeds
        self.preferences = preferences
        self.runner = MeetingProcessingRunner(
            feature: feature, session: feature.session, preferences: preferences)
        runner.isLiveMeeting = { [weak self] meeting in self?.activeMeeting == meeting }
    }

    /// Installs the handlers and starts reading the recorder. Opens no
    /// device and starts no process; it reads the meeting list one time.
    func install() {
        session.handlers = MeetingsSessionHandlers(
            start: { [weak self] title in self?.start(title: title) },
            pause: { [weak self] in self?.control { await $0.pause() } },
            resume: { [weak self] in self?.control { await $0.resume() } },
            stop: { [weak self] in self?.stop() },
            dismissProblem: { [weak self] in self?.dismissProblem() },
            retryProcessing: { [weak self] meeting in self?.retry(meeting) },
            cancelProcessing: { [weak self] meeting in self?.runner.cancel(meeting) },
            remakeText: { [weak self] meeting, engine in self?.remake(meeting, with: engine) },
            deleteMeeting: { [weak self] meeting in self?.delete(meeting) })
        session.isDriverInstalled = true

        let states = recorder.states
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.apply(state)
            }
        }
        if let events = feeds?.events {
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
        }
        startupScan = Task { [weak self] in await self?.markInterruptedMeetings() }
    }

    /// Ends each task (tests).
    func shutdown() {
        stateTask?.cancel()
        eventTask?.cancel()
        startupScan?.cancel()
        stopLive()
        runner.cancelAll()
    }

    // MARK: Start, pause, resume, stop

    private func start(title: String?) {
        guard session.canStartRecording, !isStarting, let feature else { return }
        session.startFailure = nil
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? MeetingDefaultTitle.text(for: Date()) : trimmed
        session.liveTitle = name
        isStarting = true
        // Subscribe to the audio before the recorder starts; make the live
        // sessions while it starts (the recording never waits for them).
        live?.close()
        live = MeetingsLiveText(
            session: session, audio: feeds?.liveAudio(), engines: feature.textEngines,
            preference: preferences.speechPreferences().textEngine,
            diagnostics: feature.diagnostics)
        let recorder = recorder
        Task { [weak self] in
            do {
                let meeting = try await recorder.start(title: name)
                self?.startSucceeded(meeting)
            } catch {
                self?.startFailed(error)
            }
        }
    }

    private func startSucceeded(_ meeting: MeetingID) {
        isStarting = false
        recordingStarted(meeting)
    }

    private func startFailed(_ error: any Error) {
        isStarting = false
        if activeMeeting == nil { stopLive() }
        switch error as? MeetingRecorderError {
        case .problem(let problem): session.startFailure = .problem(problem)
        case .busy: session.startFailure = .busy
        case .cancelled: break
        case .noLibrary, nil: session.startFailure = .failed
        }
    }

    /// Runs recorder calls one after another in the order of the clicks.
    private func control(
        _ action: @escaping @Sendable (any MeetingRecorderControlling) async -> Void
    ) {
        let previous = controlChain
        let recorder = recorder
        controlChain = Task {
            await previous?.value
            await action(recorder)
        }
    }

    private func stop() {
        let meeting = activeMeeting
        let usesEvents = feeds != nil
        let previous = controlChain
        let recorder = recorder
        controlChain = Task { [weak self] in
            await previous?.value
            await recorder.stop()
            // Without the event feed, Stop's return is the only signal.
            if !usesEvents, let meeting { self?.recordingStopped(meeting) }
        }
    }

    private func dismissProblem() {
        session.startFailure = nil
        guard let feeds else { return }
        Task { await feeds.dismissProblem() }
    }

    // MARK: Recorder state and events

    private func apply(_ state: MeetingRecorderState) {
        if case .problem(let problem) = state {
            switch previousState {
            case .recording, .paused, .stopping: break
            case .idle, .starting, .problem: session.startFailure = .problem(problem)
            }
        }
        previousState = state
        session.recorderState = state
    }

    private func handle(_ event: MeetingRecorderEvent) {
        switch event {
        case .started(let meeting): recordingStarted(meeting)
        case .paused(let meeting):
            guard meeting == activeMeeting, let since = runningSince else { return }
            recordedBefore += ContinuousClock.now - since
            runningSince = nil
        case .resumed(let meeting):
            guard meeting == activeMeeting, runningSince == nil else { return }
            runningSince = .now
        case .stopped(let meeting): recordingStopped(meeting)
        case .problem(let problem):
            guard activeMeeting != nil else { return }
            rules.apply(problem: problem, lastPeaks: currentPeaks())
            publishWarnings()
        case .firstBuffer: break
        }
    }

    private func recordingStarted(_ meeting: MeetingID) {
        guard activeMeeting != meeting, !stoppedMeetings.contains(meeting) else { return }
        activeMeeting = meeting
        rules = MeetingLiveWarningRules()
        recordedBefore = .zero
        runningSince = .now
        session.liveElapsed = 0
        startTimer()
        guard let feeds else { return }
        Task { [weak self] in
            guard let facts = await feeds.readStartFacts(), facts.meeting == meeting else { return }
            self?.applyStartFacts(facts)
        }
    }

    private func applyStartFacts(_ facts: MeetingRecorderStartFacts) {
        guard activeMeeting == facts.meeting else { return }
        session.microphoneName =
            facts.microphoneDevice?.name.value ?? facts.microphone?.device?.name
        rules.apply(
            usesHeadsetMicrophone: facts.microphone?.usesHeadsetMicrophone == true,
            outputWasSpeakers: facts.outputWasSpeakers)
        publishWarnings()
    }

    private func recordingStopped(_ meeting: MeetingID) {
        guard activeMeeting == meeting else { return }
        activeMeeting = nil
        stoppedMeetings.insert(meeting)
        // A Record that came before this late `.stopped` already made the
        // new recording's live text; closing it would lose that live text.
        if isStarting {
            timerTask?.cancel()
            timerTask = nil
        } else {
            stopLive()
        }
        session.noteLibraryChanged()
        runner.enqueue(meeting)
        let diagnostics = feature?.diagnostics
        Task { await (diagnostics as? MeetingDiagnosticsRecorder)?.flush() }
    }

    /// Ends the live text and the timer, and clears the live state.
    private func stopLive() {
        timerTask?.cancel()
        timerTask = nil
        live?.close()
        live = nil
        runningSince = nil
        recordedBefore = .zero
        rules = MeetingLiveWarningRules()
        session.liveTurns = []
        session.warnings = []
        session.liveElapsed = 0
        session.microphoneName = nil
        session.levels.me = 0
        session.levels.them = 0
    }

    // MARK: Timer

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                // A timer, not a wait for another task.
                try? await Task.sleep(for: Self.tick)
                guard let self, !Task.isCancelled else { return }
                count += 1
                self.timerFired(count)
            }
        }
    }

    private func timerFired(_ count: Int) {
        if feeds != nil {
            let peaks = currentPeaks()
            let me = MeetingLevelScale.unit(fromDBFS: peaks[.me] ?? -160)
            let them = MeetingLevelScale.unit(fromDBFS: peaks[.them] ?? -160)
            if session.levels.me != me { session.levels.me = me }
            if session.levels.them != them { session.levels.them = them }
            rules.apply(meDBFS: peaks[.me] ?? -160, themDBFS: peaks[.them] ?? -160)
            publishWarnings()
        }
        if count % Self.elapsedTicks == 0 {
            var elapsed = recordedBefore
            if let runningSince { elapsed += ContinuousClock.now - runningSince }
            session.liveElapsed =
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        if count % Self.turnTicks == 0, let live, live.hasNewText {
            session.liveTurns = live.publishTurns(limit: Self.liveTurnLimit)
        }
    }

    private func currentPeaks() -> [MeetingTrack: Double] {
        guard let feeds else { return [:] }
        return [.me: feeds.peakDBFS(.me), .them: feeds.peakDBFS(.them)]
    }

    private func publishWarnings() {
        let warnings = rules.warnings.compactMap { MeetingsLiveWarning(rawValue: $0.rawValue) }
        if session.warnings != warnings { session.warnings = warnings }
    }

    // MARK: Processing actions

    private func retry(_ meeting: MeetingID) {
        guard meeting != session.liveMeeting, meeting != activeMeeting else { return }
        runner.enqueue(meeting)
    }

    private func remake(_ meeting: MeetingID, with engine: MeetingTextEngineID) {
        guard meeting != session.liveMeeting, meeting != activeMeeting else { return }
        runner.enqueue(meeting, override: engine)
    }

    private func delete(_ meeting: MeetingID) {
        guard meeting != session.liveMeeting, meeting != activeMeeting, let feature,
            let store = feature.store
        else { return }
        let diagnostics = feature.diagnostics as? MeetingDiagnosticsRecorder
        Task { [weak self] in
            await self?.runner.cancelAndWait(meeting)
            do {
                try await store.delete(meeting)
            } catch {
                feature.diagnostics.record(
                    .userFacingError(
                        place: .library, domain: "delete", code: (error as NSError).code),
                    meeting: meeting)
                return
            }
            await diagnostics?.deleteDiagnostics(for: meeting)
            guard let self else { return }
            self.session.processing[meeting] = nil
            if self.session.windowSelection == meeting { self.session.windowSelection = nil }
            self.session.noteLibraryChanged()
        }
    }

    // MARK: Interrupted meetings

    /// Marks each meeting that the app left in recording, paused or
    /// processing as failed with the code `interrupted`. It does not
    /// process them: the user selects "Try again".
    private func markInterruptedMeetings() async {
        guard let store = feature?.store, let all = try? await store.list() else { return }
        let found = MeetingInterruptedRule.interrupted(
            all.filter { $0.startDate < createdAt }, liveMeeting: session.liveMeeting,
            activeJobs: runner.activeMeetings)
        for meeting in found {
            guard !Task.isCancelled else { return }
            guard meeting.id != session.liveMeeting, meeting.id != activeMeeting,
                !runner.isActive(meeting.id)
            else { continue }
            if meeting.state == .recording || meeting.state == .paused {
                _ = try? await feeds?.recoverAbandoned(meeting.id)
            }
            await runner.markFailed(meeting.id, code: MeetingProcessingFailure.interrupted)
        }
        try? await store.applyAudioRetention(preferences.audioRetention(), now: Date())
    }
}
