import Foundation
import RafuCore
import Synchronization

@testable import RafuApp

/// Keeps every diagnostic event.
final class RecorderTestDiagnostics: MeetingDiagnosticsRecording {
    private let events = Mutex<[MeetingDiagnosticEvent]>([])

    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        events.withLock { $0.append(event) }
    }

    var recorded: [MeetingDiagnosticEvent] { events.withLock { $0 } }
}

/// A host clock that the test sets (nanosecond ticks).
final class FakeHostClock: MeetingHostClock {
    private let value: Mutex<UInt64>

    init(_ start: UInt64) { value = Mutex(start) }

    var timebase: MeetingHostTimebase { .nanoseconds }
    func now() -> UInt64 { value.withLock { $0 } }
    func set(_ ticks: UInt64) { value.withLock { $0 = ticks } }
}

/// A monotonic clock that the test sets.
final class FakeMonotonicClock: Sendable {
    private let value = Mutex<TimeInterval>(0)

    var now: TimeInterval { value.withLock { $0 } }
    func set(_ seconds: TimeInterval) { value.withLock { $0 = seconds } }
}

/// A source that the test drives: it yields the blocks the test sends.
actor FakeAudioSource: MeetingAudioSource {
    nonisolated let track: MeetingTrack
    private var blocks: AsyncStream<MeetingCapturedBlock>.Continuation?
    private var events: AsyncStream<MeetingAudioSourceEvent>.Continuation?
    private var failures: [MeetingAudioSourceError] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let facts: MeetingAudioSourceFacts
    private let startSignal: AsyncStream<Int>.Continuation
    /// Yields the start count after each successful start.
    nonisolated let starts: AsyncStream<Int>

    init(track: MeetingTrack, facts: MeetingAudioSourceFacts? = nil) {
        self.track = track
        self.facts =
            facts
            ?? MeetingAudioSourceFacts(
                device: MeetingAudioDeviceFacts(
                    name: track == .me ? "Test Microphone" : "Test Speakers",
                    uid: track == .me ? "test-mic" : "test-out",
                    transportType: MeetingTransportType.builtIn, nominalSampleRate: 48_000,
                    channelCount: track == .me ? 1 : 2),
                captureSampleRate: 48_000,
                microphone: track == .me
                    ? MeetingMicrophoneResolution(
                        device: nil, kind: .automatic, reason: .systemDefault) : nil,
                outputIsBuiltInSpeakers: track == .them)
        (starts, startSignal) = AsyncStream.makeStream(of: Int.self)
    }

    func failNextStarts(_ errors: [MeetingAudioSourceError]) { failures = errors }

    func start(meeting: MeetingID?, diagnostics: any MeetingDiagnosticsRecording) async throws
        -> MeetingAudioSourceRun
    {
        if !failures.isEmpty { throw failures.removeFirst() }
        startCount += 1
        let (blockStream, blockContinuation) = AsyncStream.makeStream(
            of: MeetingCapturedBlock.self)
        let (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: MeetingAudioSourceEvent.self)
        blocks = blockContinuation
        events = eventContinuation
        startSignal.yield(startCount)
        return MeetingAudioSourceRun(facts: facts, blocks: blockStream, events: eventStream)
    }

    func stop() async {
        stopCount += 1
        blocks?.finish()
        events?.finish()
        blocks = nil
        events = nil
    }

    func takeCallbackCounters() async -> MeetingCallbackCounters { MeetingCallbackCounters() }

    /// Sends `count` samples of `value` whose first sample is at `hostTime`.
    func send(hostTime: UInt64, count: Int = 1_600, value: Int16 = 1_000) {
        blocks?.yield(
            MeetingCapturedBlock(
                hostTime: hostTime, samples: [Int16](repeating: value, count: count),
                sourceSampleRate: 48_000))
    }

    /// The device went away: report it and end the run.
    func interrupt() {
        events?.yield(.interrupted(old: facts.device))
        blocks?.finish()
        events?.finish()
        blocks = nil
        events = nil
    }
}

/// Permissions that the test sets; the microphone check can wait on a gate.
actor FakePermissions: MeetingPermissionChecking {
    var microphone: MeetingPermissionState
    var systemAudio: MeetingPermissionState
    var allowOnRequest: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    init(
        microphone: MeetingPermissionState = .granted,
        systemAudio: MeetingPermissionState = .unknown, allowOnRequest: Bool = true
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.allowOnRequest = allowOnRequest
    }

    /// The next microphone check waits until `openGate()`.
    func closeGate() { gated = true }

    func openGate() {
        gated = false
        gate?.resume()
        gate = nil
    }

    /// Returns when a microphone check has started.
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func microphoneState() async -> MeetingPermissionState {
        hasEntered = true
        entered?.resume()
        entered = nil
        if gated { await withCheckedContinuation { gate = $0 } }
        return microphone
    }

    func requestMicrophone() async -> Bool { allowOnRequest }
    func systemAudioState() async -> MeetingPermissionState { systemAudio }
}

