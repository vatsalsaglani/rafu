import Foundation
import Testing

@testable import RafuApp

// MARK: - Test doubles
//
// Mirrors `LanguageServerSessionTests.swift`'s locally-declared scripted-
// server helpers — each test file keeps its own private copy rather than
// sharing one across files.

/// A scripted in-memory language server: answers `initialize`/`shutdown`
/// and records every `textDocument/didOpen` uri it receives, so tests can
/// assert on lazy-start `didOpen` replay without inspecting
/// `LanguageServerSession`'s private state. Its "process" death is
/// controlled independently via `terminate()`, decoupling crash/backoff
/// tests from needing a fully faithful scripted LSP server.
private actor TestServerHandle {
    private(set) var didOpenURIs: [String] = []
    private(set) var hasTerminated = false
    private var terminationContinuations: [CheckedContinuation<Void, Never>] = []

    func recordDidOpen(uri: String) {
        didOpenURIs.append(uri)
    }

    func awaitTermination() async {
        if hasTerminated { return }
        await withCheckedContinuation { continuation in
            terminationContinuations.append(continuation)
        }
    }

    func terminate() {
        guard !hasTerminated else { return }
        hasTerminated = true
        let continuations = terminationContinuations
        terminationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class ScriptedServerReader {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private var decoder = JSONRPCFrameDecoder()
    private var pendingBodies: [Data] = []

    init(stream: AsyncThrowingStream<Data, any Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func nextFrame() async throws -> Data {
        while pendingBodies.isEmpty {
            guard let chunk = try await iterator.next() else {
                throw ScriptedServerReaderError.transportEnded
            }
            pendingBodies.append(contentsOf: try decoder.consume(chunk))
        }
        return pendingBodies.removeFirst()
    }
}

private enum ScriptedServerReaderError: Error, Equatable {
    case transportEnded
}

private func idFragment(_ id: JSONRPCID) -> String {
    switch id {
    case .number(let value): return String(value)
    case .string(let value): return "\"\(value)\""
    }
}

private func extractDidOpenURI(from params: JSONValue?) -> String? {
    guard case .object(let root)? = params,
        case .object(let textDocument)? = root["textDocument"],
        case .string(let uri)? = textDocument["uri"]
    else { return nil }
    return uri
}

private func runScriptedServer(server: InMemoryLanguageServerTransport, handle: TestServerHandle)
    async
{
    let reader = ScriptedServerReader(stream: await server.receive())
    while true {
        guard let body = try? await reader.nextFrame() else { break }
        guard let message = try? JSONRPCIncomingMessage.classify(body) else { continue }
        switch message {
        case .request(let request) where request.method == "initialize":
            let responseBody = Data(
                #"{"jsonrpc":"2.0","id":\#(idFragment(request.id)),"result":{"capabilities":{}}}"#
                    .utf8)
            try? await server.send(JSONRPCFrameEncoder.encode(body: responseBody))
        case .request(let request) where request.method == "shutdown":
            let responseBody = Data(
                #"{"jsonrpc":"2.0","id":\#(idFragment(request.id)),"result":null}"#.utf8)
            try? await server.send(JSONRPCFrameEncoder.encode(body: responseBody))
        case .notification(let notification) where notification.method == "textDocument/didOpen":
            if let uri = extractDidOpenURI(from: notification.params) {
                await handle.recordDidOpen(uri: uri)
            }
        default:
            break
        }
    }
    // The transport ended (a graceful `shutdown()`/`exit` or the peer
    // closing) — this is exactly what a real process exiting looks like
    // from `SpawnedLanguageServer.awaitTermination()`'s perspective, so
    // resolve it here too. Idempotent: a test that already called
    // `terminate()` to simulate a crash is unaffected.
    await handle.terminate()
}

/// Spawns a scripted in-memory session per call and hands back a
/// `TestServerHandle` per languageID (keyed by `ResolvedLanguageServer
/// .serverName`, which every test sets equal to its languageID) so tests
/// can simulate a crash (`handle.terminate()`) independently of
/// `LanguageServerSession`'s own state.
private actor TestLanguageServerSpawner: LanguageServerSpawning {
    private(set) var spawnCount = 0
    private var handlesByServerName: [String: [TestServerHandle]] = [:]
    private var failuresRemaining: [String: Int] = [:]
    private var shouldGateNextSpawn = false
    private var pendingGate: CheckedContinuation<Void, Never>?

    func failNextSpawns(serverName: String, count: Int) {
        failuresRemaining[serverName] = count
    }

    func handles(serverName: String) -> [TestServerHandle] {
        handlesByServerName[serverName] ?? []
    }

    /// Makes the *next* `spawn` call suspend right after entering (before
    /// doing any transport/session work) until `releaseGate()` is called —
    /// lets a test hold a spawn "in flight" to exercise races against it
    /// (e.g. `deactivate()` running while a spawn is still pending).
    func gateNextSpawn() {
        shouldGateNextSpawn = true
    }

    func releaseGate() {
        pendingGate?.resume()
        pendingGate = nil
    }

    func spawn(resolved: ResolvedLanguageServer, rootURI: String) async throws
        -> SpawnedLanguageServer
    {
        spawnCount += 1
        if let remaining = failuresRemaining[resolved.serverName], remaining > 0 {
            failuresRemaining[resolved.serverName] = remaining - 1
            throw TestSpawnError.injectedFailure
        }
        if shouldGateNextSpawn {
            shouldGateNextSpawn = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingGate = continuation
            }
        }

        let (client, server) = InMemoryLanguageServerTransport.makePair()
        let connection = JSONRPCConnection(transport: client)
        let session = LanguageServerSession(
            connection: connection, serverName: resolved.serverName, rootURI: rootURI,
            initializationOptions: nil)
        let handle = TestServerHandle()
        Task { await runScriptedServer(server: server, handle: handle) }
        try await session.initialize()

        handlesByServerName[resolved.serverName, default: []].append(handle)
        let pid = ProcessInfo.processInfo.processIdentifier
        return SpawnedLanguageServer(
            session: session, pid: pid, awaitTermination: { await handle.awaitTermination() })
    }
}

private enum TestSpawnError: Error, Equatable {
    case injectedFailure
}

private struct TestLanguageServerResolver: LanguageServerResolving {
    let entries: [String: ResolvedLanguageServer]

    func resolve(languageID: String) -> ResolvedLanguageServer? {
        entries[languageID]
    }
}

private func makeResolvedServer(languageID: String, rssCeilingBytes: UInt64? = nil)
    -> ResolvedLanguageServer
{
    ResolvedLanguageServer(
        serverName: languageID,
        launch: LanguageServerLaunchSpecification(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: nil,
            currentDirectoryURL: nil),
        initializationOptions: nil,
        rssCeilingBytes: rssCeilingBytes
    )
}

/// Collects every status `LanguageServerManager` pushes, in order.
@MainActor
private final class StatusCollector {
    private(set) var statuses: [LanguageServerStatus] = []

    func record(_ status: LanguageServerStatus) {
        statuses.append(status)
    }
}

private actor TestSnapshotSource {
    private var snapshotsByLanguage: [String: [LanguageServerManager.DocumentSnapshot]] = [:]

    func set(_ snapshots: [LanguageServerManager.DocumentSnapshot], for languageID: String) {
        snapshotsByLanguage[languageID] = snapshots
    }

    func snapshots(for languageID: String) -> [LanguageServerManager.DocumentSnapshot] {
        snapshotsByLanguage[languageID] ?? []
    }
}

/// Polls `predicate` on a short real sleep between checks — appropriate for
/// waiting on a background timer/watchdog task's *real* wall-clock delay,
/// unlike a tight `Task.yield()` spin (which suits near-instantaneous
/// cross-task signaling, not a `Task.sleep`-based timer).
private func waitUntil(
    timeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(5),
    _ predicate: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await predicate()
}

// MARK: - Lazy start

@Test("ensureSession spawns lazily once, then reuses the live session")
func lazyStartReusesLiveSession() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let manager = LanguageServerManager(resolver: resolver, spawner: spawner)
    await manager.activate(rootURI: "file:///workspace")

    let first = await manager.ensureSession(languageID: "swift")
    #expect(first != nil)
    let second = await manager.ensureSession(languageID: "swift")
    #expect(second != nil)

    #expect(await spawner.spawnCount == 1)

    await manager.deactivate()
}

@Test("An unresolved languageID declines without spawning")
func unresolvedLanguageDeclines() async {
    let spawner = TestLanguageServerSpawner()
    let manager = LanguageServerManager(resolver: NoLanguageServersResolver(), spawner: spawner)
    await manager.activate(rootURI: "file:///workspace")

    let session = await manager.ensureSession(languageID: "swift")
    #expect(session == nil)
    #expect(await spawner.spawnCount == 0)
}

// MARK: - Registry integration

@Test("A spawned server registers its pid; a manual restart unregisters it")
func registryRegistersAndUnregistersPid() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let registry = ProcessResourceRegistry()
    let manager = LanguageServerManager(resolver: resolver, spawner: spawner, registry: registry)
    await manager.activate(rootURI: "file:///workspace")

    _ = await manager.ensureSession(languageID: "swift")
    let samplesAfterStart = await registry.sample()
    #expect(samplesAfterStart.contains { $0.name == "swift" && $0.kind == .languageServer })

    await manager.restart(languageID: "swift")
    let samplesAfterRestart = await registry.sample()
    #expect(!samplesAfterRestart.contains { $0.name == "swift" })

    await manager.deactivate()
}

// MARK: - Idle shutdown

@Test("Idle timeout shuts a server down; activity resets its timer")
func idleTimeoutShutsDownAfterInactivity() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let collector = StatusCollector()
    let bounds = LanguageServerLifecycleBounds(
        idleTimeout: .milliseconds(60), stabilityThreshold: .seconds(5),
        sampleInterval: .seconds(5))
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner, bounds: bounds,
        statusSink: { status in collector.record(status) }
    )
    await manager.activate(rootURI: "file:///workspace")

    _ = await manager.ensureSession(languageID: "swift")

    // Reset the idle timer partway through, well before it would fire.
    try? await Task.sleep(for: .milliseconds(30))
    await manager.documentChanged(
        uri: "file:///a.swift", languageID: "swift",
        delta: DocumentEditDelta(
            range: NSRange(location: 0, length: 0), replacementLength: 0, version: 1),
        newFullText: "x")

    // Past the *original* deadline, but well before the reset deadline —
    // the server must still be alive.
    try? await Task.sleep(for: .milliseconds(45))
    #expect(await spawner.spawnCount == 1)

    let becameIdle = await waitUntil {
        await collector.statuses.contains { $0.phase == .idle }
    }
    #expect(becameIdle)

    // A later call spawns a fresh server.
    _ = await manager.ensureSession(languageID: "swift")
    #expect(await spawner.spawnCount == 2)

    await manager.deactivate()
}

