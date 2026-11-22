import Foundation
import RafuCore
import Synchronization

@testable import RafuApp

/// Settings that the test sets.
struct SessionTestPreferences: MeetingPreferencesReading {
    var textEngine: MeetingTextEngineID = .nemotronEnglish
    var speakerEngine: MeetingSpeakerEngineID = .nemotron3

    func speechPreferences() -> MeetingSpeechPreferences {
        MeetingSpeechPreferences(textEngine: textEngine, speakerEngine: speakerEngine)
    }
    func microphoneChoice() -> MeetingMicrophoneChoice { .automatic }
    func audioRetention() -> MeetingAudioRetention { .untilDeleted }
    func agentAccess() -> MeetingAgentAccess { .off }
}

/// A recorder that the test drives. It writes real meetings into the store
/// and real final files at Stop. It opens no device.
final class SessionFakeRecorder: MeetingRecorderControlling, MeetingsRecorderFeeds {
    private struct State {
        var meeting: MeetingID?
        var startError: MeetingRecorderError?
        var peaks: [MeetingTrack: Double] = [.me: -160, .them: -160]
        var facts: MeetingRecorderStartFacts?
        var recoverCalls: [MeetingID] = []
        var outputWasSpeakers = false
        var startCount = 0
    }

    let store: MeetingStore
    private let state = Mutex(State())
    private let stateBroadcast = MeetingRecorderBroadcast<MeetingRecorderState>(
        initial: .idle, replaysLatest: true)
    private let eventBroadcast = MeetingRecorderBroadcast<MeetingRecorderEvent>(
        replaysLatest: false)
    private let liveBroadcast = MeetingRecorderBroadcast<MeetingAudioChunk>(
        replaysLatest: false, bufferingPolicy: .bufferingNewest(256))

    init(store: MeetingStore) {
        self.store = store
    }

    var states: AsyncStream<MeetingRecorderState> { stateBroadcast.subscribe() }
    var events: AsyncStream<MeetingRecorderEvent> { eventBroadcast.subscribe() }
    func liveAudio() -> AsyncStream<MeetingAudioChunk> { liveBroadcast.subscribe() }
    func peakDBFS(_ track: MeetingTrack) -> Double { state.withLock { $0.peaks[track] ?? -160 } }
    func readStartFacts() async -> MeetingRecorderStartFacts? { state.withLock { $0.facts } }
    func dismissProblem() async { stateBroadcast.send(.idle) }

    func recoverAbandoned(_ meeting: MeetingID) async throws -> MeetingJournalRecoveryReport {
        state.withLock { $0.recoverCalls.append(meeting) }
        throw CocoaError(.fileNoSuchFile)
    }

    // Test controls.
    var meeting: MeetingID? { state.withLock { $0.meeting } }
    var startCount: Int { state.withLock { $0.startCount } }
    var recoverCalls: [MeetingID] { state.withLock { $0.recoverCalls } }
    func failNextStart(_ error: MeetingRecorderError) { state.withLock { $0.startError = error } }
    func setPeak(_ track: MeetingTrack, _ dbfs: Double) {
        state.withLock { $0.peaks[track] = dbfs }
    }
    func setOutputWasSpeakers(_ value: Bool) { state.withLock { $0.outputWasSpeakers = value } }
    func send(_ event: MeetingRecorderEvent) { eventBroadcast.send(event) }
    func sendChunk(_ track: MeetingTrack, at start: TimeInterval) {
        liveBroadcast.send(
            MeetingAudioChunk(
                track: track, samples: Data(count: 320), startTime: start, frameCount: 160))
    }

    // MeetingRecorderControlling

    func start(title: String) async throws -> MeetingID {
        let error = state.withLock { state -> MeetingRecorderError? in
            state.startCount += 1
            defer { state.startError = nil }
            return state.startError
        }
        stateBroadcast.send(.starting)
        if let error {
            if case .problem(let problem) = error {
                stateBroadcast.send(.problem(problem))
            } else {
                stateBroadcast.send(.idle)
            }
            throw error
        }
        let record = try await store.create(title: title, startDate: Date())
        state.withLock {
            $0.meeting = record.id
            $0.facts = MeetingRecorderStartFacts(
                meeting: record.id, microphone: nil, microphoneDevice: nil, outputDevice: nil,
                outputWasSpeakers: $0.outputWasSpeakers)
        }
        stateBroadcast.send(.recording(record.id))
        eventBroadcast.send(.started(record.id))
        return record.id
    }

    func pause() async {
        guard let id = meeting else { return }
        stateBroadcast.send(.paused(id))
        eventBroadcast.send(.paused(id))
    }

    func resume() async {
        guard let id = meeting else { return }
        stateBroadcast.send(.recording(id))
        eventBroadcast.send(.resumed(id))
    }

    func stop() async {
        guard let id = meeting else { return }
        stateBroadcast.send(.stopping(id))
        let folder = try? await store.audioFolder(for: id)
        if let folder {
            for track in MeetingTrack.allCases {
                Self.writeFinalFile(MeetingJournalLayout.finalAudioFile(track, in: folder))
            }
            let facts = MeetingRecordingFacts(
                meeting: id, startDate: Date(),
                outputWasSpeakers: state.withLock {
                    $0.outputWasSpeakers
                }, endTime: 42)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(facts).write(
                to: folder.appending(path: MeetingRecordingFacts.fileName))
        }
        if let summary = try? await store.summary(of: id) {
            _ = try? await store.setState(.processing, of: id, expectedVersion: summary.version)
        }
        state.withLock {
            $0.meeting = nil
            $0.facts = nil
        }
        liveBroadcast.finishAll()
        stateBroadcast.send(.idle)
        eventBroadcast.send(.stopped(id))
    }

