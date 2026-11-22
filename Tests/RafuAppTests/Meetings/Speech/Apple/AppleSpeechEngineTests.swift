import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

/// A live analysis that gives scripted results when enough audio has arrived,
/// and the rest on `finish()`.
nonisolated final class ScriptedLiveAnalysis: AppleSpeechLiveAnalysis {
    struct Step: Sendable {
        var afterFrames: Int
        var result: AppleSpeechResult
    }

    private struct State {
        var frames = 0
        var pending: [Step]
        var appends = 0
        var finished = false
        var cancelled = false
        var readerExited = false
    }

    private let state: Mutex<State>
    private let results: AsyncStream<AppleSpeechResult>
    private let continuation: AsyncStream<AppleSpeechResult>.Continuation
    private let failure: (any Error & Sendable)?
    let cancelSignal: AsyncStream<Void>
    private let cancelContinuation: AsyncStream<Void>.Continuation

    init(steps: [Step], failAfterSteps failure: (any Error & Sendable)? = nil) {
        state = Mutex(State(pending: steps))
        (results, continuation) = AsyncStream.makeStream()
        (cancelSignal, cancelContinuation) = AsyncStream.makeStream()
        self.failure = failure
    }

    var appendCount: Int { state.withLock { $0.appends } }
    var wasFinished: Bool { state.withLock { $0.finished } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }
    var readerExited: Bool { state.withLock { $0.readerExited } }

    func append(samples: Data, frameCount: Int) -> Bool {
        let due = state.withLock { state -> [AppleSpeechResult] in
            state.appends += 1
            state.frames += frameCount
            let ready = state.pending.prefix { $0.afterFrames <= state.frames }
            state.pending.removeFirst(ready.count)
            return ready.map(\.result)
        }
        for result in due { continuation.yield(result) }
        if failure != nil, state.withLock({ $0.pending.isEmpty }) { continuation.finish() }
        return true
    }

    func consumeResults(_ handler: @Sendable (AppleSpeechResult) async -> Void) async throws {
        defer { state.withLock { $0.readerExited = true } }
        for await result in results {
            await handler(result)
        }
        if let failure, !state.withLock({ $0.cancelled || $0.finished }) { throw failure }
    }

    func finish() async throws {
        let rest = state.withLock { state -> [AppleSpeechResult] in
            state.finished = true
            defer { state.pending.removeAll() }
            return state.pending.map(\.result)
        }
        for result in rest { continuation.yield(result) }
        continuation.finish()
    }

    func cancel() async {
        state.withLock { $0.cancelled = true }
        continuation.finish()
        cancelContinuation.yield()
    }
}

nonisolated final class ScriptedAppleSpeechAnalyzer: AppleSpeechAnalyzing {
    let status: AppleSpeechAssetStatus
    let live: ScriptedLiveAnalysis?
    let file: AppleSpeechFileAnalysis?
    private let installs = Mutex(0)

    init(
        status: AppleSpeechAssetStatus = .installed, live: ScriptedLiveAnalysis? = nil,
        file: AppleSpeechFileAnalysis? = nil
    ) {
        self.status = status
        self.live = live
        self.file = file
    }

    var installCount: Int { installs.withLock { $0 } }

    func assetStatus() async -> AppleSpeechAssetStatus { status }
    func installSystemAssets() async throws { installs.withLock { $0 += 1 } }

    func startLiveAnalysis() async throws -> any AppleSpeechLiveAnalysis {
        guard let live else { throw AppleSpeechError.assetsNotInstalled }
        return live
    }

    func analyzeFile(
        at url: URL, onProgress: @Sendable (Double) -> Void
    ) async throws -> AppleSpeechFileAnalysis {
        guard let file else { throw AppleSpeechError.unreadableAudio }
        for result in file.results { onProgress(result.range.upperBound / file.audioSeconds) }
        return file
    }
}

