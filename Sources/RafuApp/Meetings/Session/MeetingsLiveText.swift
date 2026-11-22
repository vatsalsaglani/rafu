import Foundation
import RafuCore

/// The live session of one track, shared by the task that appends audio and
/// the task that reads text events. A late session (after `close()`) is
/// refused, and the caller finishes it at once.
actor MeetingsLiveTrackSlot {
    private var session: (any MeetingLiveTextSession)?
    private var isClosed = false
    private var gaveUp = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Returns false when the slot is closed; the caller finishes `new`.
    func install(_ new: any MeetingLiveTextSession) -> Bool {
        guard !isClosed else { return false }
        session = new
        resumeWaiters()
        return true
    }

    /// Takes the current session out (for a restart).
    func take() -> (any MeetingLiveTextSession)? {
        defer { session = nil }
        return session
    }

    /// No session will come for this recording; audio is dropped.
    func giveUp() {
        gaveUp = true
        resumeWaiters()
    }

    /// Closes the slot and gives back the session to finish.
    func close() -> (any MeetingLiveTextSession)? {
        isClosed = true
        resumeWaiters()
        defer { session = nil }
        return session
    }

    var current: (any MeetingLiveTextSession)? { session }

    /// Returns when the first session is in, or when no session will come.
    /// Until then the audio waits in the bounded stream of the track.
    func waitUntilReady() async {
        guard session == nil, !isClosed, !gaveUp else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// The live text of one recording: one audio fan-out, and for each track
/// one task that appends audio and one task that reads text events into
/// one `MeetingLiveTurnAssembler`. The assembler lives on the main actor;
/// events come a few times a second. Audio never touches the main actor.
final class MeetingsLiveText {
    /// The newest chunks of one track that wait for its session.
    static let chunkBuffer = 256
    /// How many times a session that stopped giving text is made again for
    /// each track in one recording.
    static let maximumRestarts = 3
    static let afterStopNote = "Text comes after Stop"

    private enum TrackStatus: Equatable {
        case pending
        case running(MeetingTextEngineID)
        case failed
    }

    private let session: MeetingsSessionModel
    private let diagnostics: any MeetingDiagnosticsRecording
    private let slots: [MeetingTrack: MeetingsLiveTrackSlot] = [
        .me: MeetingsLiveTrackSlot(), .them: MeetingsLiveTrackSlot(),
    ]
    private var assembler = MeetingLiveTurnAssembler()
    private var status: [MeetingTrack: TrackStatus] = [.me: .pending, .them: .pending]
    private var tasks: [Task<Void, Never>] = []
    private var isClosed = false
    /// True when the turns changed since the last `publishTurns()`.
    private(set) var hasNewText = false

    /// Subscribes to `audio` at once (before the recorder starts) and
    /// makes the live sessions in a task; the recording never waits for
    /// them.
    init(
        session: MeetingsSessionModel,
        audio: AsyncStream<MeetingAudioChunk>?,
        engines: [MeetingTextEngineID: any MeetingTextEngine],
        preference: MeetingTextEngineID,
        diagnostics: any MeetingDiagnosticsRecording
    ) {
        self.session = session
        self.diagnostics = diagnostics
        session.liveTextEngine = nil
        session.liveTextNote = nil
        var feeds: [MeetingTrack: AsyncStream<MeetingAudioChunk>] = [:]
        var inputs: [MeetingTrack: AsyncStream<MeetingAudioChunk>.Continuation] = [:]
        for track in MeetingTrack.allCases {
            let (stream, continuation) = AsyncStream.makeStream(
                of: MeetingAudioChunk.self, bufferingPolicy: .bufferingNewest(Self.chunkBuffer))
            feeds[track] = stream
            inputs[track] = continuation
        }
        if let audio, let meInput = inputs[.me], let themInput = inputs[.them] {
            tasks.append(Task { await Self.fanOut(audio, me: meInput, them: themInput) })
        }
        for track in MeetingTrack.allCases {
            guard let slot = slots[track], let feed = feeds[track] else { continue }
            tasks.append(Task { await Self.appendAudio(feed, to: slot) })
        }
        tasks.append(
            Task { [weak self] in
                let engine = await Self.chooseEngine(engines, preference: preference)
                guard let self, !Task.isCancelled else { return }
                self.startTracks(engine: engine, engines: engines)
            })
    }

    /// The turns for the live view, at most `limit`, newest last. Clears
    /// `hasNewText`.
    func publishTurns(limit: Int = 200) -> [MeetingLiveTurn] {
        hasNewText = false
        return Array(assembler.turns().suffix(limit))
    }

    /// Ends each task and finishes each session. A session made later is
    /// finished at once.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for task in tasks { task.cancel() }
        tasks = []
        let slots = Array(slots.values)
        Task {
            for slot in slots {
                if let open = await slot.close() { await open.finish() }
            }
        }
    }

    // MARK: Tracks

    private func startTracks(
        engine: MeetingTextEngineID?, engines: [MeetingTextEngineID: any MeetingTextEngine]
    ) {
        guard !isClosed else { return }
        guard let engine else {
            for track in MeetingTrack.allCases { markFailed(track) }
            return
        }
        for track in MeetingTrack.allCases {
            tasks.append(
                Task { [weak self] in
                    await self?.runTrack(track, engine: engine, engines: engines)
                })
        }
    }

    private func runTrack(
        _ track: MeetingTrack, engine preferred: MeetingTextEngineID,
        engines: [MeetingTextEngineID: any MeetingTextEngine]
    ) async {
        guard let slot = slots[track] else { return }
        var engine = preferred
        var restarts = 0
        while !Task.isCancelled, !isClosed {
            guard let made = await Self.makeSession(track, engine: engine, engines: engines) else {
                markFailed(track)
                await slot.giveUp()
                return
            }
            guard !isClosed, await slot.install(made.session) else {
                await made.session.finish()
                return
            }
            engine = made.engine
            status[track] = .running(made.engine)
            updateStatus()
            for await event in made.session.events {
                assembler.ingest(event, track: track)
                hasNewText = true
                if case .unavailable = event { break }
            }
            guard !Task.isCancelled, !isClosed else { return }
            // The session stopped giving text: make it again.
            if let old = await slot.take() { await old.finish() }
            restarts += 1
            diagnostics.record(
                .liveSessionRestarted(engine: engine, track: track, reason: .engineError),
                meeting: session.liveMeeting)
            guard restarts <= Self.maximumRestarts else {
                markFailed(track)
                await slot.giveUp()
                return
            }
        }
    }

    private func markFailed(_ track: MeetingTrack) {
        status[track] = .failed
        updateStatus()
    }

    private func updateStatus() {
        guard !isClosed else { return }
        var engine: MeetingTextEngineID?
        var failed: [MeetingTrack] = []
        for track in MeetingTrack.allCases {
            switch status[track] {
            case .running(let id): engine = engine ?? id
            case .failed: failed.append(track)
            case .pending, nil: break
            }
        }
        session.liveTextEngine = engine
        switch failed.count {
        case 0: session.liveTextNote = nil
        case 1:
            session.liveTextNote =
                "Text for \(failed[0] == .me ? "Me" : "Them") comes after Stop"
        default: session.liveTextNote = Self.afterStopNote
        }
    }

    // MARK: Off the main actor

    /// The live engine: the preferred one when ready and live, else
    /// Nemotron when ready, else Apple speech. Nil when no engine is
    /// registered.
    @concurrent
    nonisolated private static func chooseEngine(
        _ engines: [MeetingTextEngineID: any MeetingTextEngine], preference: MeetingTextEngineID
    ) async -> MeetingTextEngineID? {
        guard !engines.isEmpty else { return nil }
        var availability: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in engines { availability[id] = await engine.availability() }
        let liveCapable = Set(engines.values.filter(\.supportsLiveText).map(\.id))
        let choice = resolvedLiveTextEngine(
            preference: preference, availability: availability, liveCapable: liveCapable)
        return engines[choice] != nil ? choice : engines.keys.first(where: liveCapable.contains)
    }

    /// Makes a session with `engine`; when that throws, tries Apple speech
    /// one time.
    @concurrent
    nonisolated private static func makeSession(
        _ track: MeetingTrack, engine: MeetingTextEngineID,
        engines: [MeetingTextEngineID: any MeetingTextEngine]
    ) async -> (session: any MeetingLiveTextSession, engine: MeetingTextEngineID)? {
        if let chosen = engines[engine], let made = try? await chosen.makeLiveSession(for: track) {
            return (made, engine)
        }
        guard engine != .appleSpeech, !Task.isCancelled, let apple = engines[.appleSpeech],
            let made = try? await apple.makeLiveSession(for: track)
        else { return nil }
        return (made, .appleSpeech)
    }

    /// Splits the recorder's audio by track. Never blocks: each track
    /// stream keeps the newest chunks.
    @concurrent
    nonisolated private static func fanOut(
        _ audio: AsyncStream<MeetingAudioChunk>,
        me: AsyncStream<MeetingAudioChunk>.Continuation,
        them: AsyncStream<MeetingAudioChunk>.Continuation
    ) async {
        for await chunk in audio {
            switch chunk.track {
            case .me: me.yield(chunk)
            case .them: them.yield(chunk)
            }
        }
        me.finish()
        them.finish()
    }

    /// Appends the audio of one track to its session. A slow "Them"
    /// session never blocks "Me": each track has its own task and stream.
    @concurrent
    nonisolated private static func appendAudio(
        _ feed: AsyncStream<MeetingAudioChunk>, to slot: MeetingsLiveTrackSlot
    ) async {
        await slot.waitUntilReady()
        for await chunk in feed {
            guard let open = await slot.current else { continue }
            await open.append(chunk)
        }
    }
}
