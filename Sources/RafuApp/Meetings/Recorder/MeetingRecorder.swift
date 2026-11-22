import Foundation
import RafuCore

/// Why `start(title:)` did not give a recording.
nonisolated enum MeetingRecorderError: Error, Hashable, Sendable {
    case problem(MeetingCaptureProblem)
    /// No meeting library is registered.
    case noLibrary
    /// A stop is running; try again when it ends.
    case busy
    /// Stop was pressed while the recording was starting.
    case cancelled
}

/// The facts of the running recording for the start view and the status
/// surfaces: the microphone in use and why, and the output device.
nonisolated struct MeetingRecorderStartFacts: Hashable, Sendable {
    var meeting: MeetingID
    var microphone: MeetingMicrophoneResolution?
    var microphoneDevice: MeetingAudioDeviceFacts?
    var outputDevice: MeetingAudioDeviceFacts?
    /// The "Them" sound came out of the built-in speakers: the microphone
    /// hears the far side, and the turn builder marks echo.
    var outputWasSpeakers: Bool
}

/// The parts the recorder needs. Tests pass fakes.
nonisolated struct MeetingRecorderDependencies: Sendable {
    var microphone: any MeetingAudioSource
    var systemAudio: any MeetingAudioSource
    var permissions: any MeetingPermissionChecking
    var playingProcesses: any MeetingPlayingProcessListing
    var hostClock: any MeetingHostClock
    var diagnostics: any MeetingDiagnosticsRecording
    var store: @Sendable () async -> (any MeetingStoring)?
    /// Seconds of a monotonic clock, for the health checks.
    var now: @Sendable () -> TimeInterval
    /// Production runs a 1 s timer that calls `tick(now:)`; tests call it.
    var runsTimers: Bool = true
    var segmentSeconds: TimeInterval = 10
    /// Pause between tries to open a device again after a change.
    var restartDelay: Duration = .milliseconds(500)
    var restartAttempts: Int = 3
    /// Runs when a Stop arrives while the recording is starting (tests use
    /// it to order a Stop against the start work).
    var onStopWhileStarting: (@Sendable () async -> Void)?
}