/// The apps that play sound, set by the test.
final class FakePlayingProcesses: MeetingPlayingProcessListing {
    private let ids = Mutex<[String]>([])

    func set(_ value: [String]) { ids.withLock { $0 = value } }
    func playingBundleIDs() async -> [String] { ids.withLock { $0 } }
}

/// A small in-memory library with real audio folders in a temp folder.
actor FakeMeetingStore: MeetingStoring {
    struct NotFound: Error {}

    let root: URL
    private(set) var meetings: [MeetingID: MeetingSummaryRecord] = [:]
    private(set) var deleted: [MeetingID] = []

    init() {
        root = FileManager.default.temporaryDirectory.appending(
            path: "rafu-recorder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func create(title: String, startDate: Date) async throws -> MeetingSummaryRecord {
        let record = MeetingSummaryRecord(
            id: MeetingID(), title: title, startDate: startDate, duration: 0, state: .recording)
        meetings[record.id] = record
        return record
    }

    func list() async throws -> [MeetingSummaryRecord] { Array(meetings.values) }
    func summary(of meeting: MeetingID) async throws -> MeetingSummaryRecord? { meetings[meeting] }

    func appendTurns(_ turns: [MeetingTurn], to meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { expectedVersion }

    func turns(of meeting: MeetingID, after: MeetingTurnID?, limit: Int) async throws
        -> MeetingTurnPage
    { MeetingTurnPage(turns: [], nextAfter: nil, version: 0) }

    func setState(_ state: MeetingState, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    {
        guard var record = meetings[meeting] else { throw NotFound() }
        guard record.version == expectedVersion else {
            throw MeetingVersionConflict(
                meeting: meeting, expected: expectedVersion, found: record.version)
        }
        record.state = state
        record.version += 1
        meetings[meeting] = record
        return record.version
    }

    func rename(_ meeting: MeetingID, title: String, expectedVersion: Int) async throws -> Int {
        expectedVersion
    }

    func renameSpeaker(
        _ label: MeetingSpeakerLabel, to name: String, in meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int { expectedVersion }

    func delete(_ meeting: MeetingID) async throws {
        meetings[meeting] = nil
        deleted.append(meeting)
    }

    func search(_ query: String, limit: Int) async throws -> [MeetingSearchHit] { [] }
    func agentPacketText(of meeting: MeetingID) async throws -> String { "" }
    func exportMarkdown(of meeting: MeetingID) async throws -> String { "" }
    func sizeOnDisk(of meeting: MeetingID) async throws -> MeetingSizes { MeetingSizes() }
    func applyAudioRetention(_ retention: MeetingAudioRetention, now: Date) async throws {}

    func audioFolder(for meeting: MeetingID) async throws -> URL {
        let folder = root.appending(path: meeting.uuidString, directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// One recorder with fakes, and the fakes.
@available(macOS 26, *)
struct RecorderHarness {
    static let startHostTime: UInt64 = 1_000_000_000

    let recorder: MeetingRecorder
    let microphone: FakeAudioSource
    let systemAudio: FakeAudioSource
    let permissions: FakePermissions
    let playing: FakePlayingProcesses
    let hostClock: FakeHostClock
    let monotonic: FakeMonotonicClock
    let store: FakeMeetingStore
    let diagnostics: RecorderTestDiagnostics

    init(
        permissions: FakePermissions = FakePermissions(), storeAvailable: Bool = true,
        onStopWhileStarting: (@Sendable () async -> Void)? = nil
    ) {
        let microphone = FakeAudioSource(track: .me)
        let systemAudio = FakeAudioSource(track: .them)
        let playing = FakePlayingProcesses()
        let hostClock = FakeHostClock(Self.startHostTime)
        let monotonic = FakeMonotonicClock()
        let store = FakeMeetingStore()
        let diagnostics = RecorderTestDiagnostics()
        var dependencies = MeetingRecorderDependencies(
            microphone: microphone, systemAudio: systemAudio, permissions: permissions,
            playingProcesses: playing, hostClock: hostClock, diagnostics: diagnostics,
            store: { storeAvailable ? store : nil }, now: { monotonic.now }, runsTimers: false,
            segmentSeconds: 1, restartDelay: .zero, restartAttempts: 2)
        dependencies.onStopWhileStarting = onStopWhileStarting
        recorder = MeetingRecorder(dependencies: dependencies)
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.permissions = permissions
        self.playing = playing
        self.hostClock = hostClock
        self.monotonic = monotonic
        self.store = store
        self.diagnostics = diagnostics
    }

    /// Host time `seconds` after Start.
    static func hostTime(_ seconds: Double) -> UInt64 {
        startHostTime + UInt64((seconds * 1_000_000_000).rounded())
    }
}
