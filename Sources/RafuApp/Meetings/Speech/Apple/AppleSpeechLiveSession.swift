import Foundation
import RafuCore

/// One live Apple speech stream for one track. Audio chunks go in through
/// `append`; volatile and final results come out of `events` as
/// `MeetingLiveTextEvent`s with times on the meeting clock.
///
/// One task reads the analyzer's results. `finish()` ends the input,
/// finalizes, waits for that task and ends `events`. When the reader of
/// `events` stops, the session cancels the analysis. After either path no task
/// of the session is left.
actor AppleSpeechLiveSession: MeetingLiveTextSession {
    nonisolated let events: AsyncStream<MeetingLiveTextEvent>
    private let continuation: AsyncStream<MeetingLiveTextEvent>.Continuation
    private let analysis: any AppleSpeechLiveAnalysis
    private let track: MeetingTrack
    private let diagnostics: any MeetingDiagnosticsRecording
    private let now: @Sendable () -> TimeInterval

    private enum Phase { case running, finishing, finished }
    private var phase = Phase.running
    private var consumer: Task<Void, Never>?
    private var clock = AppleSpeechClockMap()
    private var stats = AppleSpeechLiveStats()
    private var firstAppendAt: TimeInterval?
    private var hasReportedFirstText = false
    private(set) var droppedChunks = 0

    /// The user-facing reason when Apple speech stops giving live text.
    static let stoppedReason = "Live text stopped. The recording goes on."

    /// Makes the session and starts the task that reads results.
    static func start(
        track: MeetingTrack, analysis: any AppleSpeechLiveAnalysis,
        diagnostics: any MeetingDiagnosticsRecording,
        now: @escaping @Sendable () -> TimeInterval
    ) async -> AppleSpeechLiveSession {
        let session = AppleSpeechLiveSession(
            track: track, analysis: analysis, diagnostics: diagnostics, now: now)
        await session.startReading()
        return session
    }

    private init(
        track: MeetingTrack, analysis: any AppleSpeechLiveAnalysis,
        diagnostics: any MeetingDiagnosticsRecording,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        // Volatile results arrive about ten times a second; a slow reader
        // loses old previews, never the order.
        let (stream, continuation) = AsyncStream<MeetingLiveTextEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(512))
        self.events = stream
        self.continuation = continuation
        self.analysis = analysis
        self.track = track
        self.diagnostics = diagnostics
        self.now = now
    }

    private func startReading() {
        let analysis = analysis
        consumer = Task {
            do {
                try await analysis.consumeResults { result in
                    await self.handle(result)
                }
                self.resultsEnded(error: nil)
            } catch {
                self.resultsEnded(error: error)
            }
        }
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.cancel() }
        }
    }

    // MARK: MeetingLiveTextSession

    func append(_ chunk: MeetingAudioChunk) async {
        guard phase == .running, chunk.track == track, chunk.isWellFormed, chunk.frameCount > 0
        else { return }
        let wall = now()
        if firstAppendAt == nil { firstAppendAt = wall }
        clock.append(meetingStart: chunk.startTime, duration: chunk.duration)
        stats.noteAppend(analyzerEnd: clock.analyzerEnd, wall: wall)
        if !analysis.append(samples: chunk.samples, frameCount: chunk.frameCount) {
            droppedChunks += 1
        }
    }

    func finish() async {
        guard phase == .running else {
            await consumer?.value
            return
        }
        phase = .finishing
        do {
            try await analysis.finish()
        } catch {
            diagnostics.record(AppleSpeechErrorFacts.event(for: error), meeting: nil)
        }
        await consumer?.value
        close()
    }

    /// Stops at once: cancels the analysis and the reading task, and ends
    /// `events` without the remaining results.
    func cancel() async {
        guard phase != .finished else { return }
        phase = .finishing
        await analysis.cancel()
        consumer?.cancel()
        await consumer?.value
        close()
    }

    /// True while the task that reads results exists (for tests).
    var hasReadingTask: Bool { consumer != nil }

    // MARK: Results

    private func handle(_ result: AppleSpeechResult) {
        guard phase != .finished else { return }
        let wall = now()
        if !hasReportedFirstText, !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
            hasReportedFirstText = true
            let start = firstAppendAt ?? wall
            diagnostics.record(
                .firstLiveText(
                    engine: .appleSpeech, track: track,
                    milliseconds: AppleSpeechLiveStats.milliseconds(wall - start)),
                meeting: nil)
        }
        if result.isFinal {
            let words = AppleSpeechWords.words(
                from: result.runs, fallback: result.range,
                map: clock.meetingTime(forAnalyzerTime:))
            if let window = stats.noteFinal(
                analyzerEnd: result.range.upperBound, words: words.count, wall: wall)
            {
                record(window)
            }
            if !words.isEmpty { continuation.yield(.final(words: words)) }
        } else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            continuation.yield(.volatile(text: text, range: clock.meetingRange(result.range)))
        }
    }

    private func resultsEnded(error: (any Error)?) {
        guard phase != .finished else { return }
        if let error, !(error is CancellationError) {
            diagnostics.record(AppleSpeechErrorFacts.event(for: error), meeting: nil)
            if phase == .running {
                let facts = error as NSError
                diagnostics.record(
                    .userFacingError(
                        place: .appleSpeech, domain: MeetingDiagnosticString(facts.domain),
                        code: facts.code),
                    meeting: nil)
                continuation.yield(.unavailable(reason: Self.stoppedReason))
            }
        }
        // The results ended by themselves (not from finish or cancel): the
        // session can give no more text.
        if phase == .running { close() }
    }

    private func close() {
        guard phase != .finished else { return }
        phase = .finished
        if let window = stats.flush(at: now()) { record(window) }
        consumer = nil
        continuation.finish()
    }

    private func record(_ window: AppleSpeechLiveStats.Window) {
        diagnostics.record(
            .liveTextWindow(
                engine: .appleSpeech, track: track,
                delayMedianMilliseconds: window.delayMedianMilliseconds,
                delayP95Milliseconds: window.delayP95Milliseconds, words: window.words),
            meeting: nil)
    }
}