/// Regression test for a real scheduling-dependent race: `shutdown()`
/// drives the process to exit, which resolves the supervision task's
/// `awaitTermination()`. If the server were torn down *after* `shutdown()`
/// (the old, buggy order) rather than before, `handleTermination` could
/// still find the languageID present with a matching registryID and
/// misclassify this intentional idle stop as a crash — recording
/// `.backingOff`/`.dead` and bumping `consecutiveCrashes` instead of the
/// intended `.idle`. The scripted spawner's `awaitTermination` resolves as
/// a real consequence of the transport closing (see `runScriptedServer`),
/// matching the realistic production behavior this race depends on.
@Test("Idle shutdown is never misclassified as a crash")
func idleShutdownIsNeverMisclassifiedAsCrash() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let collector = StatusCollector()
    let bounds = LanguageServerLifecycleBounds(
        idleTimeout: .milliseconds(40), stabilityThreshold: .seconds(5),
        sampleInterval: .seconds(5))
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner, bounds: bounds,
        statusSink: { status in collector.record(status) }
    )
    await manager.activate(rootURI: "file:///workspace")

    _ = await manager.ensureSession(languageID: "swift")

    let becameIdle = await waitUntil {
        await collector.statuses.last?.phase == .idle
    }
    #expect(becameIdle)

    let sawCrashPhase = await collector.statuses.contains {
        $0.phase == .backingOff || $0.phase == .dead
    }
    #expect(!sawCrashPhase)
    #expect(await collector.statuses.last?.consecutiveCrashes == 0)

    // No backoff bookkeeping was recorded, so a fresh call succeeds right
    // away rather than declining as "cooling down".
    let revived = await manager.ensureSession(languageID: "swift")
    #expect(revived != nil)
    #expect(await spawner.spawnCount == 2)

    await manager.deactivate()
}