/// A clock the test moves by hand.
nonisolated final class ManualClock: Sendable {
    private let value = Mutex<TimeInterval>(100)
    func now() -> TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@Suite("Apple speech engine")
struct AppleSpeechEngineTests {
    /// 0.1 s of audio (1600 frames) starting at `start` on the meeting clock.
    private static func chunk(_ track: MeetingTrack, start: TimeInterval) -> MeetingAudioChunk {
        MeetingAudioChunk(
            track: track, samples: Data(count: 3200), startTime: start, frameCount: 1600)
    }

    private static func run(_ text: String, _ start: Double, _ end: Double) -> AppleSpeechRun {
        AppleSpeechRun(text: text, range: start...end)
    }

    // MARK: Live text

    @Test("Scripted audio in, ordered live events out, on the meeting clock")
    func liveEventsInOrder() async throws {
        guard #available(macOS 26, *) else { return }
        let live = ScriptedLiveAnalysis(steps: [
            .init(
                afterFrames: 1600,
                result: AppleSpeechResult(
                    isFinal: false, range: 0...0.1, runs: [Self.run("Hel", 0, 0.1)])),
            .init(
                afterFrames: 3200,
                result: AppleSpeechResult(
                    isFinal: true, range: 0...0.2,
                    runs: [Self.run("Hello", 0, 0.1), Self.run(" world", 0.1, 0.2)])),
            .init(
                afterFrames: 9_999_999,
                result: AppleSpeechResult(
                    isFinal: true, range: 0.2...0.3, runs: [Self.run(" again.", 0.2, 0.3)])),
        ])
        let diagnostics = RecordingMeetingDiagnostics()
        let clock = ManualClock()
        let engine = AppleSpeechEngine(
            analyzer: ScriptedAppleSpeechAnalyzer(live: live), diagnostics: diagnostics,
            now: { clock.now() })
        let session = try await engine.makeLiveSession(for: .them)

        // The session starts 30 s into the meeting.
        await session.append(Self.chunk(.them, start: 30.0))
        clock.advance(0.1)
        await session.append(Self.chunk(.them, start: 30.1))
        clock.advance(0.1)
        await session.append(Self.chunk(.them, start: 30.2))
        await session.finish()

        var events: [MeetingLiveTextEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.count == 3)
        #expect(events[0] == .volatile(text: "Hel", range: 30.0...30.1))
        guard case .final(let words) = events[1], case .final(let last) = events[2] else {
            Issue.record("expected two final events, got \(events)")
            return
        }
        #expect(words.map(\.text) == ["Hello", "world"])
        #expect(abs(words[0].start - 30.0) < 1e-9)
        #expect(abs(words[1].start - 30.1) < 1e-9 && abs(words[1].end - 30.2) < 1e-9)
        #expect(last.map(\.text) == ["again."])
        #expect(live.wasFinished)
        #expect(live.appendCount == 3)

        let recorded = diagnostics.events
        #expect(
            recorded.contains {
                if case .textEngineLoaded(.appleSpeech, nil, nil, _, true) = $0 {
                    true
                } else {
                    false
                }
            })
        #expect(
            recorded.contains {
                if case .firstLiveText(.appleSpeech, .them, _) = $0 { true } else { false }
            })
        #expect(
            recorded.contains {
                if case .liveTextWindow(.appleSpeech, .them, _, _, 3) = $0 { true } else { false }
            })
    }

    @Test("finish() ends the stream and leaves no task")
    func finishEndsStream() async throws {
        guard #available(macOS 26, *) else { return }
        let live = ScriptedLiveAnalysis(steps: [])
        let engine = AppleSpeechEngine(analyzer: ScriptedAppleSpeechAnalyzer(live: live))
        let session = try #require(
            try await engine.makeLiveSession(for: .me) as? AppleSpeechLiveSession)
        #expect(await session.hasReadingTask)
        await session.append(Self.chunk(.me, start: 0))
        await session.finish()
        var count = 0
        for await _ in session.events { count += 1 }
        #expect(count == 0)
        #expect(await !session.hasReadingTask)
        #expect(live.readerExited)
        // A second finish and later audio do nothing.
        await session.finish()
        await session.append(Self.chunk(.me, start: 0.1))
        #expect(live.appendCount == 1)
    }

    @Test("Audio of the other track or with a wrong byte count is ignored")
    func ignoresWrongChunks() async throws {
        guard #available(macOS 26, *) else { return }
        let live = ScriptedLiveAnalysis(steps: [])
        let engine = AppleSpeechEngine(analyzer: ScriptedAppleSpeechAnalyzer(live: live))
        let session = try await engine.makeLiveSession(for: .me)
        await session.append(Self.chunk(.them, start: 0))
        await session.append(
            MeetingAudioChunk(track: .me, samples: Data(count: 3), startTime: 0, frameCount: 1600))
        #expect(live.appendCount == 0)
        await session.finish()
    }

    @Test("Cancellation (the reader stops) cancels the analysis and leaves no task")
    func cancellationLeavesNoTask() async throws {
        guard #available(macOS 26, *) else { return }
        let live = ScriptedLiveAnalysis(steps: [])
        let engine = AppleSpeechEngine(analyzer: ScriptedAppleSpeechAnalyzer(live: live))
        let session = try #require(
            try await engine.makeLiveSession(for: .them) as? AppleSpeechLiveSession)
        let reader = Task {
            for await _ in session.events {}
        }
        await session.append(Self.chunk(.them, start: 0))
        reader.cancel()
        await reader.value
        for await _ in live.cancelSignal { break }
        #expect(live.wasCancelled)
        // `cancel()` is idempotent and waits for the reading task to end.
        await session.cancel()
        #expect(await !session.hasReadingTask)
        #expect(live.readerExited)
    }

    @Test("An analyzer error gives one unavailable event and ends the stream")
    func analyzerError() async throws {
        guard #available(macOS 26, *) else { return }
        let live = ScriptedLiveAnalysis(
            steps: [
                .init(
                    afterFrames: 1600,
                    result: AppleSpeechResult(
                        isFinal: false, range: 0...0.1, runs: [Self.run("Hi", 0, 0.1)]))
            ],
            failAfterSteps: URLError(.badServerResponse))
        let diagnostics = RecordingMeetingDiagnostics()
        let engine = AppleSpeechEngine(
            analyzer: ScriptedAppleSpeechAnalyzer(live: live), diagnostics: diagnostics)
        let session = try await engine.makeLiveSession(for: .them)
        await session.append(Self.chunk(.them, start: 0))
        var events: [MeetingLiveTextEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.last == .unavailable(reason: AppleSpeechLiveSession.stoppedReason))
        #expect(
            diagnostics.events.contains {
                if case .engineError(.text(.appleSpeech), _, URLError.badServerResponse.rawValue) =
                    $0
                {
                    true
                } else {
                    false
                }
            })
        await session.finish()
    }

    @Test("A failed start records the error domain and code and throws")
    func failedStart() async throws {
        guard #available(macOS 26, *) else { return }
        let diagnostics = RecordingMeetingDiagnostics()
        let engine = AppleSpeechEngine(
            analyzer: ScriptedAppleSpeechAnalyzer(live: nil), diagnostics: diagnostics)
        await #expect(throws: AppleSpeechError.assetsNotInstalled) {
            _ = try await engine.makeLiveSession(for: .me)
        }
        #expect(
            diagnostics.events.contains {
                if case .engineError(.text(.appleSpeech), _, _) = $0 { true } else { false }
            })
    }

    // MARK: Final pass

    @Test("The final pass maps word times to the meeting clock")
    func finalPass() async throws {
        guard #available(macOS 26, *) else { return }
        let file = AppleSpeechFileAnalysis(
            audioSeconds: 10, loadMilliseconds: 80,
            results: [
                AppleSpeechResult(
                    isFinal: true, range: 1.0...2.0,
                    runs: [Self.run("Good", 1.0, 1.4), Self.run(" morning,", 1.4, 2.0)]),
                AppleSpeechResult(
                    isFinal: true, range: 5.0...6.0,
                    runs: [AppleSpeechRun(text: " team", range: nil)]),
            ])
        let diagnostics = RecordingMeetingDiagnostics()
        let engine = AppleSpeechEngine(
            analyzer: ScriptedAppleSpeechAnalyzer(file: file), diagnostics: diagnostics)
        let meeting = MeetingID()
        let progress = Mutex<[MeetingEngineProgress]>([])
        let transcript = try await engine.transcribe(
            MeetingFinalTextRequest(
                meeting: meeting, track: .them, audioFile: URL(fileURLWithPath: "/tmp/them.caf"))
        ) { value in progress.withLock { $0.append(value) } }

        #expect(transcript.track == .them)
        #expect(transcript.engine == .appleSpeech)
        #expect(transcript.model == nil)
        #expect(transcript.words.map(\.text) == ["Good", "morning,", "team"])
        #expect(transcript.words[0].start == 1.0 && transcript.words[0].end == 1.4)
        #expect(transcript.words[1].start == 1.4 && transcript.words[1].end == 2.0)
        #expect(transcript.words[2].start == 5.0 && transcript.words[2].end == 6.0)

        let steps = progress.withLock { $0 }
        #expect(steps.first == .preparingModel)
        #expect(steps.last == .working(fraction: 1))
        #expect(steps.contains(.working(fraction: 0.2)))
        #expect(
            diagnostics.events.contains(
                .textEngineLoaded(
                    engine: .appleSpeech, model: nil, modelRevision: nil, loadMilliseconds: 80,
                    isCold: true)))
        #expect(
            diagnostics.events.contains {
                if case .finalTextDone(.appleSpeech, .them, 10, _) = $0 { true } else { false }
            })
    }

    // MARK: Availability

    @Test("Availability follows the system asset status")
    func availability() async {
        guard #available(macOS 26, *) else { return }
        let ready = AppleSpeechEngine(analyzer: ScriptedAppleSpeechAnalyzer(status: .installed))
        #expect(await ready.availability() == .ready)
        #expect(await ready.availabilityReason() == nil)
        let download = ScriptedAppleSpeechAnalyzer(status: .needsSystemDownload)
        let needs = AppleSpeechEngine(analyzer: download)
        #expect(await needs.availability() == .needsModel([]))
        #expect(await needs.availabilityReason() == AppleSpeechEngine.systemDownloadReason)
        #expect(download.installCount == 0)
        try? await needs.installSystemAssets()
        #expect(download.installCount == 1)
        let none = AppleSpeechEngine(analyzer: ScriptedAppleSpeechAnalyzer(status: .unsupported))
        #expect(
            await none.availability() == .unavailable(reason: AppleSpeechEngine.unsupportedReason))
        #expect(ready.supportsLiveText)
        #expect(ready.id == .appleSpeech)
    }

    @MainActor
    @Test("The engine registers in MeetingsFeature through its registration file")
    func registration() {
        let feature = MeetingsFeature()
        feature.registerAppleSpeechParts()
        if #available(macOS 26, *) {
            let engine = feature.textEngines[.appleSpeech]
            #expect(engine is AppleSpeechEngine)
            #expect(engine?.supportsLiveText == true)
            #expect(feature.registeredKinds.contains(.textEngine))
        } else {
            #expect(feature.textEngines[.appleSpeech] == nil)
        }
    }

    // MARK: Pure mapping

    @Test("The clock map follows chunk times and starts a segment at a jump")
    func clockMap() {
        var map = AppleSpeechClockMap()
        map.append(meetingStart: 12.0, duration: 0.5)
        map.append(meetingStart: 12.5, duration: 0.5)
        #expect(map.segments.count == 1)
        #expect(abs(map.meetingTime(forAnalyzerTime: 0.75) - 12.75) < 1e-9)
        map.append(meetingStart: 40.0, duration: 1.0)
        #expect(map.segments.count == 2)
        #expect(abs(map.meetingTime(forAnalyzerTime: 1.5) - 40.5) < 1e-9)
        #expect(abs(map.meetingTime(forAnalyzerTime: 0.25) - 12.25) < 1e-9)
        #expect(map.meetingRange(0.25...1.5) == 12.25...40.5)
    }

    @Test("Words: shared times, punctuation joins, split runs continue a word")
    func words() {
        let words = AppleSpeechWords.words(
            from: [
                Self.run("It is", 0, 1.0),
                Self.run(" fine", 1.0, 1.5),
                Self.run("ly", 1.5, 1.7),
                Self.run(" .", 1.7, 1.8),
                Self.run("  ", 1.8, 1.9),
            ],
            fallback: 0...2, map: { $0 + 100 })
        #expect(words.map(\.text) == ["It", "is", "finely."])
        #expect(abs(words[0].start - 100) < 1e-9 && abs(words[0].end - 100.5) < 1e-9)
        #expect(abs(words[1].start - 100.5) < 1e-9 && abs(words[1].end - 101.0) < 1e-9)
        #expect(abs(words[2].start - 101.0) < 1e-9 && abs(words[2].end - 101.8) < 1e-9)
    }

    @Test("Live stats: delay median and p95 for each 60 s, and word counts")
    func liveStats() {
        var stats = AppleSpeechLiveStats()
        for index in 0..<10 {
            stats.noteAppend(analyzerEnd: Double(index + 1), wall: Double(index))
        }
        // Results for audio ending at 1...9 s arrive 2 s after that audio.
        for index in 0..<9 {
            #expect(
                stats.noteFinal(
                    analyzerEnd: Double(index + 1), words: 2, wall: Double(index) + 2) == nil)
        }
        let window = stats.noteFinal(analyzerEnd: 10, words: 2, wall: 70)
        #expect(window?.words == 20)
        #expect(window?.delayMedianMilliseconds == 2000)
        #expect(window?.delayP95Milliseconds == 61_000)
        #expect(stats.flush(at: 80) == nil)
        #expect(AppleSpeechLiveStats.percentile([], 0.5) == 0)
        #expect(AppleSpeechLiveStats.percentile([3, 1, 2], 0.5) == 2)
    }

    // MARK: Real system check

    /// Runs the real `SpeechAnalyzer` on a short file, live and final.
    /// Skipped unless `RAFU_MEETINGS_APPLE_SPEECH_FILE` names a 16 kHz mono
    /// Int16 WAV file with English speech, and the assets are installed.
    @Test(
        "Real Apple speech on a file (needs RAFU_MEETINGS_APPLE_SPEECH_FILE)",
        .enabled(
            if: ProcessInfo.processInfo.environment["RAFU_MEETINGS_APPLE_SPEECH_FILE"] != nil))
    func realSystem() async throws {
        guard #available(macOS 26, *) else { return }
        let path = try #require(
            ProcessInfo.processInfo.environment["RAFU_MEETINGS_APPLE_SPEECH_FILE"])
        let engine = AppleSpeechEngine()
        #expect(await engine.availability() == .ready)
        let transcript = try await engine.transcribe(
            MeetingFinalTextRequest(
                meeting: MeetingID(), track: .them, audioFile: URL(fileURLWithPath: path))
        ) { _ in }
        #expect(!transcript.words.isEmpty)
        #expect(transcript.words.allSatisfy { $0.end >= $0.start })

        // Live: feed the same samples as chunks (faster than real time).
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples = RealFileSamples.pcm16(from: data)
        let session = try await engine.makeLiveSession(for: .them)
        let collector = Task {
            var finals = 0
            for await event in session.events {
                if case .final = event { finals += 1 }
            }
            return finals
        }
        let chunkFrames = 1600
        var offset = 0
        while offset < samples.count {
            let count = min(chunkFrames, samples.count - offset)
            let bytes = samples[offset..<(offset + count)].withUnsafeBytes { Data($0) }
            await session.append(
                MeetingAudioChunk(
                    track: .them, samples: bytes, startTime: Double(offset) / 16_000,
                    frameCount: count))
            offset += count
        }
        await session.finish()
        #expect(await collector.value > 0)
    }
}

/// Reads the PCM samples of a WAV file written as 16 kHz mono little-endian
/// Int16 (for the real-system check only; example:
/// `afconvert -f WAVE -d LEI16@16000 -c 1 in.aiff out.wav`).
nonisolated enum RealFileSamples {
    static func pcm16(from data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        let marker: [UInt8] = Array("data".utf8)
        guard bytes.count > 16,
            let index = (12..<(bytes.count - 8)).first(where: {
                Array(bytes[$0..<($0 + 4)]) == marker
            })
        else { return [] }
        var result: [Int16] = []
        var position = index + 8
        while position + 1 < bytes.count {
            result.append(
                Int16(bitPattern: UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8))
            position += 2
        }
        return result
    }
}