    /// A final file with one second of silence.
    static func writeFinalFile(_ url: URL) {
        guard let writer = try? MeetingCAFFileWriter(url: url, frameCount: 16_000) else { return }
        try? writer.writeSilence(frames: 16_000)
        try? writer.finish()
    }
}

/// Counts the `transcribe` calls of each engine and checks that no two run
/// at the same time.
final class TranscribeProbe: Sendable {
    private struct State {
        var running = 0
        var overlapped = false
        var calls: [(MeetingTextEngineID, MeetingTrack)] = []
    }

    private let state = Mutex(State())

    func enter(_ engine: MeetingTextEngineID, _ track: MeetingTrack) {
        state.withLock {
            $0.running += 1
            if $0.running > 1 { $0.overlapped = true }
            $0.calls.append((engine, track))
        }
    }

    func leave() { state.withLock { $0.running -= 1 } }

    var overlapped: Bool { state.withLock { $0.overlapped } }
    var callCount: Int { state.withLock { $0.calls.count } }
    func calls(of engine: MeetingTextEngineID) -> [MeetingTrack] {
        state.withLock { $0.calls.filter { $0.0 == engine }.map(\.1) }
    }
}

/// A live session whose events the test sends.
final class SessionFakeLiveSession: MeetingLiveTextSession {
    let events: AsyncStream<MeetingLiveTextEvent>
    let input: AsyncStream<MeetingLiveTextEvent>.Continuation
    private let appended = Mutex(0)
    private let finished = Mutex(false)

    init() {
        (events, input) = AsyncStream.makeStream(of: MeetingLiveTextEvent.self)
    }

    var appendCount: Int { appended.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }

    func append(_ chunk: MeetingAudioChunk) async { appended.withLock { $0 += 1 } }
    func finish() async {
        finished.withLock { $0 = true }
        input.finish()
    }
}

/// A text engine with scripted live sessions and transcripts.
final class SessionFakeTextEngine: MeetingTextEngine {
    private struct State {
        var liveFails = false
        var transcribeFails = false
        var blocksTranscribe = false
        var sessions: [MeetingTrack: [SessionFakeLiveSession]] = [:]
    }

    let id: MeetingTextEngineID
    let supportsLiveText: Bool
    private let probe: TranscribeProbe
    private let state = Mutex(State())
    private let gate: AsyncStream<Void>
    private let gateInput: AsyncStream<Void>.Continuation

    init(_ id: MeetingTextEngineID, probe: TranscribeProbe, supportsLiveText: Bool = true) {
        self.id = id
        self.probe = probe
        self.supportsLiveText = supportsLiveText
        (gate, gateInput) = AsyncStream.makeStream(of: Void.self)
    }

    func setLiveFails(_ value: Bool) { state.withLock { $0.liveFails = value } }
    func setTranscribeFails(_ value: Bool) { state.withLock { $0.transcribeFails = value } }
    /// `transcribe` waits until the task is cancelled.
    func setBlocksTranscribe(_ value: Bool) { state.withLock { $0.blocksTranscribe = value } }
    /// Lets each waiting and later `transcribe` call go on.
    func openGate() {
        setBlocksTranscribe(false)
        gateInput.finish()
    }
    func liveSession(_ track: MeetingTrack) -> SessionFakeLiveSession? {
        state.withLock { $0.sessions[track]?.last }
    }

    func availability() async -> MeetingEngineAvailability { .ready }

    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        let made = SessionFakeLiveSession()
        let fails = state.withLock { state -> Bool in
            if state.liveFails { return true }
            state.sessions[track, default: []].append(made)
            return false
        }
        if fails { throw CocoaError(.featureUnsupported) }
        return made
    }

    func transcribe(
        _ request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        probe.enter(id, request.track)
        defer { probe.leave() }
        progress(.preparingModel)
        await Task.yield()
        progress(.working(fraction: 0.5))
        let (fails, blocks) = state.withLock { ($0.transcribeFails, $0.blocksTranscribe) }
        if blocks {
            for await _ in gate {}
            try Task.checkCancellation()
        }
        if fails { throw CocoaError(.fileReadCorruptFile) }
        let text = request.track == .me ? "hello from me" : "hello from them"
        let words = text.split(separator: " ").enumerated().map { index, word in
            MeetingWord(
                text: String(word), start: Double(index) * 0.3 + (request.track == .me ? 0 : 5),
                end: Double(index) * 0.3 + 0.25 + (request.track == .me ? 0 : 5))
        }
        return MeetingTrackTranscript(track: request.track, words: words, engine: id)
    }
}

/// A speaker engine that gives one speaker or throws.
final class SessionFakeSpeakerEngine: MeetingSpeakerEngine {
    let id: MeetingSpeakerEngineID
    private let fails: Bool

    init(_ id: MeetingSpeakerEngineID = .nemotron3, fails: Bool = false) {
        self.id = id
        self.fails = fails
    }

    func availability() async -> MeetingEngineAvailability { .ready }

    func diarize(_ request: MeetingSpeakerRequest) async throws -> [MeetingSpeakerSegment] {
        if fails { throw CocoaError(.fileReadUnknown) }
        return [MeetingSpeakerSegment(speaker: 1, start: 0, end: 60)]
    }
}