// MARK: - Crash backoff

@Test(
    "Consecutive fast crashes escalate through the backoff schedule to manual-only, then restart clears it"
)
func fastCrashesEscalateToManualRestart() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let collector = StatusCollector()
    let bounds = LanguageServerLifecycleBounds(
        idleTimeout: .seconds(5), stabilityThreshold: .seconds(5),
        backoff: RestartBackoffPolicy(
            schedule: [.milliseconds(20), .milliseconds(40), .milliseconds(60)]),
        sampleInterval: .seconds(5)
    )
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner, bounds: bounds,
        statusSink: { status in collector.record(status) }
    )
    await manager.activate(rootURI: "file:///workspace")

    // Each iteration below drives a real spawn → terminate → cross-actor
    // status-push round trip (`LanguageServerManager`'s supervision task
    // resuming on the process-death continuation, hopping actors through
    // `handleTermination` → `recordCrash` → `pushStatus`'s own
    // fire-and-forget `Task`, then a `@MainActor` hop into `collector`).
    // Measured directly under this file's full-suite parallel run, a single
    // one of these round trips can take from single-digit milliseconds up
    // to several hundred milliseconds under ordinary cooperative-thread-pool
    // contention — with four crashes chained in one test, `waitUntil`'s
    // 2-second default is not always enough headroom under heavier load,
    // which is what previously made this specific test intermittently show
    // "Expectation failed" with no actual product defect (the manager's own
    // state was always correct; only this test's `#expect` outraced its
    // async signal). `crashRoundTripTimeout` gives every poll in this test
    // real headroom instead.
    let crashRoundTripTimeout = Duration.seconds(5)

    for _ in 0..<3 {
        let session = await waitForSession(manager: manager, languageID: "swift")
        #expect(session != nil)
        let handles = await spawner.handles(serverName: "swift")
        await handles.last?.terminate()
        let becameBackingOff = await waitUntil(timeout: crashRoundTripTimeout) {
            await collector.statuses.last?.phase == .backingOff
        }
        #expect(becameBackingOff)
    }

    // A 4th fast crash exhausts the 3-step schedule: manual restart only.
    let fourthSession = await waitForSession(manager: manager, languageID: "swift")
    #expect(fourthSession != nil)
    let handlesBeforeDeath = await spawner.handles(serverName: "swift")
    await handlesBeforeDeath.last?.terminate()
    // In addition to the longer timeout above: `pushStatus`'s fire-and-
    // forget `Task`s are not guaranteed to land on `collector.statuses` in
    // creation order once the cooperative thread pool is under contention,
    // so `.last?.phase` could in principle observe an earlier push that
    // actually arrives after this one. Poll for the terminal `.dead` status
    // having been recorded at all (with the crash count this exact death
    // produces) instead of requiring it be literally the newest array
    // entry; the manager's own authoritative state — queried directly via
    // `ensureSession` below — is what the rest of this test actually
    // verifies.
    let becameDead = await waitUntil(timeout: crashRoundTripTimeout) {
        await collector.statuses.contains { $0.phase == .dead && $0.consecutiveCrashes == 4 }
    }
    #expect(becameDead)

    // No amount of waiting brings it back on its own.
    try? await Task.sleep(for: .milliseconds(120))
    let declinedWhileDead = await manager.ensureSession(languageID: "swift")
    #expect(declinedWhileDead == nil)

    // A manual restart clears the counter and lets the next call start
    // fresh immediately, with a reset crash count.
    await manager.restart(languageID: "swift")
    let revived = await manager.ensureSession(languageID: "swift")
    #expect(revived != nil)

    // `pushStatus` pushes through its own fire-and-forget `Task`, so the
    // fresh `.ready` push can still be in flight the instant
    // `ensureSession` returns — poll for it rather than reading
    // `collector.statuses` once immediately.
    let becameFreshReady = await waitUntil(timeout: crashRoundTripTimeout) {
        let last = await collector.statuses.last
        return last?.phase == .ready && last?.consecutiveCrashes == 0
    }
    #expect(becameFreshReady)

    await manager.deactivate()
}

