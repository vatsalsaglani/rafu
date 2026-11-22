import Foundation
import RafuCore
import Synchronization

/// Live Nemotron text for both tracks through one helper process, with the
/// footprint guard: when a `stats` line shows the limit (1.0 GB), the hub
/// starts a new helper, keeps sending audio to the old one until the new
/// one is ready, then sends the next frame to the new one and closes the
/// old one's input, so the old one gives its last `final` lines and ends.
/// Each frame goes to exactly one helper: no chunk is lost at a restart.
/// When a restart fails two times, each session gets `.unavailable` and
/// the recording continues (live text is a preview only).
actor MeetingWorkerLiveHub {
    static let defaultFootprintLimitBytes: Int64 = 1_000_000_000
    static let maximumRestartFailures = 2
    static let unavailableReason = "Live text stopped. The text comes after Stop."

    private struct Helper {
        let id: Int
        let connection: any MeetingWorkerConnection
        var ready = false
        var inputClosed = false
        var peakFootprintBytes: Int64?
        let started: ContinuousClock.Instant
    }

    private let process: MeetingWorkerProcess
    private let makeRequest: @Sendable () async throws(MeetingWorkerError) -> MeetingWorkerRequest
    private let footprintLimitBytes: Int64
    private let diagnostics: any MeetingDiagnosticsRecording
    private let meeting: MeetingID?

    private var continuations: [MeetingTrack: AsyncStream<MeetingLiveTextEvent>.Continuation] = [:]
    private var finishedTracks: Set<MeetingTrack> = []
    private var helpers: [Int: Helper] = [:]
    private var activeID: Int?
    private var standbyID: Int?
    private var standbyStarting = false
    private var nextID = 0
    private var restartFailures = 0
    private var isUnavailable = false
    private var isEnded = false
    private var startTask: Task<Void, Never>?
    private var wordsSinceStats: [MeetingTrack: Int] = [:]
    /// Frames that wait for the active helper's `ready` line (its model
    /// loads, 0.1 s warm, about 7 s cold), so the pipe does not fill and
    /// drop the first seconds. At most `maximumWaitingBytes`.
    private var waitingFrames: [Data] = []
    private var closeActiveWhenReady = false
    private var waitingBytes = 0
    static let maximumWaitingBytes = 2 * 1_024 * 1_024
    /// Frames dropped while waiting (the oldest first).
    private(set) var droppedWaitingFrames = 0
    /// Frames written to each helper (for tests and diagnostics).
    private(set) var framesSent: [Int: Int] = [:]
    /// The number of footprint restarts that switched helpers.
    private(set) var restartCount = 0

    init(
        process: MeetingWorkerProcess,
        footprintLimitBytes: Int64 = MeetingWorkerLiveHub.defaultFootprintLimitBytes,
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        meeting: MeetingID? = nil,
        makeRequest: @escaping @Sendable () async throws(MeetingWorkerError) -> MeetingWorkerRequest
    ) {
        self.process = process
        self.footprintLimitBytes = footprintLimitBytes
        self.diagnostics = diagnostics
        self.meeting = meeting
        self.makeRequest = makeRequest
    }

    /// True when the hub has ended (both tracks finished, or unavailable).
    var hasEnded: Bool { isEnded }

    private nonisolated let endedFlag = Atomic<Bool>(false)

    /// `hasEnded`, readable with no await (the engine picks a hub under a
    /// lock).
    nonisolated var isEndedFlag: Bool { endedFlag.load(ordering: .acquiring) }

    /// Adds a session for `track` and starts the helper on the first one.
    func openSession(for track: MeetingTrack) -> AsyncStream<MeetingLiveTextEvent> {
        let (stream, continuation) = AsyncStream<MeetingLiveTextEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        continuations[track]?.finish()
        continuations[track] = continuation
        finishedTracks.remove(track)
        if isUnavailable {
            continuation.yield(.unavailable(reason: Self.unavailableReason))
            continuation.finish()
        } else if activeID == nil, startTask == nil {
            startTask = Task { await self.startHelper(asStandby: false) }
        }
        return stream
    }

    /// Waits until the first helper has started (or failed to start).
    func waitUntilStarted() async {
        await startTask?.value
    }

    /// Sends one chunk of `track` to the active helper, in frames of at
    /// most 1 s.
    func append(_ chunk: MeetingAudioChunk, track: MeetingTrack) async {
        await startTask?.value
        guard !isUnavailable, !isEnded, !finishedTracks.contains(track), let activeID,
            let helper = helpers[activeID]
        else { return }
        var adjusted = chunk
        adjusted.track = track
        for frame in MeetingWorkerFrame.split(adjusted) {
            let bytes = frame.encoded()
            if helper.ready {
                helper.connection.send(bytes, droppable: true)
                framesSent[activeID, default: 0] += 1
            } else {
                waitingFrames.append(bytes)
                waitingBytes += bytes.count
                while waitingBytes > Self.maximumWaitingBytes, !waitingFrames.isEmpty {
                    waitingBytes -= waitingFrames.removeFirst().count
                    droppedWaitingFrames += 1
                }
            }
        }
    }

    /// Sends the frames that waited for the active helper's model load.
    /// They are already bounded (2 MB), so the pipe queue must not drop them.
    private func flushWaitingFrames() {
        guard let activeID, let helper = helpers[activeID], helper.ready else { return }
        for bytes in waitingFrames {
            helper.connection.send(bytes, droppable: false)
            framesSent[activeID, default: 0] += 1
        }
        waitingFrames = []
        waitingBytes = 0
    }

    /// No more audio for `track`. When each open track has finished, the
    /// helper gets the end of input, gives its last words and exits.
    func finish(track: MeetingTrack) async {
        await startTask?.value
        finishedTracks.insert(track)
        guard Set(continuations.keys).isSubset(of: finishedTracks) else { return }
        if let standbyID, let standby = helpers[standbyID] {
            standby.connection.terminate()
        }
        if let activeID {
            if helpers[activeID]?.ready == true {
                closeInput(of: activeID)
            } else {
                // Its model still loads: close after the waiting frames.
                closeActiveWhenReady = true
            }
        }
        endIfIdle()
    }

    // MARK: - Helpers

    private func startHelper(asStandby: Bool) async {
        defer { if asStandby { standbyStarting = false } }
        let connection: any MeetingWorkerConnection
        do {
            let request = try await makeRequest()
            connection = try await process.launch(mode: .liveText, request: request)
        } catch {
            if case .modelMissing = error {
                restartFailures = Self.maximumRestartFailures
            } else {
                restartFailures += 1
            }
            if !asStandby || restartFailures >= Self.maximumRestartFailures { becomeUnavailable() }
            return
        }
        let id = nextID
        nextID += 1
        helpers[id] = Helper(id: id, connection: connection, started: .now)
        if asStandby {
            standbyID = id
        } else {
            activeID = id
        }
        Task { await self.read(helperID: id, connection: connection) }
    }

    private func read(helperID: Int, connection: any MeetingWorkerConnection) async {
        var splitter = MeetingWorkerLineSplitter()
        var violation = false
        reading: for await bytes in connection.output {
            let lines: [Data]
            do {
                lines = try splitter.append(bytes)
            } catch {
                violation = true
                break reading
            }
            for line in lines {
                let event: MeetingWorkerEvent
                do {
                    event = try MeetingWorkerEvent.decode(line: line)
                } catch {
                    violation = true
                    break reading
                }
                await handle(event, from: helperID)
            }
        }
        if violation { connection.terminate() }
        let termination = await connection.termination()
        helperEnded(helperID, termination: termination, violation: violation)
    }

    /// Handles one line. A footprint restart is awaited here, so the lines
    /// of one helper are handled in order with the restart between them.
    private func handle(_ event: MeetingWorkerEvent, from helperID: Int) async {
        guard var helper = helpers[helperID] else { return }
        switch event {
        case .ready(let loadMs, let cold):
            helper.ready = true
            helpers[helperID] = helper
            diagnostics.record(
                .textEngineLoaded(
                    engine: .nemotronEnglish, model: .nemotronEnglish1120, modelRevision: nil,
                    loadMilliseconds: loadMs, isCold: cold),
                meeting: meeting)
            if helperID == standbyID {
                switchToStandby()
            } else if helperID == activeID {
                flushWaitingFrames()
                if closeActiveWhenReady {
                    closeActiveWhenReady = false
                    closeInput(of: helperID)
                }
            }
        case .volatile(let track, let text, let start, let end):
            continuations[track]?.yield(
                .volatile(text: text, range: min(start, end)...max(start, end)))
        case .final(let track, let words):
            wordsSinceStats[track, default: 0] += words.count
            continuations[track]?.yield(.final(words: words))
        case .stats(let peak, let p50, let p95):
            helper.peakFootprintBytes = peak
            helpers[helperID] = helper
            if let p50, let p95 {
                for track in continuations.keys {
                    diagnostics.record(
                        .liveTextWindow(
                            engine: .nemotronEnglish, track: track, delayMedianMilliseconds: p50,
                            delayP95Milliseconds: p95, words: wordsSinceStats[track] ?? 0),
                        meeting: meeting)
                }
                wordsSinceStats = [:]
            }
            if helperID == activeID, peak >= footprintLimitBytes, standbyID == nil,
                !standbyStarting, !helper.inputClosed
            {
                standbyStarting = true
                diagnostics.record(
                    .helperRestarted(mode: .liveText, reason: .memoryPressure), meeting: meeting)
                await startHelper(asStandby: true)
            }
        case .error(let domain, let code):
            diagnostics.record(
                .engineError(
                    engine: .text(.nemotronEnglish),
                    domain: MeetingDiagnosticString("worker.\(domain.rawValue)"), code: code),
                meeting: meeting)
        case .preparing, .progress, .segments, .done:
            break
        }
    }

    /// The standby helper is ready: the next frame goes to it, and the old
    /// helper gets the end of input.
    private func switchToStandby() {
        guard let standbyID else { return }
        let oldID = activeID
        activeID = standbyID
        self.standbyID = nil
        restartCount += 1
        if let oldID { closeInput(of: oldID) }
    }

    private func closeInput(of id: Int) {
        guard var helper = helpers[id], !helper.inputClosed else { return }
        helper.inputClosed = true
        helpers[id] = helper
        helper.connection.closeInput()
    }

    private func helperEnded(_ id: Int, termination: MeetingWorkerTermination, violation: Bool) {
        guard let helper = helpers.removeValue(forKey: id) else { return }
        process.registry.remove(helper.connection)
        MeetingWorkerProcess.recordExit(
            diagnostics: diagnostics, mode: .liveText, termination: termination,
            wallSeconds: MeetingWorkerProcess.seconds(ContinuousClock.now - helper.started),
            peak: helper.peakFootprintBytes, meeting: meeting)
        let endedWell = !violation && termination == .exited(0) && helper.inputClosed
        if id == standbyID {
            // The new helper failed before it was ready; the old one goes on.
            standbyID = nil
            restartFailures += 1
            if restartFailures >= Self.maximumRestartFailures { becomeUnavailable() }
        } else if id == activeID {
            activeID = nil
            if !endedWell, !isEnded, !isUnavailable {
                // The active helper crashed: start a new one.
                diagnostics.record(
                    .helperRestarted(
                        mode: .liveText, reason: violation ? .protocolError : .crashed),
                    meeting: meeting)
                restartFailures += 1
                if restartFailures >= Self.maximumRestartFailures {
                    becomeUnavailable()
                } else if !Set(continuations.keys).isSubset(of: finishedTracks) {
                    startTask = Task { await self.startHelper(asStandby: false) }
                }
            }
        }
        endIfIdle()
    }

    private func endIfIdle() {
        guard !isEnded, helpers.isEmpty, Set(continuations.keys).isSubset(of: finishedTracks)
        else { return }
        isEnded = true
        endedFlag.store(true, ordering: .releasing)
        for continuation in continuations.values { continuation.finish() }
    }

    private func becomeUnavailable() {
        guard !isUnavailable else { return }
        isUnavailable = true
        for continuation in continuations.values {
            continuation.yield(.unavailable(reason: Self.unavailableReason))
            continuation.finish()
        }
        for helper in helpers.values { helper.connection.terminate() }
        isEnded = true
        endedFlag.store(true, ordering: .releasing)
    }
}

/// One track's live text session on a `MeetingWorkerLiveHub`.
nonisolated final class MeetingWorkerLiveTextSession: MeetingLiveTextSession {
    let events: AsyncStream<MeetingLiveTextEvent>
    let track: MeetingTrack
    private let hub: MeetingWorkerLiveHub

    init(hub: MeetingWorkerLiveHub, track: MeetingTrack, events: AsyncStream<MeetingLiveTextEvent>)
    {
        self.hub = hub
        self.track = track
        self.events = events
    }

    func append(_ chunk: MeetingAudioChunk) async {
        await hub.append(chunk, track: track)
    }

    func finish() async {
        await hub.finish(track: track)
    }
}
