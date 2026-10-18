import Foundation
import Observation
import RafuCore

/// The app's one view of agent activity from hooks (X11). Notch, titlebar,
/// and Ensemble terminal nodes read it; each keeps its own output-based
/// fallback when no session matches.
///
/// Data flow: the hook helper writes one small file per event into the
/// private spool. This store watches the spool directory (a
/// `DispatchSource` on its file descriptor) only while a provider is
/// connected, drains it off the main actor (oldest first, at most
/// `AgentHookSpool.drainLimit` files per drain, each file deleted after
/// reading), and folds the events into `AgentSessionLedger`. Nothing here
/// logs a payload, a message, or a path.
@MainActor
@Observable
final class AgentActivityStore {
    static let shared = AgentActivityStore()

    static let connectedProvidersKey = "agentTrackingConnectedProviders"
    /// The clock ticks this often while sessions exist, to age states.
    static let clockInterval: Duration = .seconds(30)
    /// Bounds one drain call; the next spool change or tick continues.
    static let maximumPassesPerDrain = 8

    /// Sessions that need the person first, then the most recent.
    private(set) var sessions: [TrackedAgentSession] = []
    /// Updated on each drain and clock tick, so time-based states (fresh
    /// reply, stale work) recompute.
    private(set) var now = Date()
    private(set) var connectedProviders: Set<AgentHookProvider>

    let paths: AgentTrackingPaths
    @ObservationIgnored private var ledger = AgentSessionLedger()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var isDraining = false
    @ObservationIgnored private var drainsAgain = false
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isOpeningWatcher = false
    @ObservationIgnored private let appProcessID = ProcessInfo.processInfo.processIdentifier

    init(
        paths: AgentTrackingPaths = AgentTrackingPaths(identity: .current),
        defaults: UserDefaults = .standard
    ) {
        self.paths = paths
        self.defaults = defaults
        let raw = defaults.stringArray(forKey: Self.connectedProvidersKey) ?? []
        connectedProviders = Set(raw.compactMap(AgentHookProvider.init(rawValue:)))
    }

    // MARK: - Lifecycle

    /// Starts watching when a provider is connected. Idempotent. Installs
    /// nothing and changes no agent configuration.
    func start() {
        isStarted = true
        guard !connectedProviders.isEmpty, watcher == nil, !isOpeningWatcher else { return }
        isOpeningWatcher = true
        let spool = paths.spool
        Task {
            defer { isOpeningWatcher = false }
            guard let descriptor = await AgentActivityIO.openSpool(spool) else { return }
            guard isStarted, !connectedProviders.isEmpty, watcher == nil else {
                close(descriptor)
                return
            }
            let source = AgentActivityIO.makeWatcher(descriptor: descriptor) { [weak self] in
                await self?.drain()
            }
            watcher = source
            source.resume()
            await drain()
        }
    }

    func stop() {
        isStarted = false
        watcher?.cancel()
        watcher = nil
        clock?.cancel()
        clock = nil
    }

    /// Records a Connect or Disconnect from Settings, then starts or stops
    /// watching.
    func setConnected(_ provider: AgentHookProvider, _ connected: Bool) {
        if connected {
            connectedProviders.insert(provider)
        } else {
            connectedProviders.remove(provider)
        }
        defaults.set(
            connectedProviders.map(\.rawValue).sorted(), forKey: Self.connectedProvidersKey)
        if connectedProviders.isEmpty {
            watcher?.cancel()
            watcher = nil
        } else if isStarted {
            start()
        }
    }

    // MARK: - Draining

    /// Reads one bounded batch off the main actor and folds it. Re-entrant
    /// calls coalesce into one more pass.
    func drain() async {
        if isDraining {
            drainsAgain = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        var passes = 0
        repeat {
            drainsAgain = false
            passes += 1
            let events = await AgentActivityIO.readBatch(paths.spool)
            apply(events, at: Date())
            // A full batch means more files may be waiting.
            if events.count >= AgentHookSpool.drainLimit { drainsAgain = true }
        } while drainsAgain && passes < Self.maximumPassesPerDrain
    }

    /// Folds events into the ledger and publishes. Internal for tests.
    func apply(_ events: [AgentHookEvent], at date: Date) {
        var changed = false
        for event in events where ledger.apply(event) { changed = true }
        if ledger.expire(now: date) { changed = true }
        now = date
        if changed { sessions = ledger.sessions }
        updateClock()
    }

    /// The clock runs only while sessions exist: each tick drains (which
    /// also expires old sessions) and refreshes `now`.
    private func updateClock() {
        if sessions.isEmpty {
            clock?.cancel()
            clock = nil
            return
        }
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.clockInterval)
                guard !Task.isCancelled, let self else { return }
                await self.drain()
            }
        }
    }

    // MARK: - Reading

    /// The live session that runs in `controller`, if any.
    func trackedSession(for controller: WorkspaceTerminalController) -> TrackedAgentSession? {
        guard !sessions.isEmpty, controller.hasLiveProcess else { return nil }
        return AgentTerminalMatcher.session(for: Self.candidate(controller), in: sessions)
    }

    /// Live sessions that run outside every terminal in `controllers` and
    /// outside Rafu itself (another terminal app, an editor).
    func externalSessions(excluding controllers: [WorkspaceTerminalController])
        -> [TrackedAgentSession]
    {
        guard !sessions.isEmpty else { return [] }
        return AgentTerminalMatcher.externalSessions(
            sessions,
            terminals: controllers.filter(\.hasLiveProcess).map(Self.candidate),
            appProcessID: appProcessID)
    }

    static func candidate(_ controller: WorkspaceTerminalController) -> AgentTerminalCandidate {
        AgentTerminalCandidate(
            id: controller.id,
            processID: controller.shellProcessID,
            cwd: controller.currentDirectoryPath ?? controller.startingDirectory,
            provider: controller.resolvedAgentProvider.flatMap(AgentHookProvider.init(cli:)))
    }
}

/// The store's blocking work, always off the main actor.
nonisolated enum AgentActivityIO {
    @concurrent
    static func readBatch(_ spool: URL) async -> [AgentHookEvent] {
        (try? AgentHookSpool.drain(directory: spool)) ?? []
    }

    /// Creates the spool (0700) if needed and opens it for event-only
    /// watching. `nil` when either step fails.
    @concurrent
    static func openSpool(_ spool: URL) async -> Int32? {
        do {
            try FileManager.default.createDirectory(
                at: spool, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let descriptor = open(spool.path, O_EVTONLY)
        return descriptor >= 0 ? descriptor : nil
    }

    /// A directory watcher whose handler only schedules `onChange` on the
    /// main actor. Built here, outside any actor, so the handler closure is
    /// never inferred main-actor-isolated.
    static func makeWatcher(
        descriptor: Int32, onChange: @escaping @MainActor @Sendable () async -> Void
    ) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            Task { @MainActor in await onChange() }
        }
        source.setCancelHandler { close(descriptor) }
        return source
    }
}