@Test("A server that stays alive past the stability threshold restarts its crash count fresh")
func stableUptimeResetsCrashCount() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "rust": makeResolvedServer(languageID: "rust")
    ])
    let collector = StatusCollector()
    let bounds = LanguageServerLifecycleBounds(
        idleTimeout: .seconds(5), stabilityThreshold: .milliseconds(80),
        backoff: RestartBackoffPolicy(
            schedule: [.milliseconds(20), .milliseconds(40), .milliseconds(60)]),
        sampleInterval: .seconds(5)
    )
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner, bounds: bounds,
        statusSink: { status in collector.record(status) }
    )
    await manager.activate(rootURI: "file:///workspace")

    // Crash 1: fast, right after start.
    _ = await waitForSession(manager: manager, languageID: "rust")
    var handles = await spawner.handles(serverName: "rust")
    await handles.last?.terminate()
    var backedOff = await waitUntil { await collector.statuses.last?.phase == .backingOff }
    #expect(backedOff)
    #expect(await collector.statuses.last?.consecutiveCrashes == 1)

    // Crash 2: also fast — escalates to crash count 2.
    _ = await waitForSession(manager: manager, languageID: "rust")
    handles = await spawner.handles(serverName: "rust")
    await handles.last?.terminate()
    backedOff = await waitUntil { await collector.statuses.last?.phase == .backingOff }
    #expect(backedOff)
    #expect(await collector.statuses.last?.consecutiveCrashes == 2)

    // Crash 3: this time the server survives past `stabilityThreshold`
    // before dying — the crash count must reset to 1, not escalate to 3.
    _ = await waitForSession(manager: manager, languageID: "rust")
    try? await Task.sleep(for: .milliseconds(120))
    handles = await spawner.handles(serverName: "rust")
    await handles.last?.terminate()
    backedOff = await waitUntil { await collector.statuses.last?.phase == .backingOff }
    #expect(backedOff)
    #expect(await collector.statuses.last?.consecutiveCrashes == 1)

    await manager.deactivate()
}

