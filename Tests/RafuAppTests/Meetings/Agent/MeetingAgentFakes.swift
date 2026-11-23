import Foundation
import RafuCore
import Synchronization

@testable import RafuApp

/// What a fake process does.
nonisolated enum FakeAgentBehaviour: Sendable {
    /// Prints the lines, then exits with the code.
    case lines([String], exit: Int32)
    /// Prints the lines, then waits until it is ended (a CLI that retries
    /// or hangs).
    case hang([String])
    /// Writes a file with this name in its working directory, then prints
    /// the lines and exits with the code.
    case writeFile(String, lines: [String], exit: Int32)
}

/// What the fake saw at one start, read while the process "ran" (the
/// folders are removed after the run).
nonisolated struct FakeAgentStart: Sendable {
    var spec: MeetingAgentProcessSpec
    var directoryExisted: Bool
    var directoryMode: Int
    var directoryEntries: [String]
}

/// A fake process handle. `terminate()` while it runs is recorded and ends it.
nonisolated final class FakeAgentHandle: MeetingAgentProcessHandle {
    private struct State {
        var running = true
        var termination: MeetingAgentTermination?
        var waiters: [CheckedContinuation<MeetingAgentTermination, Never>] = []
        var terminateCalls = 0
    }

    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = Mutex(State())

    init(_ behaviour: FakeAgentBehaviour) {
        (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        switch behaviour {
        case .lines(let lines, let exit):
            for line in lines { continuation.yield(Data((line + "\n").utf8)) }
            continuation.finish()
            end(.exited(exit))
        case .hang(let lines):
            for line in lines { continuation.yield(Data((line + "\n").utf8)) }
        case .writeFile(_, let lines, let exit):
            for line in lines { continuation.yield(Data((line + "\n").utf8)) }
            continuation.finish()
            end(.exited(exit))
        }
    }

    /// Calls of `terminate()` while the process ran.
    var terminateCalls: Int { state.withLock { $0.terminateCalls } }

    func terminate() {
        let wasRunning = state.withLock { state -> Bool in
            guard state.running else { return false }
            state.terminateCalls += 1
            return true
        }
        guard wasRunning else { return }
        continuation.finish()
        end(.signalled(15))
    }

    private func end(_ termination: MeetingAgentTermination) {
        let waiters = state.withLock { state in
            state.running = false
            state.termination = termination
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        for waiter in waiters { waiter.resume(returning: termination) }
    }

    func termination() async -> MeetingAgentTermination {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> MeetingAgentTermination? in
                if let termination = state.termination { return termination }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}

/// A fake process runner: `--version` gets `versionOutput`; each other
/// start gets the next behaviour.
nonisolated final class FakeAgentProcessRunner: MeetingAgentProcessRunning {
    private struct State {
        var behaviours: [FakeAgentBehaviour]
        var starts: [FakeAgentStart] = []
        var handles: [FakeAgentHandle] = []
    }

    let versionOutput: String
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let state: Mutex<State>

    init(_ behaviours: [FakeAgentBehaviour], versionOutput: String = "codex-cli 0.171.0") {
        self.versionOutput = versionOutput
        state = Mutex(State(behaviours: behaviours))
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    var starts: [FakeAgentStart] { state.withLock { $0.starts } }
    /// The starts that were not the `--version` probe.
    var runs: [FakeAgentStart] { starts.filter { $0.spec.arguments != ["--version"] } }
    var runHandles: [FakeAgentHandle] { state.withLock { $0.handles } }

    func start(_ spec: MeetingAgentProcessSpec) throws -> any MeetingAgentProcessHandle {
        let path = spec.currentDirectoryURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let record = FakeAgentStart(
            spec: spec, directoryExisted: attributes != nil,
            directoryMode: ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777,
            directoryEntries: ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                .sorted())
        if spec.arguments == ["--version"] {
            state.withLock { $0.starts.append(record) }
            return FakeAgentHandle(.lines([versionOutput], exit: 0))
        }
        let handle = state.withLock { state -> FakeAgentHandle in
            state.starts.append(record)
            let behaviour =
                state.behaviours.isEmpty ? .lines([], exit: 1) : state.behaviours.removeFirst()
            if case .writeFile(let name, _, _) = behaviour {
                FileManager.default.createFile(
                    atPath: spec.currentDirectoryURL.appendingPathComponent(name).path,
                    contents: Data("x".utf8))
            }
            let handle = FakeAgentHandle(behaviour)
            state.handles.append(handle)
            return handle
        }
        startedContinuation.yield()
        return handle
    }
}

/// A locator that finds each CLI at a fixed fake path.
nonisolated struct FakeAgentLocator: MeetingAgentLocating {
    var installed: Set<MeetingAgentCLI> = [.claudeCode, .codex]
    var modified = Date(timeIntervalSince1970: 1)

    func locate(_ cli: MeetingAgentCLI) -> MeetingAgentExecutable? {
        guard installed.contains(cli) else { return nil }
        let path = "/fake/bin/\(MeetingAgentExecutableLocator.executableName(for: cli))"
        return MeetingAgentExecutable(
            url: URL(fileURLWithPath: path), resolvedPath: path, modified: modified)
    }
}

/// Kept probe results in memory, for tests.
nonisolated final class FakeProbeCache: MeetingAgentProbeCacheStoring {
    private let storage = Mutex<[MeetingAgentCLI: MeetingAgentProbeCacheEntry]>([:])

    func entry(for cli: MeetingAgentCLI) -> MeetingAgentProbeCacheEntry? {
        storage.withLock { $0[cli] }
    }

    func setEntry(_ entry: MeetingAgentProbeCacheEntry?, for cli: MeetingAgentCLI) {
        storage.withLock { $0[cli] = entry }
    }
}

/// A probe with fixed results (ready unless set). It starts no process.
nonisolated final class FakeAgentProber: MeetingAgentProbeService {
    private struct State {
        var results: [MeetingAgentCLI: MeetingAgentProbeResult]
        var probes: [(cli: MeetingAgentCLI, refresh: Bool)] = []
        var invalidated: [MeetingAgentCLI] = []
    }

    private let state: Mutex<State>

    init(_ results: [MeetingAgentCLI: MeetingAgentProbeResult] = [:]) {
        state = Mutex(State(results: results))
    }

    var probes: [(cli: MeetingAgentCLI, refresh: Bool)] { state.withLock { $0.probes } }
    var invalidated: [MeetingAgentCLI] { state.withLock { $0.invalidated } }

    func set(_ result: MeetingAgentProbeResult, for cli: MeetingAgentCLI) {
        state.withLock { $0.results[cli] = result }
    }

    func probe(_ cli: MeetingAgentCLI, refresh: Bool) async -> MeetingAgentProbeResult {
        state.withLock {
            $0.probes.append((cli, refresh))
            return $0.results[cli] ?? .ready
        }
    }

    func lastResult(of cli: MeetingAgentCLI) async -> MeetingAgentProbeResult? {
        state.withLock { $0.results[cli] }
    }

    func readyVersion(of cli: MeetingAgentCLI) async -> String? {
        switch cli {
        case .claudeCode: "2.1.330"
        case .codex: "0.171.0"
        }
    }

    func invalidate(_ cli: MeetingAgentCLI) async {
        state.withLock { $0.invalidated.append(cli) }
    }
}

/// Keeps each start and end that the runner reports.
nonisolated final class AgentActivityLog: Sendable {
    struct Entry: Hashable, Sendable {
        var meeting: MeetingID
        var kind: MeetingAgentRunKind
        var cli: MeetingAgentCLI
        var isRunning: Bool
    }

    private let storage = Mutex<[Entry]>([])
    /// Each entry as it comes, for a test that waits for a run to end.
    let changes: AsyncStream<Entry>
    private let continuation: AsyncStream<Entry>.Continuation

    init() {
        (changes, continuation) = AsyncStream<Entry>.makeStream()
    }

    var sink: MeetingAgentRunner.ActivitySink {
        { [self] meeting, activity, isRunning in
            let entry = Entry(
                meeting: meeting, kind: activity.kind, cli: activity.cli, isRunning: isRunning)
            storage.withLock { $0.append(entry) }
            continuation.yield(entry)
        }
    }

    /// Waits until a run of `kind` reports its end.
    func waitForEnd(of kind: MeetingAgentRunKind) async {
        for await entry in changes where entry.kind == kind && !entry.isRunning { return }
    }

    var entries: [Entry] { storage.withLock { $0 } }
}

/// Keeps each diagnostics event.
nonisolated final class AgentTestDiagnostics: MeetingDiagnosticsRecording {
    private let storage = Mutex<[MeetingDiagnosticEvent]>([])

    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        storage.withLock { $0.append(event) }
    }

    var events: [MeetingDiagnosticEvent] { storage.withLock { $0 } }

    var agentRuns: [MeetingDiagnosticEvent] {
        events.filter {
            if case .agentRun = $0 { return true }
            return false
        }
    }
}

/// A real `MeetingStore` at a temporary root with one synthetic meeting.
nonisolated struct AgentTestLibrary {
    static let marker = "Zebrafinch"

    let base: URL
    let store: MeetingStore
    let snapshotRoot: URL
    let runsRoot: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-agent-test-\(UUID().uuidString)", isDirectory: true)
        snapshotRoot = base.appendingPathComponent("Snapshots", isDirectory: true)
        runsRoot = base.appendingPathComponent("Runs", isDirectory: true)
        store = MeetingStore(
            rootDirectory: base.appendingPathComponent("Library", isDirectory: true),
            snapshotRoot: snapshotRoot)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    /// A meeting with turns t1 (me), t2 (speaker-1, holds the marker),
    /// t3 (speaker-2), in `state`.
    func makeMeeting(
        state: MeetingState = .ready, turnText: String? = nil, turnCount: Int = 3,
        title: String = "Sync \(Self.marker)"
    ) async throws -> MeetingID {
        let created = try await store.create(title: title, startDate: Date())
        var turns: [MeetingTurn] = [
            MeetingTurn(
                id: MeetingTurnID(1), track: .me, speaker: .me, start: 0, end: 4,
                text: "Thanks for joining."),
            MeetingTurn(
                id: MeetingTurnID(2), track: .them, speaker: .speaker(1), start: 5, end: 9,
                text: "We ship the \(Self.marker) build on March 14."),
            MeetingTurn(
                id: MeetingTurnID(3), track: .them, speaker: .speaker(2), start: 10, end: 14,
                text: "Sounds good."),
        ]
        if turnCount > 3 {
            for number in 4...turnCount {
                turns.append(
                    MeetingTurn(
                        id: MeetingTurnID(number), track: .them, speaker: .speaker(1),
                        start: Double(number) * 10, end: Double(number) * 10 + 5,
                        text: turnText ?? "More words."))
            }
        }
        var version = try await store.appendTurns(
            turns, to: created.id, expectedVersion: created.version)
        version = try await store.setState(state, of: created.id, expectedVersion: version)
        return created.id
    }

    func makeRunner(
        _ process: FakeAgentProcessRunner,
        diagnostics: AgentTestDiagnostics = AgentTestDiagnostics(),
        locator: FakeAgentLocator = FakeAgentLocator(), timeLimit: Duration = .seconds(30),
        activity: @escaping MeetingAgentRunner.ActivitySink = { _, _, _ in },
        prober: any MeetingAgentProbeService = FakeAgentProber()
    ) -> MeetingAgentRunner {
        let store = store
        return MeetingAgentRunner(
            store: { store }, diagnostics: diagnostics, processRunner: process, locator: locator,
            runsRoot: runsRoot, timeLimit: timeLimit,
            environment: MeetingAgentEnvironment.make(
                path: "/usr/bin:/bin", home: "/Users/test", user: "test"),
            activity: activity, prober: prober)
    }

    /// A ready meeting whose only speaker is `me` (nothing to name).
    func makeMeOnlyMeeting() async throws -> MeetingID {
        let created = try await store.create(title: "Solo", startDate: Date())
        var version = try await store.appendTurns(
            [
                MeetingTurn(
                    id: MeetingTurnID(1), track: .me, speaker: .me, start: 0, end: 4,
                    text: "Notes to self.")
            ], to: created.id, expectedVersion: created.version)
        version = try await store.setState(.ready, of: created.id, expectedVersion: version)
        return created.id
    }

    /// Folders left in the snapshot root and the runs root.
    func leftovers() -> [String] {
        let fileManager = FileManager.default
        let snapshots = (try? fileManager.contentsOfDirectory(atPath: snapshotRoot.path)) ?? []
        let runs = (try? fileManager.contentsOfDirectory(atPath: runsRoot.path)) ?? []
        return snapshots + runs
    }
}

/// A summary agent with fixed probe results. `summarize` runs `behaviour`.
nonisolated final class FakeSummarizer: MeetingAgentSummarizing {
    typealias Behaviour = @Sendable (MeetingID, MeetingAgentCLI) async throws -> MeetingSummaryNotes

    private struct State {
        var results: [MeetingAgentCLI: MeetingAgentProbeResult]
        var summarized: [MeetingAgentCLI] = []
        var cancelled: [MeetingAgentRunKind] = []
    }

    private let state: Mutex<State>
    private let behaviour: Behaviour
    /// Yields at each start of `summarize`.
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(
        _ results: [MeetingAgentCLI: MeetingAgentProbeResult] = [
            .claudeCode: .ready, .codex: .ready,
        ], behaviour: @escaping Behaviour
    ) {
        state = Mutex(State(results: results))
        self.behaviour = behaviour
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
    }

    var summarized: [MeetingAgentCLI] { state.withLock { $0.summarized } }
    var cancelled: [MeetingAgentRunKind] { state.withLock { $0.cancelled } }

    func probe(_ cli: MeetingAgentCLI, refresh: Bool) async -> MeetingAgentProbeResult {
        state.withLock { $0.results[cli] ?? .notInstalled }
    }

    func summarize(_ meeting: MeetingID, using cli: MeetingAgentCLI) async throws
        -> MeetingSummaryNotes
    {
        state.withLock { $0.summarized.append(cli) }
        startedContinuation.yield()
        return try await behaviour(meeting, cli)
    }

    func cancelRun(_ kind: MeetingAgentRunKind, for meeting: MeetingID) async {
        state.withLock { $0.cancelled.append(kind) }
    }
}
