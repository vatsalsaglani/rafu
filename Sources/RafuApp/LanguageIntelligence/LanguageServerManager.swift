import Foundation

/// Per-workspace lifecycle owner for opt-in language servers: one session
/// per languageID, lazily started on first `ensureSession(languageID:)`,
/// idle-shut-down via a cancellable sleeping task reset on activity,
/// crash-backoff (1 s / 5 s / 30 s, then manual restart only), and an RSS
/// ceiling watchdog sampling through `ProcessResourceRegistry`. A bare
/// `actor` — like `LanguageServerSession` and `JSONRPCConnection` — because
/// it needs its own isolation domain independent of the app's `MainActor`
/// default.
///
/// `documentOpened`/`documentChanged`/`documentClosed` never require
/// `activate(rootURI:)` to have run first: `LanguageIntelligenceCoordinator`
/// forwards `WorkspaceSession`'s non-async hooks as independent `Task`s, so
/// nothing guarantees their arrival order. Open URIs are tracked
/// regardless of whether a root is set; `ensureSession` simply declines
/// (`nil`) until `activate(rootURI:)` has run.
actor LanguageServerManager {
    /// A read of one open document's live text, handed to `LanguageServerManager`
    /// only when it's needed to replay `didOpen` for a lazily-started
    /// session — never stored, never logged.
    nonisolated struct DocumentSnapshot: Sendable {
        let uri: String
        let languageID: String
        let text: String
    }

    /// One live, supervised language server.
    private final class ManagedServer {
        let languageID: String
        let serverName: String
        let session: LanguageServerSession
        let pid: pid_t?
        let registryID: UUID
        let rssCeilingBytes: UInt64
        let startInstant: ContinuousClock.Instant

        var phase: LanguageServerStatus.Phase = .starting
        var consecutiveCrashes: Int
        var openURIs: Set<String> = []
        var idleTask: Task<Void, Never>?
        var supervisionTask: Task<Void, Never>?

        init(
            languageID: String,
            serverName: String,
            session: LanguageServerSession,
            pid: pid_t?,
            registryID: UUID,
            consecutiveCrashes: Int,
            rssCeilingBytes: UInt64
        ) {
            self.languageID = languageID
            self.serverName = serverName
            self.session = session
            self.pid = pid
            self.registryID = registryID
            self.rssCeilingBytes = rssCeilingBytes
            self.consecutiveCrashes = consecutiveCrashes
            self.startInstant = .now
        }
    }

    /// Crash/backoff bookkeeping for a languageID that currently has no
    /// live `ManagedServer` — either it's cooling down after a crash, or
    /// backoff is exhausted and only a manual restart can bring it back.
    private struct CrashState {
        var consecutiveCrashes: Int
        var phase: LanguageServerStatus.Phase
        var backoffDeadline: ContinuousClock.Instant?
    }

    private let resolver: any LanguageServerResolving
    private let spawner: any LanguageServerSpawning
    private let registry: ProcessResourceRegistry
    private let bounds: LanguageServerLifecycleBounds
    private let statusSink: @Sendable @MainActor (LanguageServerStatus) -> Void
    private let snapshotProvider: @Sendable (String) async -> [DocumentSnapshot]

    private var rootURI: String?
    private var servers: [String: ManagedServer] = [:]
    private var crashState: [String: CrashState] = [:]
    private var openURIsByLanguage: [String: Set<String>] = [:]
    private var startingTasks: [String: Task<LanguageServerSession?, Never>] = [:]
    private var watchdogTask: Task<Void, Never>?

    /// Bumped on every `activate(rootURI:)`/`deactivate()` call. A spawn in
    /// flight when the workspace deactivates (and possibly reactivates)
    /// checks this in `finishStart` before adopting the result, so a
    /// stale spawn from a since-abandoned activation is shut down instead
    /// of silently orphaned into the new (or absent) activation.
    private var activationEpoch = 0

    init(
        resolver: any LanguageServerResolving = NoLanguageServersResolver(),
        spawner: any LanguageServerSpawning = ProcessLanguageServerSpawner(),
        registry: ProcessResourceRegistry = ProcessResourceRegistry(),
        bounds: LanguageServerLifecycleBounds = LanguageServerLifecycleBounds(),
        statusSink: @escaping @Sendable @MainActor (LanguageServerStatus) -> Void = { _ in },
        snapshotProvider: @escaping @Sendable (String) async -> [DocumentSnapshot] = { _ in [] }
    ) {
        self.resolver = resolver
        self.spawner = spawner
        self.registry = registry
        self.bounds = bounds
        self.statusSink = statusSink
        self.snapshotProvider = snapshotProvider
    }

    // MARK: - Workspace lifecycle

    /// Records the workspace root and starts the RSS watchdog (idempotent —
    /// a second call while one is already running only refreshes the root).
    func activate(rootURI: String) {
        self.rootURI = rootURI
        activationEpoch += 1
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            await self?.watchdogLoop()
        }
    }

    /// Cancels the watchdog, gracefully shuts down and unregisters every
    /// live server, and clears all bookkeeping including tracked open URIs.
    func deactivate() async {
        activationEpoch += 1
        watchdogTask?.cancel()
        watchdogTask = nil
        for languageID in Array(servers.keys) {
            guard let torn = await tearDown(languageID: languageID) else { continue }
            await torn.session.shutdown()
        }
        servers.removeAll()
        crashState.removeAll()
        openURIsByLanguage.removeAll()
        startingTasks.removeAll()
        rootURI = nil
    }

    // MARK: - Session access

    /// Returns a live, ready session for `languageID`, starting one lazily
    /// if needed. Declines (`nil`) when no root is active yet, no server is
    /// resolved for `languageID`, the server is dead (manual restart only),
    /// or it's still cooling down after a crash.
    func ensureSession(languageID: String) async -> LanguageServerSession? {
        if let server = servers[languageID] {
            resetIdleTimer(languageID: languageID)
            return server.session
        }
        if let inFlight = startingTasks[languageID] {
            return await inFlight.value
        }
        guard let rootURI else { return nil }
        guard let resolved = resolver.resolve(languageID: languageID) else { return nil }

        if let crash = crashState[languageID] {
            switch crash.phase {
            case .dead:
                return nil
            case .backingOff:
                guard let deadline = crash.backoffDeadline, ContinuousClock.now >= deadline else {
                    return nil
                }
            default:
                break
            }
        }

        let consecutiveCrashes = crashState[languageID]?.consecutiveCrashes ?? 0
        pushStatus(
            languageID: languageID, serverName: resolved.serverName, phase: .starting,
            residentBytes: nil, consecutiveCrashes: consecutiveCrashes)

        let spawner = spawner
        let epoch = activationEpoch
        let task = Task<LanguageServerSession?, Never> { [weak self] in
            do {
                let spawned = try await spawner.spawn(resolved: resolved, rootURI: rootURI)
                return await self?.finishStart(
                    languageID: languageID, resolved: resolved, spawned: spawned,
                    consecutiveCrashes: consecutiveCrashes, epoch: epoch)
            } catch {
                await self?.recordCrash(
                    languageID: languageID, serverName: resolved.serverName,
                    consecutiveCrashes: consecutiveCrashes + 1)
                return nil
            }
        }
        startingTasks[languageID] = task
        let result = await task.value
        startingTasks[languageID] = nil
        return result
    }

    /// Completes a successful spawn: registers the pid, records the
    /// `ManagedServer`, starts its supervision task, replays `didOpen` for
    /// every URI already tracked open for `languageID`, and starts its idle
    /// timer.
    ///
    /// `epoch` is the `activationEpoch` captured by `ensureSession` *before*
    /// the spawn started. If `deactivate()`/`activate(rootURI:)` ran while
    /// the spawn was in flight, `activationEpoch` will have moved on and
    /// `rootURI` may now be `nil` or point somewhere else entirely — this
    /// spawn belongs to an abandoned activation and must not be adopted:
    /// its session is shut down and it is never registered, tracked, or
    /// surfaced as a status.
    private func finishStart(
        languageID: String, resolved: ResolvedLanguageServer, spawned: SpawnedLanguageServer,
        consecutiveCrashes: Int, epoch: Int
    ) async -> LanguageServerSession? {
        guard activationEpoch == epoch, rootURI != nil else {
            await spawned.session.shutdown()
            return nil
        }

        let registryID = UUID()
        if let pid = spawned.pid {
            await registry.register(
                id: registryID, name: resolved.serverName, kind: .languageServer, pid: pid)
        }

        let managed = ManagedServer(
            languageID: languageID,
            serverName: resolved.serverName,
            session: spawned.session,
            pid: spawned.pid,
            registryID: registryID,
            consecutiveCrashes: consecutiveCrashes,
            rssCeilingBytes: resolved.rssCeilingBytes ?? bounds.defaultRSSCeilingBytes
        )
        let openURIs = openURIsByLanguage[languageID] ?? []
        managed.openURIs = openURIs
        servers[languageID] = managed
        crashState[languageID] = nil

        managed.supervisionTask = Task { [weak self] in
            await spawned.awaitTermination()
            await self?.handleTermination(languageID: languageID, registryID: registryID)
        }

        if !openURIs.isEmpty {
            let snapshots = await snapshotProvider(languageID)
            for snapshot in snapshots where openURIs.contains(snapshot.uri) {
                await spawned.session.didOpen(
                    uri: snapshot.uri, languageID: languageID, text: snapshot.text)
            }
        }

        managed.phase = .ready
        resetIdleTimer(languageID: languageID)
        pushStatus(
            languageID: languageID, serverName: resolved.serverName, phase: .ready,
            residentBytes: nil, consecutiveCrashes: consecutiveCrashes)
        return spawned.session
    }

    // MARK: - Document forwarding

    /// Records `snapshot.uri` as open for `snapshot.languageID` regardless
    /// of whether a live session exists yet, and forwards `didOpen`
    /// immediately when one does.
    func documentOpened(snapshot: DocumentSnapshot) async {
        openURIsByLanguage[snapshot.languageID, default: []].insert(snapshot.uri)
        guard let server = servers[snapshot.languageID] else { return }
        server.openURIs.insert(snapshot.uri)
        await server.session.didOpen(
            uri: snapshot.uri, languageID: snapshot.languageID, text: snapshot.text)
        resetIdleTimer(languageID: snapshot.languageID)
    }

    /// Forwards `didChange` to a live session and resets its idle timer.
    /// Dropped silently if there is no live session for `languageID` — the
    /// URI stays tracked in `openURIsByLanguage` for a later replay.
    func documentChanged(
        uri: String, languageID: String, delta: DocumentEditDelta, newFullText: String
    ) async {
        guard let server = servers[languageID] else { return }
        await server.session.didChange(uri: uri, delta: delta, newFullText: newFullText)
        resetIdleTimer(languageID: languageID)
    }

    /// Stops tracking `uri` as open and forwards `didClose` to a live
    /// session, if any.
    func documentClosed(uri: String, languageID: String) async {
        openURIsByLanguage[languageID]?.remove(uri)
        if openURIsByLanguage[languageID]?.isEmpty == true {
            openURIsByLanguage.removeValue(forKey: languageID)
        }
        guard let server = servers[languageID] else { return }
        server.openURIs.remove(uri)
        await server.session.didClose(uri: uri)
    }

    // MARK: - Manual restart

    /// Clears any crash/cool-down bookkeeping and tears down a live server
    /// (if any), letting the next `ensureSession(languageID:)` start fresh
    /// immediately — for a future C4 "restart" UI action.
    func restart(languageID: String) async {
        crashState[languageID] = nil
        guard let torn = await tearDown(languageID: languageID) else { return }
        await torn.session.shutdown()
    }

    // MARK: - Idle shutdown

    private func resetIdleTimer(languageID: String) {
        guard let server = servers[languageID] else { return }
        server.idleTask?.cancel()
        let idleTimeout = bounds.idleTimeout
        server.idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.idleFired(languageID: languageID)
        }
    }

    /// Tears down *before* calling `shutdown()` — not the reverse — so that
    /// when `shutdown()` drives the process to exit and resolves the
    /// supervision task's `awaitTermination()`, `handleTermination` finds
    /// `languageID` already gone from `servers` (a registryID mismatch) and
    /// no-ops instead of misclassifying this intentional stop as a crash.
    private func idleFired(languageID: String) async {
        guard let torn = await tearDown(languageID: languageID) else { return }
        crashState[languageID] = nil
        await torn.session.shutdown()
        pushStatus(
            languageID: languageID, serverName: torn.serverName, phase: .idle,
            residentBytes: nil, consecutiveCrashes: torn.consecutiveCrashes)
    }

    // MARK: - Crash supervision

    /// The sole death detector: fired when `SpawnedLanguageServer
    /// .awaitTermination()` resolves. `registryID` identifies exactly
    /// which spawn generation died — if `servers[languageID]` no longer
    /// matches it, this server was already intentionally torn down (idle,
    /// ceiling, manual restart, or deactivate), so this is a no-op. This is
    /// what makes `handleTermination`/`tearDown` idempotent regardless of
    /// which path reached them first.
    private func handleTermination(languageID: String, registryID: UUID) async {
        guard let current = servers[languageID], current.registryID == registryID else { return }

        let uptime = ContinuousClock.now - current.startInstant
        let crashes: Int
        if uptime >= bounds.stabilityThreshold {
            // Alive long enough to count as stable: this death starts a
            // fresh crash-count escalation rather than continuing a prior
            // one.
            crashes = 1
        } else {
            crashes = current.consecutiveCrashes + 1
        }

        let serverName = current.serverName
        _ = await tearDown(languageID: languageID)
        recordCrash(languageID: languageID, serverName: serverName, consecutiveCrashes: crashes)
    }

    private func recordCrash(languageID: String, serverName: String, consecutiveCrashes: Int) {
        if let delay = bounds.backoff.delay(afterConsecutiveCrashes: consecutiveCrashes) {
            let deadline = ContinuousClock.now.advanced(by: delay)
            crashState[languageID] = CrashState(
                consecutiveCrashes: consecutiveCrashes, phase: .backingOff,
                backoffDeadline: deadline)
            pushStatus(
                languageID: languageID, serverName: serverName, phase: .backingOff,
                residentBytes: nil, consecutiveCrashes: consecutiveCrashes)
        } else {
            crashState[languageID] = CrashState(
                consecutiveCrashes: consecutiveCrashes, phase: .dead, backoffDeadline: nil)
            pushStatus(
                languageID: languageID, serverName: serverName, phase: .dead,
                residentBytes: nil, consecutiveCrashes: consecutiveCrashes)
        }
    }

    // MARK: - RSS ceiling watchdog

    /// Samples every live server's resident memory once per
    /// `bounds.sampleInterval` and unilaterally kills any server whose
    /// resident memory exceeds its ceiling — no auto-restart afterward,
    /// only a fresh `ensureSession` call restarts it. A missing resident
    /// sample (the registry doesn't have a row yet, or the row's
    /// `residentBytes` is `nil`) is never treated as a breach and never
    /// inferred as death; death is detected exclusively by
    /// `handleTermination`.
    private func watchdogLoop() async {
        while !Task.isCancelled {
            let rows = await registry.sample()
            var residentByRegistryID: [UUID: UInt64?] = [:]
            for row in rows {
                residentByRegistryID[row.id] = row.residentBytes
            }

            for (languageID, server) in servers {
                guard let residentBytes = residentByRegistryID[server.registryID] else {
                    continue
                }
                if RSSCeilingDecision.exceedsCeiling(
                    residentBytes: residentBytes, ceiling: server.rssCeilingBytes)
                {
                    // Tear down *before* `shutdown()` — see `idleFired`'s
                    // doc comment for why this ordering, not the reverse,
                    // is what keeps `handleTermination` from misclassifying
                    // this intentional stop as a crash.
                    guard let torn = await tearDown(languageID: languageID) else { continue }
                    crashState[languageID] = nil
                    await torn.session.shutdown()
                    pushStatus(
                        languageID: languageID, serverName: torn.serverName,
                        phase: .ceilingKilled, residentBytes: residentBytes,
                        consecutiveCrashes: torn.consecutiveCrashes)
                } else if let residentBytes {
                    pushStatus(
                        languageID: languageID, serverName: server.serverName,
                        phase: server.phase, residentBytes: residentBytes,
                        consecutiveCrashes: server.consecutiveCrashes)
                }
            }

            try? await Task.sleep(for: bounds.sampleInterval)
        }
    }

    // MARK: - Shared teardown funnel

    /// The single funnel for every stop path (idle, ceiling, crash, manual
    /// restart, deactivate): removes `languageID` from `servers`, cancels
    /// its idle/supervision tasks, and unregisters its pid from
    /// `ProcessResourceRegistry`. Idempotent — an unknown `languageID` is a
    /// no-op. Never touches `crashState` or pushes a status itself; callers
    /// own that, since only they know which specific outcome (idle,
    /// ceiling, crash-with-a-count, manual, deactivate) just happened.
    @discardableResult
    private func tearDown(languageID: String) async -> ManagedServer? {
        guard let server = servers.removeValue(forKey: languageID) else { return nil }
        server.idleTask?.cancel()
        server.idleTask = nil
        server.supervisionTask?.cancel()
        server.supervisionTask = nil
        await registry.unregister(id: server.registryID)
        return server
    }

    private func pushStatus(
        languageID: String, serverName: String, phase: LanguageServerStatus.Phase,
        residentBytes: UInt64?, consecutiveCrashes: Int
    ) {
        let status = LanguageServerStatus(
            languageID: languageID, serverName: serverName, phase: phase,
            residentBytes: residentBytes, consecutiveCrashes: consecutiveCrashes)
        let sink = statusSink
        Task { await sink(status) }
    }
}