// MARK: - RSS ceiling watchdog

@Test("A server exceeding its RSS ceiling is killed with no auto-restart")
func ceilingBreachKillsWithNoAutoRestart() async {
    let spawner = TestLanguageServerSpawner()
    // A ceiling of 1 byte is always exceeded by this test process's own
    // real resident memory (the spawner reuses this process's own pid so
    // the watchdog samples a real, non-nil reading).
    let resolver = TestLanguageServerResolver(entries: [
        "heavy": makeResolvedServer(languageID: "heavy", rssCeilingBytes: 1)
    ])
    let collector = StatusCollector()
    let registry = ProcessResourceRegistry()
    let bounds = LanguageServerLifecycleBounds(
        idleTimeout: .seconds(5), stabilityThreshold: .seconds(5),
        sampleInterval: .milliseconds(20)
    )
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner, registry: registry, bounds: bounds,
        statusSink: { status in collector.record(status) }
    )
    await manager.activate(rootURI: "file:///workspace")

    _ = await manager.ensureSession(languageID: "heavy")

    let becameCeilingKilled = await waitUntil {
        await collector.statuses.contains { $0.phase == .ceilingKilled }
    }
    #expect(becameCeilingKilled)

    let samplesAfterKill = await registry.sample()
    #expect(!samplesAfterKill.contains { $0.name == "heavy" })

    // No crash bookkeeping was recorded, so a fresh manual call is never
    // blocked by backoff.
    let revived = await manager.ensureSession(languageID: "heavy")
    #expect(revived != nil)
    #expect(await spawner.spawnCount == 2)

    await manager.deactivate()
}

/// Regression test for the same race as `idleShutdownIsNeverMisclassifiedAsCrash`,
/// this time via the ceiling-kill path in `watchdogLoop`: `shutdown()` is
/// called after `tearDown()`, not before, so `handleTermination` sees a
/// registryID mismatch and no-ops instead of recording a spurious crash.
@Test("Ceiling kill is never misclassified as a crash")
func ceilingKillIsNeverMisclassifiedAsCrash() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "heavy": makeResolvedServer(languageID: "heavy", rssCeilingBytes: 1)
    ])
    let collector = StatusCollector()
    let registry = ProcessResourceRegistry()
    let bounds = LanguageServerLifecycleBounds(
        idleTimeout: .seconds(5), stabilityThreshold: .seconds(5),
        sampleInterval: .milliseconds(20)
    )
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner, registry: registry, bounds: bounds,
        statusSink: { status in collector.record(status) }
    )
    await manager.activate(rootURI: "file:///workspace")

    _ = await manager.ensureSession(languageID: "heavy")

    let becameCeilingKilled = await waitUntil {
        await collector.statuses.last?.phase == .ceilingKilled
    }
    #expect(becameCeilingKilled)

    let sawCrashPhase = await collector.statuses.contains {
        $0.phase == .backingOff || $0.phase == .dead
    }
    #expect(!sawCrashPhase)
    #expect(await collector.statuses.last?.consecutiveCrashes == 0)

    await manager.deactivate()
}

// MARK: - Deactivate