/// The one recorder of the app. It records "Me" and "Them" into the
/// crash-safe journal, gives 16 kHz mono chunks on the meeting clock to the
/// live text engines (`liveAudio()`), and reports each problem. A meeting
/// is not tied to a workspace: the recorder holds only meeting ids and the
/// library's audio folder. A second recording can start while an earlier
/// meeting is processing.
///
/// Concurrency: an actor. Effects that start or stop sources (pause,
/// resume, stop, a rebuild after a device change) run one after another
/// through `serially`, so a Resume never overlaps the Pause before it.
/// Blocks arrive on one task per source run; an event from an older run
/// (its generation) is ignored.
@available(macOS 26, *)
actor MeetingRecorder: MeetingRecorderControlling {
    private nonisolated struct TrackWindow {
        var blocks = 0
        var silentBlocks = 0
        var lateBlocks = 0
        var peakDBFS = MeetingBlockLevels.floorDBFS
        var powerSum = 0.0
        var frames = 0
    }

    private nonisolated struct TrackRun {
        var generation = 0
        var facts: MeetingAudioSourceFacts?
        var consumer: Task<Void, Never>?
        var eventTask: Task<Void, Never>?
        var health: MeetingTrackHealthMonitor
        var firstBufferSeen = false
        var lastBlockEnd: TimeInterval?
        var window = TrackWindow()
        var reportedFindings: Set<MeetingTrackFinding> = []
    }

    private nonisolated struct Session {
        let meeting: MeetingID
        let clock: MeetingClock
        let audioFolder: URL
        let journal: MeetingAudioJournalWriter
        var facts: MeetingRecordingFacts
        var startFacts: MeetingRecorderStartFacts
        var tracks: [MeetingTrack: TrackRun]
        var lastFlowRecord: TimeInterval
    }

    private let dependencies: MeetingRecorderDependencies
    private var phase: MeetingRecorderPhase = .idle
    private var session: Session?
    private var startTask: Task<MeetingID, any Error>?
    private var operation: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var nextGeneration = 1

    private nonisolated let stateBroadcast = MeetingRecorderBroadcast<MeetingRecorderState>(
        initial: .idle, replaysLatest: true)
    private nonisolated let eventBroadcast = MeetingRecorderBroadcast<MeetingRecorderEvent>(
        replaysLatest: false)
    private nonisolated let liveBroadcast = MeetingRecorderBroadcast<MeetingAudioChunk>(
        replaysLatest: false, bufferingPolicy: .bufferingNewest(256))

    /// The level of each track, read by the interface at its own pace.
    nonisolated let levels = MeetingLevelMeters()

    init(dependencies: MeetingRecorderDependencies) {
        self.dependencies = dependencies
    }

    // MARK: MeetingRecorderControlling

    nonisolated var states: AsyncStream<MeetingRecorderState> { stateBroadcast.subscribe() }

    /// Events beside the state (started, first buffer, a problem on one
    /// track that did not stop the recording).
    nonisolated var events: AsyncStream<MeetingRecorderEvent> { eventBroadcast.subscribe() }

    /// The converted audio of both tracks for the live text engines, until
    /// the current (or next) recording stops. Newest chunks win when a
    /// reader is slow.
    nonisolated func liveAudio() -> AsyncStream<MeetingAudioChunk> { liveBroadcast.subscribe() }

    /// The current state, for tests and for a view that needs one value.
    var state: MeetingRecorderState { phase.state }

    /// The facts of the running recording, or nil.
    var startFacts: MeetingRecorderStartFacts? { session?.startFacts }

    func start(title: String) async throws -> MeetingID {
        if let startTask { return try await startTask.value }
        switch phase {
        case .recording(let id), .paused(let id): return id
        case .stopping: throw MeetingRecorderError.busy
        case .idle, .starting, .problem: break
        }
        guard apply(.start) == .beginStart else { throw MeetingRecorderError.busy }
        let task = Task { try await self.performStart(title: title) }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    func pause() async {
        guard case .pauseCapture(let id) = apply(.pause) else { return }
        await serially { await self.performPause(id) }
    }

    func resume() async {
        guard case .resumeCapture(let id) = apply(.resume) else { return }
        await serially { await self.performResume(id) }
    }

    func stop() async {
        let effect = apply(.stop)
        if case .beginStop(let id) = effect {
            await serially { await self.performStop(id) }
            return
        }
        if case .starting = phase, let startTask {
            // The start sees the request and closes what it opened.
            await dependencies.onStopWhileStarting?()
            _ = try? await startTask.value
            return
        }
        // A stop that a fault started may be running: wait for it.
        await operation?.value
    }

    /// Closes a problem message.
    func dismissProblem() {
        _ = apply(.dismissProblem)
    }

    // MARK: Start

    private func performStart(title: String) async throws -> MeetingID {
        let diagnostics = dependencies.diagnostics

        // 1. Permissions, at each Start: the microphone first (its prompt
        //    comes first), then system audio.
        var microphone = await dependencies.permissions.microphoneState()
        if microphone == .notDetermined {
            microphone = await dependencies.permissions.requestMicrophone() ? .granted : .denied
        }
        let systemAudio = await dependencies.permissions.systemAudioState()
        diagnostics.record(
            .permissions(microphone: microphone, systemAudio: systemAudio), meeting: nil)
        if microphone == .denied { return try failStart(.missingMicrophonePermission) }
        if systemAudio == .denied { return try failStart(.missingSystemAudioPermission) }
        if case .starting(true) = phase { return try failStart(nil) }

        // 2. The meeting and its audio folder.
        guard let store = await dependencies.store() else {
            // Back to idle with no problem flash: no library is a wiring
            // fault, not a capture problem.
            _ = apply(.stop)
            _ = apply(.startFailed(.deviceLost))
            throw MeetingRecorderError.noLibrary
        }
        let startDate = Date()
        let meeting: MeetingID
        let audioFolder: URL
        do {
            meeting = try await store.create(title: title, startDate: startDate).id
            audioFolder = try await store.audioFolder(for: meeting)
        } catch {
            diagnostics.record(
                .userFacingError(
                    place: .recorder, domain: MeetingDiagnosticString((error as NSError).domain),
                    code: (error as NSError).code), meeting: nil)
            return try failStart(.diskFull)
        }

        // 3. The clock and the journal.
        let clock = MeetingClock(
            startHostTime: dependencies.hostClock.now(), timebase: dependencies.hostClock.timebase)
        let journal = MeetingAudioJournalWriter(
            audioFolder: audioFolder, segmentSeconds: dependencies.segmentSeconds,
            diagnostics: diagnostics, meeting: meeting)
        do {
            try journal.prepare()
        } catch {
            try? await store.delete(meeting)
            return try failStart(.diskFull)
        }

        // 4. Both sources. The microphone must start; a failed call-audio
        //    tap also fails the start, so no recording silently lacks "Them".
        let meRun: MeetingAudioSourceRun
        let themRun: MeetingAudioSourceRun
        do {
            meRun = try await dependencies.microphone.start(
                meeting: meeting, diagnostics: diagnostics)
        } catch {
            try? await store.delete(meeting)
            return try failStart(Self.problem(for: error, track: .me))
        }
        do {
            themRun = try await dependencies.systemAudio.start(
                meeting: meeting, diagnostics: diagnostics)
        } catch {
            await dependencies.microphone.stop()
            try? await store.delete(meeting)
            return try failStart(Self.problem(for: error, track: .them))
        }

        // 5. Start facts for diagnostics (no title, no path).
        diagnostics.record(
            .devices(input: meRun.facts.device, output: themRun.facts.device), meeting: meeting)
        if let resolution = meRun.facts.microphone {
            diagnostics.record(
                .microphoneChoice(kind: resolution.kind, reason: resolution.reason),
                meeting: meeting)
        }
        let playing = await dependencies.playingProcesses.playingBundleIDs()
        diagnostics.record(
            .playingProcesses(bundleIDs: playing.map { MeetingDiagnosticString($0) }),
            meeting: meeting)

        let now = dependencies.now()
        let startFacts = MeetingRecorderStartFacts(
            meeting: meeting, microphone: meRun.facts.microphone,
            microphoneDevice: meRun.facts.device, outputDevice: themRun.facts.device,
            outputWasSpeakers: themRun.facts.outputIsBuiltInSpeakers)
        session = Session(
            meeting: meeting, clock: clock, audioFolder: audioFolder, journal: journal,
            facts: MeetingRecordingFacts(
                meeting: meeting, startDate: startDate,
                outputWasSpeakers: themRun.facts.outputIsBuiltInSpeakers),
            startFacts: startFacts,
            tracks: [
                .me: TrackRun(health: MeetingTrackHealthMonitor(track: .me, startedAt: now)),
                .them: TrackRun(health: MeetingTrackHealthMonitor(track: .them, startedAt: now)),
            ],
            lastFlowRecord: now)
        attach(meRun, track: .me)
        attach(themRun, track: .them)
        writeFacts()

        // 6. A Stop that came while starting closes it all again.
        let effect = apply(.startSucceeded(meeting))
        if case .abandonStart = effect {
            await stopSources()
            session = nil
            try? await store.delete(meeting)
            levels.reset()
            throw MeetingRecorderError.cancelled
        }
        eventBroadcast.send(.started(meeting))
        if dependencies.runsTimers { startTimer() }
        return meeting
    }

    /// Ends a failed start. `problem` nil: a Stop came while starting.
    private func failStart(_ problem: MeetingCaptureProblem?) throws -> MeetingID {
        guard let problem else {
            _ = apply(.startFailed(.noBuffers))
            throw MeetingRecorderError.cancelled
        }
        _ = apply(.startFailed(problem))
        dependencies.diagnostics.record(
            .userFacingError(place: .capture, domain: "MeetingCaptureProblem", code: problem.code),
            meeting: nil)
        if case .problem = phase { eventBroadcast.send(.problem(problem)) }
        if case .idle = phase { throw MeetingRecorderError.cancelled }
        throw MeetingRecorderError.problem(problem)
    }

    private static func problem(for error: any Error, track: MeetingTrack) -> MeetingCaptureProblem
    {
        switch error as? MeetingAudioSourceError {
        case .permissionDenied:
            track == .me ? .missingMicrophonePermission : .missingSystemAudioPermission
        case .noDevice, .failed, nil:
            .deviceLost
        }
    }

    // MARK: Source runs

    private func source(_ track: MeetingTrack) -> any MeetingAudioSource {
        track == .me ? dependencies.microphone : dependencies.systemAudio
    }

    private func attach(_ run: MeetingAudioSourceRun, track: MeetingTrack) {
        guard session != nil else { return }
        let generation = nextGeneration
        nextGeneration += 1
        let blocks = run.blocks
        let events = run.events
        session?.tracks[track]?.generation = generation
        session?.tracks[track]?.facts = run.facts
        session?.tracks[track]?.consumer = Task {
            for await block in blocks {
                self.ingest(block, track: track)
            }
        }
        session?.tracks[track]?.eventTask = Task {
            for await event in events {
                await self.handle(event, track: track, generation: generation)
            }
        }
    }

    /// Stops both sources and waits until every block they gave is written.
    private func stopSources() async {
        await dependencies.microphone.stop()
        await dependencies.systemAudio.stop()
        for track in MeetingTrack.allCases {
            await session?.tracks[track]?.consumer?.value
            session?.tracks[track]?.eventTask?.cancel()
            session?.tracks[track]?.consumer = nil
            session?.tracks[track]?.eventTask = nil
        }
    }

    private func ingest(_ block: MeetingCapturedBlock, track: MeetingTrack) {
        // A block of an older run of the same recording is still good audio
        // (it can arrive after a rebuild has started the next run); the
        // journal places it by its time.
        // Blocks still in the stream at Pause or Stop were captured before
        // it, so they are kept too.
        guard let id = phase.state.meeting, var run = session?.tracks[track],
            let session, session.meeting == id, !block.samples.isEmpty
        else { return }
        let startTime = session.clock.seconds(atHostTime: block.hostTime)
        let levels = block.samples.withUnsafeBufferPointer { MeetingBlockLevels.measure($0) }
        let now = dependencies.now()

        if !run.firstBufferSeen {
            run.firstBufferSeen = true
            dependencies.diagnostics.record(
                .firstBuffer(track: track, frames: block.samples.count), meeting: id)
            eventBroadcast.send(.firstBuffer(id, track))
        }
        if let end = run.lastBlockEnd,
            abs(startTime - end) > MeetingAudioJournalWriter.reanchorTolerance
        {
            run.window.lateBlocks += 1
        }
        run.lastBlockEnd = startTime + Double(block.samples.count) / MeetingAudioFormat.sampleRate
        run.health.noteBuffer(at: now, silent: levels.isDigitalSilence)
        run.window.blocks += 1
        run.window.frames += block.samples.count
        if levels.isDigitalSilence { run.window.silentBlocks += 1 }
        run.window.peakDBFS = max(run.window.peakDBFS, levels.peakDBFS)
        run.window.powerSum += pow(10, levels.meanDBFS / 10) * Double(block.samples.count)
        self.session?.tracks[track] = run
        self.levels.set(track, peakDBFS: levels.peakDBFS)

        do {
            try session.journal.append(track: track, samples: block.samples, startTime: startTime)
        } catch {
            fault(.diskFull, error: error)
            return
        }
        let samples = block.samples.withUnsafeBytes { Data($0) }
        liveBroadcast.send(
            MeetingAudioChunk(
                track: track, samples: samples, startTime: startTime,
                frameCount: block.samples.count))
    }

    private func handle(_ event: MeetingAudioSourceEvent, track: MeetingTrack, generation: Int)
        async
    {
        switch event {
        case .interrupted(let old):
            guard case .recording = phase, session?.tracks[track]?.generation == generation else {
                return
            }
            await serially { await self.rebuild(track, old: old, generation: generation) }
        }
    }

    /// Opens a source again after a device change or loss: records a gap
    /// span, keeps the other track running, and reads the rate again (the
    /// source's `start`).
    private func rebuild(_ track: MeetingTrack, old: MeetingAudioDeviceFacts?, generation: Int)
        async
    {
        guard case .recording(let id) = phase, let current = session,
            current.tracks[track]?.generation == generation
        else { return }
        let gapStart = clockNow()
        session?.facts.spans.append(MeetingRecordingSpan(kind: .gap(track), start: gapStart))
        let spanIndex = (session?.facts.spans.count ?? 1) - 1
        try? session?.journal.close(track)

        var lastError: (any Error)?
        for attempt in 0..<max(1, dependencies.restartAttempts) {
            if attempt > 0 { try? await Task.sleep(for: dependencies.restartDelay) }
            guard case .recording(let stillID) = phase, stillID == id else { return }
            do {
                let run = try await source(track).start(
                    meeting: id, diagnostics: dependencies.diagnostics)
                guard case .recording(let afterID) = phase, afterID == id else {
                    await source(track).stop()
                    return
                }
                let gapEnd = clockNow()
                session?.facts.spans[spanIndex].end = gapEnd
                session?.tracks[track]?.health.noteRestart(at: dependencies.now())
                session?.tracks[track]?.lastBlockEnd = nil
                attach(run, track: track)
                dependencies.diagnostics.record(
                    .deviceChanged(track: track, old: old, new: run.facts.device), meeting: id)
                if track == .them {
                    let speakers =
                        (session?.facts.outputWasSpeakers ?? false)
                        || run.facts.outputIsBuiltInSpeakers
                    session?.facts.outputWasSpeakers = speakers
                    session?.startFacts.outputDevice = run.facts.device
                    session?.startFacts.outputWasSpeakers = speakers
                } else {
                    session?.startFacts.microphone = run.facts.microphone
                    session?.startFacts.microphoneDevice = run.facts.device
                }
                writeFacts()
                return
            } catch {
                lastError = error
            }
        }
        dependencies.diagnostics.record(
            .deviceChanged(track: track, old: old, new: nil), meeting: id)
        if track == .me {
            fault(.deviceLost, error: lastError)
        } else {
            report(.deviceLost, meeting: id)
            writeFacts()
        }
    }

    // MARK: Pause, resume, stop

    private func performPause(_ id: MeetingID) async {
        guard case .paused(id) = phase else { return }
        let pauseStart = clockNow()
        session?.facts.spans.append(MeetingRecordingSpan(kind: .paused, start: pauseStart))
        dependencies.diagnostics.record(.recordingPaused, meeting: id)
        await stopSources()
        do {
            try session?.journal.flush()
        } catch {
            fault(.diskFull, error: error)
        }
        writeFacts()
        levels.reset()
        eventBroadcast.send(.paused(id))
    }

    private func performResume(_ id: MeetingID) async {
        guard case .recording(id) = phase else { return }
        if let index = session?.facts.spans.lastIndex(where: { $0.kind == .paused }) {
            let pauseEnd = clockNow()
            session?.facts.spans[index].end = pauseEnd
        }
        dependencies.diagnostics.record(.recordingResumed, meeting: id)
        let now = dependencies.now()
        for track in MeetingTrack.allCases {
            do {
                let run = try await source(track).start(
                    meeting: id, diagnostics: dependencies.diagnostics)
                guard case .recording(id) = phase else {
                    await source(track).stop()
                    return
                }
                session?.tracks[track]?.health.noteRestart(at: now)
                session?.tracks[track]?.lastBlockEnd = nil
                attach(run, track: track)
            } catch {
                if track == .me {
                    fault(Self.problem(for: error, track: .me), error: error)
                    return
                }
                report(Self.problem(for: error, track: .them), meeting: id)
            }
        }
        writeFacts()
        eventBroadcast.send(.resumed(id))
    }

    private func performStop(_ id: MeetingID) async {
        guard case .stopping(id, _) = phase else { return }
        timerTask?.cancel()
        timerTask = nil
        await stopSources()
        let diagnostics = dependencies.diagnostics
        if let current = session {
            try? current.journal.flush()
            let end = clockNow()
            session?.facts.endTime = end
            for index in session?.facts.spans.indices ?? 0..<0
            where session?.facts.spans[index].end == nil {
                session?.facts.spans[index].end = end
            }
            writeFacts()
            do {
                let report = try MeetingAudioJournalRecovery.recover(
                    audioFolder: current.audioFolder, diagnostics: diagnostics, meeting: id)
                if report.result == .recovered {
                    try? MeetingAudioJournalRecovery.removeJournal(in: current.audioFolder)
                }
            } catch {
                diagnostics.record(
                    .journalRecovery(result: .failed, recoveredSeconds: 0), meeting: id)
            }
            diagnostics.record(
                .recordingStopped(recordedSeconds: session?.facts.recordedSeconds ?? 0),
                meeting: id)
            await markProcessing(id)
        }
        session = nil
        liveBroadcast.finishAll()
        levels.reset()
        let problem: MeetingCaptureProblem? =
            if case .stopping(_, let problem) = phase { problem } else { nil }
        _ = apply(.stopFinished)
        eventBroadcast.send(.stopped(id))
        if let problem { eventBroadcast.send(.problem(problem)) }
    }

    private func markProcessing(_ id: MeetingID) async {
        guard let store = await dependencies.store() else { return }
        for _ in 0..<2 {
            guard let summary = try? await store.summary(of: id) else { return }
            do {
                try await store.setState(.processing, of: id, expectedVersion: summary.version)
                return
            } catch is MeetingVersionConflict {
                continue
            } catch {
                return
            }
        }
    }

    // MARK: Health and flow

    /// The 1 s check: the health of each track and, each 10 s, the flow
    /// counters. Tests call it with their own time.
    func tick(now: TimeInterval) async {
        guard case .recording(let id) = phase, session != nil else { return }
        let playing = await dependencies.playingProcesses.playingBundleIDs()
        guard case .recording(id) = phase, session?.meeting == id else { return }
        for track in MeetingTrack.allCases {
            guard
                let finding = session?.tracks[track]?.health.evaluate(
                    at: now, othersPlaying: !playing.isEmpty)
            else { continue }
            switch (track, finding) {
            case (.me, .noBuffers):
                fault(.noBuffers, error: nil)
                return
            case (.me, .silentWhilePlaying):
                report(.missingMicrophonePermission, meeting: id)
            case (.them, .noBuffers):
                report(.noBuffers, meeting: id)
            case (.them, .silentWhilePlaying):
                report(.missingSystemAudioPermission, meeting: id)
            }
        }
        if let last = session?.lastFlowRecord, now - last >= 10 {
            session?.lastFlowRecord = now
            for track in MeetingTrack.allCases {
                let callback = await source(track).takeCallbackCounters()
                guard let window = session?.tracks[track]?.window else { continue }
                session?.tracks[track]?.window = TrackWindow()
                let mean =
                    window.frames > 0
                    ? max(
                        MeetingBlockLevels.floorDBFS,
                        10 * log10(max(window.powerSum / Double(window.frames), 1e-16)))
                    : MeetingBlockLevels.floorDBFS
                dependencies.diagnostics.record(
                    .trackFlow(
                        track: track,
                        counters: MeetingTrackFlowCounters(
                            buffers: callback.buffers > 0 ? callback.buffers : window.blocks,
                            frames: callback.frames > 0 ? callback.frames : window.frames,
                            silentBuffers: window.silentBlocks,
                            droppedBuffers: callback.droppedBuffers,
                            lateBuffers: window.lateBlocks, peakLevelDBFS: window.peakDBFS,
                            meanLevelDBFS: mean, converterErrors: callback.converterErrors)),
                    meeting: id)
            }
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        let now = dependencies.now
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self.tick(now: now())
            }
        }
    }

    /// A problem that stops the recording; the audio so far is kept.
    private func fault(_ problem: MeetingCaptureProblem, error: (any Error)?) {
        let code: Int =
            if case .diskFull? = error as? MeetingJournalError { 28 } else { problem.code }
        dependencies.diagnostics.record(
            .userFacingError(place: .recorder, domain: "MeetingCaptureProblem", code: code),
            meeting: session?.meeting)
        guard case .beginStop(let id) = apply(.fault(problem)) else { return }
        operation = chained { await self.performStop(id) }
    }

    /// A problem on one track that does not stop the recording (the other
    /// track keeps recording). Reported once until the track recovers.
    private func report(_ problem: MeetingCaptureProblem, meeting: MeetingID) {
        dependencies.diagnostics.record(
            .userFacingError(place: .capture, domain: "MeetingCaptureProblem", code: problem.code),
            meeting: meeting)
        eventBroadcast.send(.problem(problem))
    }

    // MARK: Helpers

    @discardableResult
    private func apply(_ command: MeetingRecorderCommand) -> MeetingRecorderEffect {
        let transition = MeetingRecorderMachine.transition(from: phase, on: command)
        let changed = transition.phase.state != phase.state
        phase = transition.phase
        if changed { stateBroadcast.send(phase.state) }
        return transition.effect
    }

    private func chained(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = operation
        return Task {
            await previous?.value
            await work()
        }
    }

    /// Runs `work` after every earlier effect and waits for it.
    private func serially(_ work: @escaping @Sendable () async -> Void) async {
        let task = chained(work)
        operation = task
        await task.value
    }

    private func clockNow() -> TimeInterval {
        session?.clock.seconds(atHostTime: dependencies.hostClock.now()) ?? 0
    }

    private func writeFacts() {
        guard let session else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session.facts) else { return }
        try? data.write(
            to: session.audioFolder.appending(path: MeetingRecordingFacts.fileName),
            options: .atomic)
    }

    /// Makes the final audio files of a meeting whose recording did not end
    /// (Rafu quit or crashed). Safe to run more than once.
    func recoverAbandoned(_ meeting: MeetingID) async throws -> MeetingJournalRecoveryReport {
        guard let store = await dependencies.store() else { throw MeetingRecorderError.noLibrary }
        let folder = try await store.audioFolder(for: meeting)
        return try MeetingAudioJournalRecovery.recover(
            audioFolder: folder, diagnostics: dependencies.diagnostics, meeting: meeting)
    }
}

extension MeetingCaptureProblem {
    /// A stable number for diagnostics.
    nonisolated var code: Int {
        switch self {
        case .missingMicrophonePermission: 1
        case .missingSystemAudioPermission: 2
        case .noBuffers: 3
        case .deviceLost: 4
        case .diskFull: 5
        }
    }
}
