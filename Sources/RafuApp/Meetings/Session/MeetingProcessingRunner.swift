import Foundation
import RafuCore
import Synchronization

/// The stored audio of one meeting, read off the main actor before a job.
nonisolated struct MeetingPreparedAudio: Sendable, Equatable {
    /// The final file of each track that exists and holds audio.
    var files: [MeetingTrack: URL]
    /// True when at least one final file exists (it can be empty).
    var hasAnyFile: Bool
    var outputWasSpeakers: Bool
    /// Recorded seconds, when known.
    var duration: TimeInterval?
}

/// A job failure with its stable reason code.
nonisolated struct MeetingProcessingError: Error, Equatable {
    var reasonCode: String
}

/// Drops progress updates that come closer than `interval`.
nonisolated final class MeetingProgressThrottle: Sendable {
    private let last = Mutex<ContinuousClock.Instant?>(nil)
    private let interval: Duration

    init(interval: Duration = .milliseconds(200)) {
        self.interval = interval
    }

    func shouldSend() -> Bool {
        let now = ContinuousClock.now
        return last.withLock { last in
            if let previous = last, now - previous < interval { return false }
            last = now
            return true
        }
    }
}

/// Processes stopped meetings one at a time: stored audio → final text of
/// each track (one call after the other) → speakers of "Them" → turns →
/// echo marks → library. A second meeting waits with the step `.waiting`.
/// A new recording can run while a job runs; the two share no state.
final class MeetingProcessingRunner {
    private struct Job: Equatable {
        var meeting: MeetingID
        var override: MeetingTextEngineID?
    }

    private weak var feature: MeetingsFeature?
    private let session: MeetingsSessionModel
    private let preferences: any MeetingPreferencesReading
    private var queue: [Job] = []
    private var running: (meeting: MeetingID, task: Task<Void, Never>)?
    /// The track whose text progress may change the step now.
    private var progressPhase: (meeting: MeetingID, track: MeetingTrack)?
    /// True for the meeting that still records. The driver sets it from the
    /// recorder's events: the recorder state stream and the event stream
    /// are read by two tasks, so `session.liveMeeting` can still name a
    /// meeting whose `.stopped` event was already handled.
    var isLiveMeeting: (MeetingID) -> Bool

    init(
        feature: MeetingsFeature, session: MeetingsSessionModel,
        preferences: any MeetingPreferencesReading
    ) {
        self.feature = feature
        self.session = session
        self.preferences = preferences
        self.isLiveMeeting = { [weak session] meeting in session?.liveMeeting == meeting }
    }

    /// The meetings that wait or run now.
    var activeMeetings: Set<MeetingID> {
        var result = Set(queue.map(\.meeting))
        if let running { result.insert(running.meeting) }
        return result
    }

    func isActive(_ meeting: MeetingID) -> Bool { activeMeetings.contains(meeting) }

    /// Queues a meeting. A meeting that waits is ignored, and so is one
    /// whose job still works. A job that already showed its result (ready
    /// or failed) can be finishing its last writes: the new job waits for it.
    func enqueue(_ meeting: MeetingID, override: MeetingTextEngineID? = nil) {
        guard !queue.contains(where: { $0.meeting == meeting }) else { return }
        if running?.meeting == meeting {
            switch session.processing[meeting] {
            case nil, .failed?: break
            case .some: return
            }
        }
        queue.append(Job(meeting: meeting, override: override))
        session.processing[meeting] = .waiting
        startNext()
    }

    /// Cancels the job of a meeting; the meeting becomes failed with the
    /// code `cancelled`. The running engines stop on task cancellation.
    func cancel(_ meeting: MeetingID) {
        if let index = queue.firstIndex(where: { $0.meeting == meeting }) {
            queue.remove(at: index)
            Task { await self.markFailed(meeting, code: MeetingProcessingFailure.cancelled) }
            return
        }
        if running?.meeting == meeting { running?.task.cancel() }
    }