@Test("deactivate shuts down and unregisters every live server")
func deactivateTearsDownEverything() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift"),
        "rust": makeResolvedServer(languageID: "rust"),
    ])
    let registry = ProcessResourceRegistry()
    let manager = LanguageServerManager(resolver: resolver, spawner: spawner, registry: registry)
    await manager.activate(rootURI: "file:///workspace")

    _ = await manager.ensureSession(languageID: "swift")
    _ = await manager.ensureSession(languageID: "rust")
    #expect(await registry.sample().count == 2)

    await manager.deactivate()

    #expect(await registry.sample().isEmpty)
    // The root was cleared too, so a later call declines until reactivated.
    let session = await manager.ensureSession(languageID: "swift")
    #expect(session == nil)
}

/// Regression test for the activation-epoch guard: a spawn still in flight
/// when `deactivate()` runs must not be adopted once it completes — no
/// `ManagedServer`, no pid registration, and the late-arriving session is
/// shut down rather than silently orphaned (which would otherwise only
/// self-heal after a full idle timeout, and against the wrong root).
@Test("deactivate() during an in-flight spawn orphans and shuts down the late server")
func deactivateDuringInFlightSpawnDoesNotAdoptLateServer() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let registry = ProcessResourceRegistry()
    let manager = LanguageServerManager(resolver: resolver, spawner: spawner, registry: registry)
    await manager.activate(rootURI: "file:///workspace")

    await spawner.gateNextSpawn()
    let inFlight = Task { await manager.ensureSession(languageID: "swift") }

    // Once `spawnCount` reaches 1, the spawn call is guaranteed to already
    // be parked at the gate (or about to be, atomically) — `spawn()` is
    // actor-isolated and has no suspension point between the increment and
    // the gate's `withCheckedContinuation`, so this manager can't have
    // observed the increment while the spawner's own actor is anywhere
    // else.
    let gated = await waitUntil { await spawner.spawnCount == 1 }
    #expect(gated)

    await manager.deactivate()
    await spawner.releaseGate()

    let result = await inFlight.value
    #expect(result == nil)

    let samples = await registry.sample()
    #expect(!samples.contains { $0.name == "swift" })

    let handle = await spawner.handles(serverName: "swift").last
    let shutDown = await waitUntil {
        guard let handle else { return false }
        return await handle.hasTerminated
    }
    #expect(shutDown)

    // A later, freshly-activated call is unaffected and starts a brand new
    // spawn — no lingering epoch/root confusion.
    await manager.activate(rootURI: "file:///workspace")
    let fresh = await manager.ensureSession(languageID: "swift")
    #expect(fresh != nil)
    #expect(await spawner.spawnCount == 2)

    await manager.deactivate()
}

// MARK: - Out-of-order tolerance (correction C)

@Test(
    "documentOpened before activate does not crash, and the URI replays once the server lazily starts"
)
func documentOpenedBeforeActivateReplaysOnLaterStart() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let snapshotSource = TestSnapshotSource()
    let uri = "file:///a.swift"
    await snapshotSource.set(
        [LanguageServerManager.DocumentSnapshot(uri: uri, languageID: "swift", text: "let x = 1")],
        for: "swift")

    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner,
        snapshotProvider: { languageID in await snapshotSource.snapshots(for: languageID) }
    )

    // Arrives before `activate(rootURI:)` — must not crash, and must
    // decline (not spawn) since there's no root yet.
    await manager.documentOpened(
        snapshot: LanguageServerManager.DocumentSnapshot(
            uri: uri, languageID: "swift", text: "let x = 1"))
    let declinedBeforeActivate = await manager.ensureSession(languageID: "swift")
    #expect(declinedBeforeActivate == nil)
    #expect(await spawner.spawnCount == 0)

    await manager.activate(rootURI: "file:///workspace")
    let session = await manager.ensureSession(languageID: "swift")
    #expect(session != nil)

    // `didOpen` is sent as a fire-and-forget wire notification; give the
    // scripted server's independent reader task a real chance to process
    // it before asserting.
    let replayed = await waitUntil {
        let handles = await spawner.handles(serverName: "swift")
        return await handles.last?.didOpenURIs == [uri]
    }
    #expect(replayed)

    await manager.deactivate()
}

// MARK: - Helpers

/// Retries `ensureSession` until it succeeds (or a real-time budget is
/// exhausted) — used after a crash where the manager may still be
/// cooling down.
private func waitForSession(manager: LanguageServerManager, languageID: String) async
    -> LanguageServerSession?
{
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if let session = await manager.ensureSession(languageID: languageID) {
            return session
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await manager.ensureSession(languageID: languageID)
}