    /// Cancels the job of a meeting and waits until it ended.
    func cancelAndWait(_ meeting: MeetingID) async {
        queue.removeAll { $0.meeting == meeting }
        guard let running, running.meeting == meeting else { return }
        running.task.cancel()
        await running.task.value
    }

    /// Cancels each job (tests and shutdown).
    func cancelAll() {
        queue = []
        running?.task.cancel()
    }

    private func startNext() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let task = Task { [weak self] in
            let diagnostics = await self?.run(job)
            self?.jobEnded(job.meeting)
            // After each job, so an export right after a call holds each event.
            await (diagnostics as? MeetingDiagnosticsRecorder)?.flush()
        }
        running = (job.meeting, task)
    }

    private func jobEnded(_ meeting: MeetingID) {
        if running?.meeting == meeting { running = nil }
        startNext()
    }

    // MARK: One job

    /// Returns the diagnostics recorder to flush.
    private func run(_ job: Job) async -> (any MeetingDiagnosticsRecording)? {
        let meeting = job.meeting
        guard let feature, let store = feature.store else {
            session.processing[meeting] = .failed(reasonCode: MeetingProcessingFailure.libraryWrite)
            return nil
        }
        let diagnostics = feature.diagnostics
        do {
            guard try await beginJob(job, store: store) else {
                session.processing[meeting] = nil
                return diagnostics
            }
            session.processing[meeting] = .preparingModel
            let folder = try await store.audioFolder(for: meeting)
            let audio = await Self.prepareAudio(
                folder: folder, meeting: meeting, diagnostics: diagnostics)
            try Task.checkCancellation()
            guard audio.hasAnyFile else {
                throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.noAudio)
            }
            let plan = await makePlan(override: job.override, feature: feature)
            let text = try await transcribeTracks(
                meeting, audio: audio, plan: plan, feature: feature)
            let speakers = await findSpeakers(
                meeting, audio: audio, engine: plan.speakerEngine, feature: feature)
            try Task.checkCancellation()

            session.processing[meeting] = .finishing
            let marking = MeetingTranscriptAssembly.assemble(
                me: text.me, them: text.them, segments: speakers.segments,
                outputWasSpeakers: audio.outputWasSpeakers)
            let engines = MeetingProcessingPlan.engineUse(
                me: text.me, them: text.them, textEngine: text.engine,
                speakerEngine: speakers.engine)
            try await writeResult(
                marking.turns, engines: engines, duration: audio.duration, of: meeting,
                in: store)
            session.processing[meeting] = nil
            session.noteLibraryChanged()
            try? await store.applyAudioRetention(preferences.audioRetention(), now: Date())
        } catch {
            let code =
                Task.isCancelled || error is CancellationError
                ? MeetingProcessingFailure.cancelled
                : (error as? MeetingProcessingError)?.reasonCode
                    ?? MeetingProcessingFailure.textFailed
            await markFailed(meeting, code: code)
        }
        return diagnostics
    }

    /// Sets the library state to processing. Returns false when the job
    /// must not run ("make the text again" of a meeting that is not ready
    /// or failed, or the live meeting).
    private func beginJob(_ job: Job, store: any MeetingStoring) async throws -> Bool {
        let meeting = job.meeting
        guard !isLiveMeeting(meeting) else { return false }
        guard let summary = try await store.summary(of: meeting) else {
            throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.libraryWrite)
        }
        if job.override != nil {
            switch summary.state {
            case .ready, .failed: break
            case .recording, .paused, .processing: return false
            }
        }
        guard summary.state != .processing else { return true }
        try await withFreshVersion(meeting, in: store) { version in
            try await store.setState(.processing, of: meeting, expectedVersion: version)
        }
        session.noteLibraryChanged()
        return true
    }

    private func makePlan(override: MeetingTextEngineID?, feature: MeetingsFeature) async
        -> MeetingProcessingPlan
    {
        var text: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in feature.textEngines { text[id] = await engine.availability() }
        var speakers: [MeetingSpeakerEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in feature.speakerEngines { speakers[id] = await engine.availability() }
        return MeetingProcessingPlan.make(
            preferences: preferences.speechPreferences(), override: override,
            textAvailability: text, speakerAvailability: speakers)
    }

    private struct TrackTexts {
        var me: MeetingTrackTranscript?
        var them: MeetingTrackTranscript?
        var engine: MeetingTextEngineID
    }

    /// The final text of both tracks with the plan's engine; when that
    /// engine throws (not a cancel), both tracks again with Apple speech.
    private func transcribeTracks(
        _ meeting: MeetingID, audio: MeetingPreparedAudio, plan: MeetingProcessingPlan,
        feature: MeetingsFeature
    ) async throws -> TrackTexts {
        do {
            return try await transcribeTracks(
                meeting, audio: audio, engine: plan.textEngine, feature: feature)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            guard let fallback = plan.fallbackTextEngine else {
                throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.textFailed)
            }
            feature.diagnostics.record(
                .userFacingError(
                    place: .helper, domain: MeetingDiagnosticString(plan.textEngine.rawValue),
                    code: (error as NSError).code),
                meeting: meeting)
            do {
                return try await transcribeTracks(
                    meeting, audio: audio, engine: fallback, feature: feature)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.textFailed)
            }
        }
    }

    /// One engine, "Me" then "Them", one call after the other (Apple speech
    /// must never get two calls at the same time).
    private func transcribeTracks(
        _ meeting: MeetingID, audio: MeetingPreparedAudio, engine id: MeetingTextEngineID,
        feature: MeetingsFeature
    ) async throws -> TrackTexts {
        guard let engine = feature.textEngines[id] else {
            throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.textFailed)
        }
        var result = TrackTexts(engine: id)
        for track in MeetingTrack.allCases {
            guard let file = audio.files[track] else { continue }
            try Task.checkCancellation()
            progressPhase = (meeting, track)
            session.processing[meeting] = .text(track: track, fraction: 0)
            defer { progressPhase = nil }
            let transcript = try await engine.transcribe(
                MeetingFinalTextRequest(meeting: meeting, track: track, audioFile: file),
                progress: progressHandler(meeting, track: track))
            switch track {
            case .me: result.me = transcript
            case .them: result.them = transcript
            }
        }
        return result
    }

    private func progressHandler(_ meeting: MeetingID, track: MeetingTrack)
        -> @Sendable (MeetingEngineProgress) -> Void
    {
        let throttle = MeetingProgressThrottle()
        return { [weak self] progress in
            guard throttle.shouldSend() else { return }
            let step: MeetingsProcessingStep =
                switch progress {
                case .preparingModel: .preparingModel
                case .working(let fraction): .text(track: track, fraction: fraction)
                }
            Task { @MainActor [weak self] in
                guard let self, let phase = self.progressPhase, phase.meeting == meeting,
                    phase.track == track
                else { return }
                self.session.processing[meeting] = step
            }
        }
    }

    /// The speaker segments of "Them". A failure gives no segments and
    /// does not fail the job.
    private func findSpeakers(
        _ meeting: MeetingID, audio: MeetingPreparedAudio, engine id: MeetingSpeakerEngineID?,
        feature: MeetingsFeature
    ) async -> (segments: [MeetingSpeakerSegment], engine: MeetingSpeakerEngineID?) {
        guard let id, let engine = feature.speakerEngines[id], let file = audio.files[.them],
            !Task.isCancelled
        else { return ([], nil) }
        session.processing[meeting] = .speakers
        do {
            let segments = try await engine.diarize(
                MeetingSpeakerRequest(meeting: meeting, audioFile: file))
            return (segments, segments.isEmpty ? nil : id)
        } catch {
            if !Task.isCancelled {
                feature.diagnostics.record(
                    .userFacingError(
                        place: .speakers, domain: MeetingDiagnosticString(id.rawValue),
                        code: (error as NSError).code),
                    meeting: meeting)
            }
            return ([], nil)
        }
    }

    // MARK: Library writes

    private func writeResult(
        _ turns: [MeetingTurn], engines: MeetingEngineUse, duration: TimeInterval?,
        of meeting: MeetingID, in store: any MeetingStoring
    ) async throws {
        guard let library = store as? any MeetingLibraryServicing else {
            throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.libraryWrite)
        }
        do {
            try await withFreshVersion(meeting, in: library) { version in
                try await library.replaceTurns(turns, in: meeting, expectedVersion: version)
            }
            try await withFreshVersion(meeting, in: library) { version in
                try await library.setEngines(engines, of: meeting, expectedVersion: version)
            }
            if let duration {
                try await withFreshVersion(meeting, in: library) { version in
                    try await library.setDuration(duration, of: meeting, expectedVersion: version)
                }
            }
            try await withFreshVersion(meeting, in: library) { version in
                try await library.setState(.ready, of: meeting, expectedVersion: version)
            }
        } catch {
            throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.libraryWrite)
        }
    }

    /// Sets `.failed(reasonCode:)` in the library and in the session.
    func markFailed(_ meeting: MeetingID, code: String) async {
        session.processing[meeting] = .failed(reasonCode: code)
        if let store = feature?.store {
            try? await withFreshVersion(meeting, in: store) { version in
                try await store.setState(
                    .failed(reasonCode: code), of: meeting, expectedVersion: version)
            }
        }
        session.noteLibraryChanged()
    }

    /// Reads the summary just before the write; one more try after a
    /// version conflict.
    private func withFreshVersion(
        _ meeting: MeetingID, in store: any MeetingStoring,
        _ write: (Int) async throws -> Void
    ) async throws {
        for attempt in 0..<2 {
            guard let summary = try await store.summary(of: meeting) else {
                throw MeetingProcessingError(reasonCode: MeetingProcessingFailure.libraryWrite)
            }
            do {
                try await write(summary.version)
                return
            } catch let conflict as MeetingVersionConflict {
                if attempt == 1 { throw conflict }
            }
        }
    }

    // MARK: Off the main actor

    /// Writes missing final files from the journal, and reads
    /// `recording.json`.
    @concurrent
    nonisolated static func prepareAudio(
        folder: URL, meeting: MeetingID, diagnostics: any MeetingDiagnosticsRecording
    ) async -> MeetingPreparedAudio {
        let fileManager = FileManager.default
        let finals = Dictionary(
            uniqueKeysWithValues: MeetingTrack.allCases.map {
                ($0, MeetingJournalLayout.finalAudioFile($0, in: folder))
            })
        var report: MeetingJournalRecoveryReport?
        if MeetingAudioJournalRecovery.hasJournal(in: folder),
            finals.values.contains(where: { !fileManager.fileExists(atPath: $0.path) })
        {
            report = try? MeetingAudioJournalRecovery.recover(
                audioFolder: folder, diagnostics: diagnostics, meeting: meeting)
        }
        var files: [MeetingTrack: URL] = [:]
        var hasAnyFile = false
        for (track, url) in finals {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                continue
            }
            hasAnyFile = true
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > MeetingCAFFileWriter.headerSize { files[track] = url }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let facts = (try? Data(contentsOf: folder.appending(path: MeetingRecordingFacts.fileName)))
            .flatMap { try? decoder.decode(MeetingRecordingFacts.self, from: $0) }
        var duration: TimeInterval?
        if let facts, facts.endTime != nil {
            duration = facts.recordedSeconds
        } else if let report, report.recoveredSeconds > 0 {
            duration = report.recoveredSeconds
        }
        return MeetingPreparedAudio(
            files: files, hasAnyFile: hasAnyFile,
            outputWasSpeakers: facts?.outputWasSpeakers ?? false, duration: duration)
    }
}
