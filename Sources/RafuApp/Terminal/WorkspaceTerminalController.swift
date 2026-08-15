import AppKit
import Observation
import SwiftTerm

/// A terminal session's lifecycle: `.idle` until its view is first mounted
/// (spawn is lazy, ADR 0004), `.running` while the shell is alive, `.bell`
/// while it is alive but has requested attention (BEL received while
/// unfocused — terminal-manager.md T-E; cleared back to `.running` the
/// moment its tab is focused again, `WorkspaceTerminalController
/// .clearAttention()`), and `.exited(code:)` once it has quit — either
/// naturally (SwiftTerm's `processTerminated` delegate callback, `code`
/// carries the real exit status) or via explicit `shutdown()` (`code ==
/// nil`, since no process delivered one there).
nonisolated enum TerminalSessionStatus: Equatable, Sendable {
    case idle
    case running
    case bell
    case exited(code: Int32?)
}

/// Owns the set of terminal sessions for a workspace window (ADR 0004,
/// amended by ADR 0014 and the terminal-manager phase T-A: a session may be
/// parked without an editor tab — see
/// `WorkspaceSession.parkedTerminalSessions`). Sessions are created lazily —
/// the first when the panel opens, more via the tab strip — and all are
/// terminated when the workspace switches.
@Observable
@MainActor
final class WorkspaceTerminalManager {
    private(set) var sessions: [WorkspaceTerminalController] = []
    var selectedID: UUID?

    /// TG-20 is the one owner of Terminal Group metadata. Legacy callers
    /// still create unassigned sessions through the adapters below until
    /// TG-30/TG-42 move them to the aggregate launch API.
    @ObservationIgnored
    private var groupRuntime = TerminalGroupRuntime()
    /// The tracked invalidation point for every immutable Terminal Group
    /// projection. The mutable reducer remains private and unobservable.
    private(set) var terminalGroupRevision: UInt64 = 0
    @ObservationIgnored
    private var capacityReservations:
        [TerminalGroupCapacityReservationID: TerminalGroupCapacityReservation] = [:]
    @ObservationIgnored
    private var capacityGeneration: UInt64 = 1

    @ObservationIgnored
    private var sessionCounter = 0
    @ObservationIgnored
    private var parkCounter = 0

    /// Names this manager's owning window for `MemoryTimeline` rows. A
    /// closure rather than a stored string because the workspace (and so
    /// the display name) can change under a live window; wired lazily in
    /// `WorkspaceSession.installTerminalHandlersIfNeeded()` alongside the
    /// other callbacks, and harmlessly empty until then.
    @ObservationIgnored
    var memoryTimelineSource: (@MainActor () -> String)?

    /// Invoked whenever any session's shell exits naturally (never on an
    /// explicit `close`/`shutdown`). `WorkspaceSession` wires this lazily —
    /// see `installTerminalHandlersIfNeeded()`.
    @ObservationIgnored
    var sessionDidExit: (@MainActor (UUID, Int32?) -> Void)?

    /// Invoked whenever any session receives BEL (terminal-manager.md T-E).
    /// `WorkspaceSession.terminalSessionDidBell(_:)` decides whether that
    /// actually raises attention (the session's tab may already be
    /// focused) — wired lazily alongside `sessionDidExit`, see
    /// `installTerminalHandlersIfNeeded()`.
    @ObservationIgnored
    var sessionDidBell: (@MainActor (UUID) -> Void)?

    /// Invoked whenever a session's `.bell` CLEARS (terminal-notch-hud.md)
    /// — the counterpart to `sessionDidBell`, wired alongside it so the
    /// notch HUD dismisses the moment attention clears for any reason.
    @ObservationIgnored
    var sessionDidClearAttention: (@MainActor (UUID) -> Void)?

    var selected: WorkspaceTerminalController? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    var hasSessions: Bool { !sessions.isEmpty }

    /// Immutable group projections. Reading these values never mounts a
    /// SwiftTerm view or starts a child process.
    var terminalGroups: [TerminalGroupSnapshot] {
        _ = terminalGroupRevision
        return groupRuntime.snapshots
    }

    var parkedTerminalGroupIDs: [TerminalGroupID] {
        _ = terminalGroupRevision
        return groupRuntime.parkedGroupIDs
    }

    var retainedTerminalPaneCount: Int {
        _ = terminalGroupRevision
        return groupRuntime.retainedPaneCount
    }

    func terminalGroup(_ id: TerminalGroupID) -> TerminalGroupSnapshot? {
        _ = terminalGroupRevision
        return groupRuntime.snapshot(groupID: id)
    }

    func terminalGroup(containing paneID: TerminalPaneID) -> TerminalGroupID? {
        _ = terminalGroupRevision
        return groupRuntime.groupID(containing: paneID)
    }

    func terminalGroupAndPane(containing sessionID: UUID) -> (TerminalGroupID, TerminalPaneID)? {
        _ = terminalGroupRevision
        return groupRuntime.groupAndPane(containing: sessionID)
    }

    func terminalController(for paneID: TerminalPaneID) -> WorkspaceTerminalController? {
        guard let groupID = groupRuntime.groupID(containing: paneID),
            let sessionID = groupRuntime.snapshot(groupID: groupID)?.panes.first(where: {
                $0.id == paneID
            })?.sessionID
        else { return nil }
        return sessions.first { $0.id == sessionID }
    }

    func terminalController(sessionID: UUID) -> WorkspaceTerminalController? {
        sessions.first { $0.id == sessionID }
    }

    /// The sole public group-mutation entry point. The runtime is value-only:
    /// it cannot create a controller or start a process as a side effect.
    @discardableResult
    func perform(_ command: TerminalGroupCommand) throws -> TerminalGroupEffect {
        if case .prepareClose = command {
            let effect = try groupRuntime.perform(command)
            guard case .requestCloseConfirmation(let runtimeToken) = effect else { return effect }
            let actualLiveProcesses = runtimeToken.affectedSessionIDs.reduce(into: 0) { count, id in
                if terminalController(sessionID: id)?.hasLiveProcess == true { count += 1 }
            }
            guard
                let token = TerminalGroupCloseToken(
                    target: runtimeToken.target,
                    affectedSessionIDs: runtimeToken.affectedSessionIDs,
                    liveProcessCount: actualLiveProcesses, generation: runtimeToken.generation)
            else { throw TerminalGroupValidationError.staleCloseToken }
            return .requestCloseConfirmation(token)
        }
        if case .finalizeClose(let token) = command {
            let effect = try groupRuntime.perform(command)
            closeGroupedControllers(sessionIDs: token.affectedSessionIDs)
            noteTerminalGroupMutation()
            return effect
        }
        switch command {
        case .startPane(let paneID), .restartExitedShellPane(let paneID):
            guard let groupID = groupRuntime.groupID(containing: paneID),
                let pane = groupRuntime.snapshot(groupID: groupID)?.panes.first(where: {
                    $0.id == paneID
                }),
                pane.status == .stopped || pane.status == .exited
            else { break }
            try preflightAdditionalLiveCapacity(1)
        case .startAllRestartablePanes(let groupID):
            let requested =
                groupRuntime.snapshot(groupID: groupID)?.panes.filter {
                    $0.startAvailability == .available
                        && ($0.status == .stopped || $0.status == .exited)
                }.count ?? 0
            try preflightAdditionalLiveCapacity(requested)
        default:
            break
        }
        let effect = try groupRuntime.perform(command)
        noteTerminalGroupMutation()
        return effect
    }

    /// Opens an inert saved-layout instance. It remaps every saved pane and
    /// split identity and creates no controller, view, process, reservation,
    /// or Process Resources entry.
    @discardableResult
    func insertStoppedSavedGroup(_ record: SavedTerminalGroupRecord) throws -> TerminalGroupSnapshot
    {
        let groupID = try groupRuntime.insertStoppedSavedGroup(record)
        noteTerminalGroupMutation()
        guard let group = groupRuntime.snapshot(groupID: groupID) else {
            throw TerminalGroupValidationError.groupNotFound(groupID)
        }
        return group
    }

    /// Creates a one-pane live group as one all-or-nothing transaction. The
    /// controller is lazy: no SwiftTerm view or child process is created here.
    @discardableResult
    func createLiveGroup(
        name: TerminalGroupName? = nil,
        instantiation: TerminalGroupControllerInstantiation,
        reservation: TerminalGroupCapacityReservation? = nil
    ) throws -> TerminalGroupSnapshot {
        try validatePreflight(requested: 1, consuming: reservation)
        try validate(instantiation: instantiation, forStoppedPane: nil, reservation: reservation)
        let counterBeforeTransaction = sessionCounter
        let controller = makeController(instantiation)
        let pane = try livePane(for: instantiation, sessionID: controller.id)
        do {
            let groupID = try groupRuntime.createLiveGroup(
                name: name, sessionID: controller.id, pane: pane)
            sessions.append(controller)
            try consumeReservationAfterCommit(reservation)
            noteTerminalGroupMutation()
            guard let group = groupRuntime.snapshot(groupID: groupID) else {
                throw TerminalGroupValidationError.groupNotFound(groupID)
            }
            return group
        } catch {
            controller.shutdown()
            sessionCounter = counterBeforeTransaction
            cancelReservationAfterFailure(reservation)
            throw error
        }
    }

    /// Starts one existing ordinary-shell pane and atomically binds the lazy
    /// controller to it. A classified reservation can be consumed only here,
    /// after the pane/session membership has committed.
    @discardableResult
    func startPane(
        _ paneID: TerminalPaneID,
        instantiation: TerminalGroupControllerInstantiation,
        reservation: TerminalGroupCapacityReservation? = nil
    ) throws -> WorkspaceTerminalController {
        try validatePreflight(requested: 1, consuming: reservation)
        try validate(instantiation: instantiation, forStoppedPane: paneID, reservation: reservation)
        let counterBeforeTransaction = sessionCounter
        let controller = makeController(instantiation)
        do {
            try groupRuntime.bindLazyController(sessionID: controller.id, to: paneID)
            sessions.append(controller)
            try consumeReservationAfterCommit(reservation)
            noteTerminalGroupMutation()
            return controller
        } catch {
            controller.shutdown()
            sessionCounter = counterBeforeTransaction
            cancelReservationAfterFailure(reservation)
            throw error
        }
    }

    /// Splits a focused pane and binds its new lazy controller in one
    /// transaction. A profile or construction failure restores the exact
    /// prior tree, membership, session counter, and reservation state.
    @discardableResult
    func splitFocusedPane(
        in groupID: TerminalGroupID,
        placement: TerminalGroupSplitPlacement,
        instantiation: TerminalGroupControllerInstantiation,
        reservation: TerminalGroupCapacityReservation? = nil
    ) throws -> WorkspaceTerminalController {
        try validatePreflight(requested: 1, consuming: reservation)
        let runtimeBeforeTransaction = groupRuntime
        let counterBeforeTransaction = sessionCounter
        var controller: WorkspaceTerminalController?
        do {
            _ = try groupRuntime.perform(.splitFocusedPane(groupID: groupID, placement: placement))
            guard let paneID = groupRuntime.snapshot(groupID: groupID)?.focusedPaneID else {
                throw TerminalGroupValidationError.groupNotFound(groupID)
            }
            try validate(
                instantiation: instantiation, forStoppedPane: paneID, reservation: reservation)
            let created = makeController(instantiation)
            controller = created
            try groupRuntime.bindLazyController(sessionID: created.id, to: paneID)
            sessions.append(created)
            try consumeReservationAfterCommit(reservation)
            noteTerminalGroupMutation()
            return created
        } catch {
            controller?.shutdown()
            groupRuntime = runtimeBeforeTransaction
            sessionCounter = counterBeforeTransaction
            cancelReservationAfterFailure(reservation)
            throw error
        }
    }

    /// Restarts an exited ordinary-shell pane with its retained controller and
    /// session UUID. It never creates an unassigned replacement controller.
    func restartExitedPane(_ paneID: TerminalPaneID) throws {
        guard let controller = terminalController(for: paneID) else {
            throw TerminalGroupValidationError.paneNotFound(paneID)
        }
        try preflightAdditionalLiveCapacity(1)
        try groupRuntime.restartBoundController(sessionID: controller.id, paneID: paneID)
        controller.restart()
        noteTerminalGroupMutation()
    }

    /// Starts all explicitly requested restartable panes only after one full
    /// preflight. Callers must supply exactly one validated instantiation for
    /// each eligible pane; unavailable placeholders are intentionally absent.
    func startAllRestartablePanes(
        in groupID: TerminalGroupID,
        instantiations: [TerminalPaneID: TerminalGroupControllerInstantiation],
        reservation: TerminalGroupCapacityReservation? = nil
    ) throws -> [WorkspaceTerminalController] {
        guard let group = groupRuntime.snapshot(groupID: groupID) else {
            throw TerminalGroupValidationError.groupNotFound(groupID)
        }
        let restartable = group.panes.filter {
            $0.startAvailability == .available && ($0.status == .stopped || $0.status == .exited)
        }
        guard Set(instantiations.keys) == Set(restartable.map(\.id)) else {
            throw TerminalGroupValidationError.unsupportedPaneStart
        }
        try validatePreflight(requested: restartable.count, consuming: reservation)
        for pane in restartable {
            guard let instantiation = instantiations[pane.id] else {
                throw TerminalGroupValidationError.paneNotFound(pane.id)
            }
            try validate(
                instantiation: instantiation, forStoppedPane: pane.id, reservation: reservation)
        }
        let runtimeBeforeTransaction = groupRuntime
        let counterBeforeTransaction = sessionCounter
        var controllers: [WorkspaceTerminalController] = []
        do {
            for pane in restartable {
                guard let instantiation = instantiations[pane.id] else {
                    throw TerminalGroupValidationError.paneNotFound(pane.id)
                }
                let controller = makeController(instantiation)
                try groupRuntime.bindLazyController(sessionID: controller.id, to: pane.id)
                controllers.append(controller)
            }
            sessions.append(contentsOf: controllers)
            try consumeReservationAfterCommit(reservation)
            noteTerminalGroupMutation()
            return controllers
        } catch {
            for controller in controllers { controller.shutdown() }
            groupRuntime = runtimeBeforeTransaction
            sessionCounter = counterBeforeTransaction
            cancelReservationAfterFailure(reservation)
            throw error
        }
    }

    @discardableResult
    /// Compatibility adapter. TG-30 migrates ordinary shell callers to the
    /// throwing aggregate launch path; it deliberately keeps its historical,
    /// nonthrowing capacity behaviour during this isolated TG-20 lane.
    func newSession(startingDirectory: String, shell: TerminalShell) -> WorkspaceTerminalController
    {
        sessionCounter += 1
        let session = WorkspaceTerminalController(
            index: sessionCounter,
            startingDirectory: startingDirectory,
            shell: shell
        )
        installCallbacks(on: session)
        sessions.append(session)
        selectedID = session.id
        MemoryTimeline.shared.note(
            .terminalOpened, detail: session.displayName,
            source: memoryTimelineSource?() ?? "")
        return session
    }

    /// Conductor seam (ADR 0018, conductor/C0-shim.md): a session that hosts
    /// an arbitrary executable + argv + cwd + env under the PTY instead of a
    /// login shell. Deliberately a SECOND entry point rather than a
    /// parameter on `newSession(startingDirectory:shell:)` — the login-shell
    /// path's behavior must stay byte-identical, and everything downstream
    /// (exit/bell/attention wiring, `ProcessResourceRegistry` registration)
    /// is shared unchanged. Exercised by tests only until C1.
    @discardableResult
    /// Compatibility adapter. TG-42 migrates classified Agent/Ensemble
    /// callers to the aggregate reservation and launch path.
    func newSession(spec: TerminalProcessSpec) -> WorkspaceTerminalController {
        sessionCounter += 1
        let session = WorkspaceTerminalController(index: sessionCounter, spec: spec)
        installCallbacks(on: session)
        sessions.append(session)
        selectedID = session.id
        MemoryTimeline.shared.note(
            .terminalOpened, detail: session.displayName,
            source: memoryTimelineSource?() ?? "")
        return session
    }

    /// Bumps this session to most-recently-parked, driving
    /// `WorkspaceSession.parkedTerminalSessions`'s MRU ordering. A no-op for
    /// an unknown id.
    /// Compatibility adapter. TG-30/TG-42 move park identity from a session
    /// to a Terminal Group. It remains a no-op for unknown legacy sessions.
    func notePark(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        parkCounter += 1
        session.markParked(sequence: parkCounter)
    }

    /// Terminates one session's shell and removes it. Selection moves to the
    /// nearest remaining session.
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let closedName = sessions[index].displayName
        sessions[index].shutdown()
        sessions.remove(at: index)
        MemoryTimeline.shared.note(
            .terminalClosed, detail: closedName,
            source: memoryTimelineSource?() ?? "")
        if selectedID == id {
            selectedID =
                sessions.indices.contains(index)
                ? sessions[index].id
                : sessions.last?.id
        }
    }

    func shutdownAll() {
        for session in sessions {
            session.shutdown()
        }
        sessions = []
        selectedID = nil
        sessionCounter = 0
        parkCounter = 0
        groupRuntime.shutdown()
        noteTerminalGroupMutation()
        capacityReservations = [:]
        capacityGeneration &+= 1
        if capacityGeneration == 0 { capacityGeneration = 1 }
    }

    /// Keeps all session construction paths on the same callback contract.
    /// The closures are installed once, before a controller becomes visible
    /// to manager queries or can mount its lazy SwiftTerm view.
    private func installCallbacks(on session: WorkspaceTerminalController) {
        session.onExit = { [weak self] id, exitCode in
            if self?.groupRuntime.markSessionExited(id) == true {
                self?.noteTerminalGroupMutation()
            }
            self?.sessionDidExit?(id, exitCode)
        }
        session.onBell = { [weak self] id in
            self?.sessionDidBell?(id)
        }
        session.onAttentionCleared = { [weak self] id in
            self?.sessionDidClearAttention?(id)
        }
    }

    private func noteTerminalGroupMutation() {
        terminalGroupRevision &+= 1
        if terminalGroupRevision == 0 { terminalGroupRevision = 1 }
    }

    /// Final close owns controller shutdown after the caller has completed
    /// its role/coordinator cleanup and the fresh token has passed reducer
    /// validation. The IDs arrive in stable pane-tree order.
    private func closeGroupedControllers(sessionIDs: [UUID]) {
        for sessionID in sessionIDs {
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { continue }
            let controller = sessions.remove(at: index)
            controller.shutdown()
            MemoryTimeline.shared.note(
                .terminalClosed, detail: controller.displayName,
                source: memoryTimelineSource?() ?? "")
        }
        if let selectedID, !sessions.contains(where: { $0.id == selectedID }) {
            self.selectedID = sessions.last?.id
        }
    }

    private func makeController(
        _ instantiation: TerminalGroupControllerInstantiation
    ) -> WorkspaceTerminalController {
        sessionCounter += 1
        let controller: WorkspaceTerminalController
        switch instantiation {
        case .ordinaryShell(let startingDirectory, let shell, _):
            controller = WorkspaceTerminalController(
                index: sessionCounter, startingDirectory: startingDirectory, shell: shell)
        case .process(let spec, _):
            controller = WorkspaceTerminalController(index: sessionCounter, spec: spec)
        }
        installCallbacks(on: controller)
        return controller
    }

    private func livePane(
        for instantiation: TerminalGroupControllerInstantiation,
        sessionID: UUID
    ) throws -> TerminalPaneSnapshot {
        switch instantiation {
        case .ordinaryShell(_, _, let profile):
            return try TerminalPaneSnapshot(
                id: TerminalPaneID(), sessionID: sessionID, explicitUserName: nil,
                reportedTitle: nil, runtimeKind: .ordinaryShell, themeColor: nil,
                status: .live, launchProfile: profile, startAvailability: .available)
        case .process(_, let kind):
            return try TerminalPaneSnapshot(
                id: TerminalPaneID(), sessionID: sessionID, explicitUserName: nil,
                reportedTitle: nil, runtimeKind: kind, themeColor: nil,
                status: .live, launchProfile: nil, startAvailability: .notRestartable)
        }
    }

    private func validatePreflight(
        requested: Int,
        consuming reservation: TerminalGroupCapacityReservation?
    ) throws {
        guard requested >= 0 else {
            throw TerminalGroupCapacityError.invalidReservationCount(requested)
        }
        let reservedToConsume: Int
        if let reservation {
            guard reservation.generation == capacityGeneration,
                capacityReservations[reservation.id] == reservation,
                reservation.reservedLiveSessionCount == requested
            else { throw TerminalGroupCapacityError.staleReservation(reservation.id) }
            reservedToConsume = reservation.reservedLiveSessionCount
        } else {
            reservedToConsume = 0
        }
        let legacyLive = ungroupedLiveSessionCount
        let allReserved = capacityReservations.values.reduce(0) { $0 + $1.reservedLiveSessionCount }
        let current = legacyLive + groupRuntime.liveSessionCount + allReserved - reservedToConsume
        guard current + requested <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupCapacityError.liveSessionLimitExceeded(
                current: current, requested: requested)
        }
    }

    private func consumeReservationAfterCommit(_ reservation: TerminalGroupCapacityReservation?)
        throws
    {
        guard let reservation else { return }
        try removeReservation(reservation)
    }

    private func cancelReservationAfterFailure(_ reservation: TerminalGroupCapacityReservation?) {
        guard let reservation, reservation.generation == capacityGeneration,
            capacityReservations[reservation.id] == reservation
        else { return }
        capacityReservations[reservation.id] = nil
    }

    private var ungroupedLiveSessionCount: Int {
        sessions.filter { session in
            guard groupRuntime.groupAndPane(containing: session.id) == nil else { return false }
            return switch session.status {
            case .idle, .running, .bell: true
            case .exited: false
            }
        }.count
    }

    private func validate(
        instantiation: TerminalGroupControllerInstantiation,
        forStoppedPane paneID: TerminalPaneID?,
        reservation: TerminalGroupCapacityReservation?
    ) throws {
        switch instantiation {
        case .ordinaryShell(_, _, let profile):
            guard reservation == nil else {
                throw TerminalGroupValidationError.unsupportedPaneStart
            }
            guard let paneID else { return }
            guard let groupID = groupRuntime.groupID(containing: paneID),
                let pane = groupRuntime.snapshot(groupID: groupID)?.panes.first(where: {
                    $0.id == paneID
                }),
                pane.runtimeKind == .ordinaryShell,
                pane.launchProfile == profile,
                pane.status == .stopped || pane.status == .exited
            else { throw TerminalGroupValidationError.unsupportedPaneStart }
        case .process(_, let kind):
            guard reservation != nil else {
                throw TerminalGroupValidationError.unsupportedPaneStart
            }
            switch kind {
            case .directAgentTerminal, .ensembleRole, .ensembleCoordinator:
                break
            case .ordinaryShell, .unavailableAgentTerminal, .unavailableEnsemble:
                throw TerminalGroupValidationError.unsupportedPaneStart
            }
            guard paneID == nil else { throw TerminalGroupValidationError.unsupportedPaneStart }
        }
    }
}

extension WorkspaceTerminalManager: TerminalGroupCapacityReserving {
    func reserveLiveSessionCapacity(
        _ requestedLiveSessionCount: Int
    ) throws -> TerminalGroupCapacityReservation {
        guard requestedLiveSessionCount > 0 else {
            throw TerminalGroupCapacityError.invalidReservationCount(requestedLiveSessionCount)
        }
        let committed = ungroupedLiveSessionCount + groupRuntime.liveSessionCount
        let reserved = capacityReservations.values.reduce(0) { $0 + $1.reservedLiveSessionCount }
        guard
            committed + reserved + requestedLiveSessionCount
                <= TerminalGroupSnapshot.maximumPanesPerGroup
        else {
            throw TerminalGroupCapacityError.liveSessionLimitExceeded(
                current: committed + reserved, requested: requestedLiveSessionCount)
        }
        guard
            let reservation = TerminalGroupCapacityReservation(
                generation: capacityGeneration, reservedLiveSessionCount: requestedLiveSessionCount)
        else { throw TerminalGroupCapacityError.invalidReservationCount(requestedLiveSessionCount) }
        capacityReservations[reservation.id] = reservation
        return reservation
    }

    func consumeLiveSessionCapacity(_ reservation: TerminalGroupCapacityReservation) throws {
        // A reservation becomes committed only inside `createLiveGroup`,
        // `startPane`, or `startAllRestartablePanes`. A standalone consume
        // has no pane/session binding and must not make capacity reusable.
        throw TerminalGroupCapacityError.staleReservation(reservation.id)
    }

    func cancelLiveSessionCapacity(_ reservation: TerminalGroupCapacityReservation) throws {
        try removeReservation(reservation)
    }

    private func removeReservation(_ reservation: TerminalGroupCapacityReservation) throws {
        guard reservation.generation == capacityGeneration,
            capacityReservations.removeValue(forKey: reservation.id) == reservation
        else { throw TerminalGroupCapacityError.staleReservation(reservation.id) }
    }

    private func preflightAdditionalLiveCapacity(_ requested: Int) throws {
        guard requested >= 0 else {
            throw TerminalGroupCapacityError.invalidReservationCount(requested)
        }
        let legacyLive = ungroupedLiveSessionCount
        let reserved = capacityReservations.values.reduce(0) { $0 + $1.reservedLiveSessionCount }
        let current = legacyLive + groupRuntime.liveSessionCount + reserved
        guard current + requested <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupCapacityError.liveSessionLimitExceeded(
                current: current, requested: requested)
        }
    }
}

/// One terminal session: a lazily spawned login shell plus its SwiftTerm
/// view. All SwiftTerm types stay behind this boundary.
@Observable
@MainActor
final class WorkspaceTerminalController: Identifiable {
    nonisolated let id = UUID()
    let index: Int
    /// Directory the shell starts in; also the tooltip fallback until the
    /// shell reports its live working directory over OSC 7.
    let startingDirectory: String
    /// The shell binary this session spawns (terminal-manager.md T-C).
    let shell: TerminalShell
    private(set) var status: TerminalSessionStatus = .idle
    /// User-set name (terminal-manager.md T-D) — always wins in
    /// `displayName`. `nil` returns display to the auto name
    /// (`reportedTitle`, then the shell/index fallback). Trimming and the
    /// empty-clears-to-auto rule live in
    /// `WorkspaceSession.renameTerminalSession(_:to:)`, the one caller.
    var userName: String?
    /// Auto title from the shell's own OSC 0/2 report (agent CLIs set this
    /// — "✳ claude", "codex", …). `nil` until the shell reports one, or
    /// after an empty/whitespace-only report clears it. Never wins over
    /// `userName`.
    private(set) var reportedTitle: String?
    /// Color TAG (terminal-manager.md T-D) — a theme palette token, never a
    /// raw color, so themes restyle it. `nil` shows no dot/stripe. Not
    /// persisted (sessions don't restore across relaunch).
    var sessionColor: TerminalSessionColor?
    /// Live working directory reported by the shell via OSC 7, when the
    /// prompt emits it (starship/powerlevel10k do; stock zsh may not).
    private(set) var currentDirectoryPath: String?
    /// MRU sequence stamped by `WorkspaceTerminalManager.notePark(_:)` when
    /// this session's tab is hidden; drives
    /// `WorkspaceSession.parkedTerminalSessions`'s ordering. `0` until
    /// parked at least once.
    private(set) var parkSequence: Int = 0

    /// `userName`, then the shell's own OSC 0/2 title report, then a
    /// generated fallback — the single source of truth for every place
    /// this session's name is shown (panel row, tab label, `.help` text).
    ///
    /// A PATH-LIKE title is skipped: prompt themes (bobthefish, starship)
    /// set the terminal title to the abbreviated cwd, which duplicated the
    /// panel row's own directory line and made sessions read as
    /// "~/D/n/p/p/rafu". Agent CLIs set real names ("✳ claude"), which is
    /// the case auto-naming exists for.
    var displayName: String {
        if let userName { return userName }
        if let reportedTitle, !Self.isPathLikeTitle(reportedTitle) { return reportedTitle }
        return "\(shell.basename) \(index)"
    }

    /// True for titles that are just a filesystem path ("~/x/y", "/usr/…"),
    /// which carry no identity beyond the directory line already shown.
    nonisolated static func isPathLikeTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("~") || trimmed.hasPrefix("/")
    }

    init(index: Int, startingDirectory: String, shell: TerminalShell) {
        self.index = index
        self.startingDirectory = startingDirectory
        self.shell = shell
    }

    /// Arbitrary-process seam (conductor/C0-shim.md, ADR 0021): spawn `spec`
    /// under the PTY instead of a login shell. `userName` is seeded from the
    /// role badge so `displayName` reads "advisor" or "Claude Code" rather
    /// than the CLI's basename, and `shell` is synthesized from the spec's
    /// executable purely so `shellDisplayName` and the name fallback stay
    /// meaningful — nothing on this path ever spawns a login shell.
    init(index: Int, spec: TerminalProcessSpec) {
        self.index = index
        startingDirectory = spec.currentDirectoryPath
        shell = TerminalShell(
            path: spec.executableURL.path, name: spec.roleBadge, isDefault: false)
        processSpec = spec
        userName = spec.roleBadge
    }

    /// Non-`nil` only for a spec-backed process (an Ensemble run or an Agent
    /// Terminal). `nil` keeps the login-shell path exactly as it was; a
    /// stored property with a `nil` default lets the original initializer
    /// above stay untouched.
    @ObservationIgnored
    private(set) var processSpec: TerminalProcessSpec?

    /// Bumped whenever a fresh terminal view must replace the old one.
    private(set) var generation = 0

    @ObservationIgnored
    private var terminalView: RafuTerminalView?
    @ObservationIgnored
    private var delegateProxy: DelegateProxy?
    @ObservationIgnored
    private var appliedStyleSignature = ""
    /// Non-`nil` only for an Ensemble run session whose spec names an
    /// `outputLogURL` — the login-shell and Agent Terminal paths never
    /// construct one.
    /// Retained so its consumer `Task` (and the `FileHandle` it owns) stay
    /// alive for the session's lifetime; released once `finish()` has been
    /// called from both process-exit paths below.
    @ObservationIgnored
    private var outputCapture: ConductorRunOutputCapture?
    /// Invoked once, on natural process exit, forwarded up to
    /// `WorkspaceTerminalManager.sessionDidExit`. Wired by the manager in
    /// `newSession`; `nil` otherwise.
    @ObservationIgnored
    var onExit: (@MainActor (UUID, Int32?) -> Void)?
    /// Invoked once per BEL, forwarded up to
    /// `WorkspaceTerminalManager.sessionDidBell`. Wired by
    /// `RafuTerminalView.onBell` in `makeOrReuseView`; `nil` before a view
    /// mounts.
    @ObservationIgnored
    var onBell: (@MainActor (UUID) -> Void)?

    /// Invoked when `.bell` actually CLEARS (terminal-notch-hud.md): the
    /// HUD dismisses the moment attention clears for any reason — it does
    /// not own that state. Wired by the manager in `newSession`, mirroring
    /// `onBell`.
    @ObservationIgnored
    var onAttentionCleared: (@MainActor (UUID) -> Void)?

    var isRunning: Bool { status == .running }

    var hasLiveProcess: Bool {
        switch status {
        case .running, .bell: true
        case .idle, .exited: false
        }
    }

    var shellDisplayName: String { shell.basename }

    /// Non-`nil` only for a tokenless interactive Agent Terminal. Ensemble
    /// run terminals and ordinary login shells intentionally return `nil`.
    var agentProvider: ConductorCLIID? { processSpec?.agentProvider }

    /// The existing run-terminal seam: only an Ensemble step names an
    /// evidence `outputLogURL`. The terminal canvas uses this to omit the
    /// ordinary shell restart overlay after a completed step; plain shells
    /// and tokenless Agent Terminals remain restartable.
    var isEnsembleRunTerminal: Bool { processSpec?.outputLogURL != nil }

    /// The terminal canvas asks this one presentation seam whether its
    /// ordinary exited-shell overlay applies. A completed Ensemble step is
    /// evidence, not a reusable shell, so it deliberately has no restart
    /// control; all other exited terminal sessions keep one.
    var showsShellExitedOverlay: Bool {
        TerminalSessionPresentation.isExited(status) && !isEnsembleRunTerminal
    }

    /// Whether this session's live view currently sits in the KEY window —
    /// part of the "not focused" test for bell attention (terminal-manager
    /// .md T-E): not the focused tab, OR the app inactive, OR the window
    /// not key. `false` when parked (no mounted view) or never spawned.
    var isHostWindowKey: Bool { terminalView?.window?.isKeyWindow ?? false }

    func markParked(sequence: Int) {
        parkSequence = sequence
    }

    /// Forces `.running` without spawning a real process. `makeOrReuseView`
    /// is the one PRODUCTION path to `.running`, and it genuinely spawns a
    /// shell inside a mounted AppKit view — something headless tests never
    /// do (ADR 0004's lazy spawn). Test-only, mirroring
    /// `processDidTerminate(exitCode:)`'s "internal so tests can drive it
    /// directly" precedent: exercises `noteBell()`/`clearAttention()` and
    /// the attention pipeline above them without a live pty.
    func markRunningForTesting() {
        status = .running
    }

    /// BEL received while the session is NOT the focused tab
    /// (terminal-manager.md T-E) — the guard also gives free coalescing: a
    /// second bell while already `.bell` is a no-op. Only a `.running`
    /// session can be asked to raise attention; the FOCUS decision itself
    /// lives one level up in `WorkspaceSession.terminalSessionDidBell(_:)`
    /// (`TerminalAttentionPolicy.shouldRaiseAttention`), which only calls
    /// this when it decided to raise.
    func noteBell() {
        guard status == .running else { return }
        status = .bell
    }

    /// Clears the attention state once the tab is focused again — both
    /// `WorkspaceSession.selectEditorTab` and `synchronizeSelectionFromLayout`
    /// call this on their `.terminal` branch, and `revealTerminalSession`
    /// calls it directly since it mutates `editorLayout`/`terminal
    /// .selectedID` without going through either. A no-op outside `.bell`.
    /// A real `.bell` → `.running` transition fires `onAttentionCleared` so
    /// the notch HUD dismisses (terminal-notch-hud.md).
    func clearAttention() {
        guard status == .bell else { return }
        status = .running
        onAttentionCleared?(id)
    }

    /// Sends a notification reply's already-sanitized, single-line text
    /// into this session's live pty, followed by a trailing newline — the
    /// agent is blocked on a prompt, so exactly one line can ever be
    /// submitted this way (`TerminalAttentionPolicy.sanitizedReply` is the
    /// one caller that produces `text`). Returns `false` — never respawns,
    /// never queues — when there is no live view (parked with nothing
    /// mounted) or the shell has already exited.
    @discardableResult
    func sendReply(_ text: String) -> Bool {
        guard let terminalView else { return false }
        if case .exited = status { return false }
        terminalView.send(txt: text + "\n")
        clearAttention()
        return true
    }

    /// Bounded read of recent on-screen output for an attention
    /// notification's body (terminal-manager.md T-E) — `""` when there is
    /// no live view (e.g. a race where the shell exited between the bell
    /// and the notification actually posting). See
    /// `RafuTerminalView.recentOutputSnippet` for the bounds and privacy
    /// rules; never call this outside the one notification-posting path
    /// that needs it.
    func recentOutputSnippet() -> String {
        terminalView?.recentOutputSnippet() ?? ""
    }

    /// Returns the live terminal view, creating it and spawning the login
    /// shell on first use.
    func makeOrReuseView(theme: RafuTheme) -> LocalProcessTerminalView {
        if let terminalView {
            applyTheme(theme, to: terminalView)
            return terminalView
        }
        let view = RafuTerminalView(frame: .zero)
        let proxy = DelegateProxy(controller: self)
        delegateProxy = proxy
        view.processDelegate = proxy
        view.onBell = { [weak self] in
            guard let self else { return }
            self.onBell?(self.id)
        }
        // Agent CLIs signal "turn finished / input needed" with OSC 9/777
        // notifications, not BEL — Codex with `tui.notifications = true`,
        // Claude Code's iterm2 channel. Route them into the SAME attention
        // pipeline as BEL: WorkspaceSession still decides focus, and the
        // snippet/notification/HUD machinery downstream is unchanged.
        view.onNotification = { [weak self] _ in
            guard let self else { return }
            self.onBell?(self.id)
        }
        view.installNotificationHandlers()
        // Zero-config completion detection: agent TUIs paint constantly
        // while working and go silent when waiting — a qualified burst
        // followed by silence fires the SAME attention pipeline as BEL
        // (the session still decides focus). Timing/byte-count only;
        // output content is never inspected here.
        view.onOutputActivity = { [weak self] bytes in
            self?.noteOutputActivity(bytes: bytes)
        }
        applyTheme(theme, to: view)

        // A Conductor session spawns its spec; everything else spawns the
        // login shell exactly as before. Only this call differs — status,
        // view retention, and `ProcessResourceRegistry` registration below
        // are shared by both paths.
        if let processSpec {
            // Run-evidence capture (`conductor/C1-single-role-runs.md`):
            // only a Conductor spec that names an `outputLogURL` gets one —
            // the login-shell branch below never constructs a capture.
            if let outputLogURL = processSpec.outputLogURL {
                let capture = ConductorRunOutputCapture(outputLogURL: outputLogURL)
                outputCapture = capture
                view.onOutputRender = { [weak capture] slice in
                    capture?.render(slice) ?? Data(slice)
                }
                view.onOutputRenderFinish = { [weak capture] in
                    capture?.finishRendering() ?? Data()
                }
                view.onOutputCapture = { [weak capture] slice in
                    capture?.record(slice)
                }
            }
            let launch = processSpec.resolvedLaunch()
            view.startProcess(
                executable: launch.executable,
                args: launch.arguments,
                environment: launch.environment,
                execName: launch.execName,
                currentDirectory: launch.currentDirectory
            )
        } else {
            view.startProcess(
                executable: shell.path,
                args: shell.loginArguments,
                environment: nil,
                execName: "-\(shell.basename)",
                currentDirectory: startingDirectory
            )
        }
        status = .running
        terminalView = view

        let shellPid = view.process.shellPid
        if shellPid != 0 {
            let controllerID = id
            // An Ensemble child is attributed by role and vendor; an Agent
            // Terminal carries its own distinct kind; a login shell keeps its
            // existing "Terminal N" naming. Registration stays PID-gated in
            // every case, so an idle Rafu registers nothing (C7 accounting).
            let attribution = processSpec?.resourceAttribution
            let registeredName = attribution ?? "Terminal \(index)"
            let registeredKind: ProcessResourceRegistry.ProcessKind =
                if processSpec?.agentProvider != nil {
                    .agentTerminal
                } else if attribution != nil {
                    .agent
                } else {
                    .terminalShell
                }
            Task {
                await ProcessResourceRegistry.shared.register(
                    id: controllerID,
                    name: registeredName,
                    kind: registeredKind,
                    pid: shellPid
                )
            }
        }

        return view
    }

    func restart() {
        shutdown()
        generation &+= 1
    }

    /// Terminates the shell and releases the emulator. Safe to call twice.
    /// Explicit close only — a shell that exits on its own goes through
    /// `processDidTerminate(exitCode:)` instead, which never calls
    /// `terminate()` since the process is already gone.
    @ObservationIgnored private var quiescenceState = TerminalQuiescencePolicy.State.idle
    @ObservationIgnored private var quiescenceTimer: Timer?
    private static let quiescencePolicy = TerminalQuiescencePolicy()

    private func noteOutputActivity(bytes: Int) {
        // Only while genuinely running: tracking during `.bell` would
        // re-fire attention (duplicate notifications) and `.exited` is dead.
        guard status == .running else { return }
        quiescenceState = Self.quiescencePolicy.advance(quiescenceState, bytes: bytes, at: Date())
        guard quiescenceTimer == nil else { return }
        quiescenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            // Timers fire on the main run loop; same discipline as the
            // SwiftTerm delegate shims.
            MainActor.assumeIsolated { self?.quiescenceTick() }
        }
    }

    private func quiescenceTick() {
        let (fired, next) = Self.quiescencePolicy.checkQuiescence(quiescenceState, at: Date())
        quiescenceState = next
        if fired { onBell?(id) }
        if case .idle = next {
            quiescenceTimer?.invalidate()
            quiescenceTimer = nil
        }
    }

    private func stopQuiescenceTracking() {
        quiescenceTimer?.invalidate()
        quiescenceTimer = nil
        quiescenceState = .idle
    }

    func shutdown() {
        stopQuiescenceTracking()
        terminalView?.flushRenderedOutput()
        terminalView?.terminate()
        terminalView = nil
        delegateProxy = nil
        appliedStyleSignature = ""
        outputCapture?.finish()
        outputCapture = nil
        status = .exited(code: nil)

        let controllerID = id
        Task {
            await ProcessResourceRegistry.shared.unregister(id: controllerID)
        }
    }

    func applyTheme(_ theme: RafuTheme, to view: LocalProcessTerminalView) {
        let signature = "\(theme.name)|\(theme.editor.background)|\(theme.editorFontSize)"
        guard signature != appliedStyleSignature else { return }
        appliedStyleSignature = signature
        view.nativeBackgroundColor = NSColor(rafuHex: theme.editor.background)
        view.nativeForegroundColor = NSColor(rafuHex: theme.editor.foreground)
        view.caretColor = NSColor(rafuHex: theme.editor.cursor)
        view.font = Self.terminalFont(for: theme)
        view.installColors(Self.ansiPalette(for: theme))
    }

    /// Shell prompts (powerlevel10k, starship) rely on Nerd Font glyphs the
    /// system mono font lacks. When the theme does not name an explicit
    /// editor family, prefer an installed patched font before falling back.
    private static func terminalFont(for theme: RafuTheme) -> NSFont {
        let size = theme.editorFontSize
        if let family = theme.fonts?.editor?.family,
            !["system", "SF Mono", ""].contains(family),
            let themed = NSFont(name: family, size: size)
        {
            return themed
        }
        let patchedCandidates = [
            "MesloLGS NF",
            "MesloLGS Nerd Font",
            "JetBrainsMono Nerd Font Mono",
            "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono",
        ]
        for name in patchedCandidates {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Natural process exit (SwiftTerm's delegate callback, not an explicit
    /// `close`/`shutdown`). Per the terminal-manager T-A coordinator
    /// decision, the session lingers as `.exited(code:)` — its tab (or
    /// parked row) stays so the exit code and Restart Shell affordance
    /// remain visible/usable; nothing here removes it from
    /// `WorkspaceTerminalManager.sessions` or any tab. The emulator view is
    /// released since it is unusable once the process is gone. Internal
    /// (not `fileprivate`) so tests can drive it directly.
    func processDidTerminate(exitCode: Int32?) {
        stopQuiescenceTracking()
        status = .exited(code: exitCode)
        terminalView?.flushRenderedOutput()
        terminalView = nil
        delegateProxy = nil
        appliedStyleSignature = ""
        outputCapture?.finish()
        outputCapture = nil

        let controllerID = id
        Task {
            await ProcessResourceRegistry.shared.unregister(id: controllerID)
        }
        onExit?(id, exitCode)
    }

    /// OSC 0/2 title report from the shell (terminal-manager.md T-D — agent
    /// CLIs set this, e.g. "✳ claude"). An empty/whitespace-only report
    /// clears the auto title back to the shell/index fallback rather than
    /// storing blank text; `userName`, when set, always wins regardless
    /// (`displayName`). Internal (not `fileprivate`, mirroring
    /// `processDidTerminate(exitCode:)`) so tests can drive it directly
    /// without a live SwiftTerm delegate callback.
    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        reportedTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// OSC 7 delivers the shell's cwd as a `file://host/path` URI; some
    /// shells send a bare path instead. `nil` clears the report.
    fileprivate func updateCurrentDirectory(_ directory: String?) {
        guard let directory, !directory.isEmpty else {
            currentDirectoryPath = nil
            return
        }
        if directory.hasPrefix("file://"), let url = URL(string: directory) {
            currentDirectoryPath = url.path
        } else {
            currentDirectoryPath = directory
        }
    }

    /// 16-entry ANSI palette derived from theme tokens. Black/white anchor on
    /// text/background tokens so both light and dark themes stay readable.
    private static func ansiPalette(for theme: RafuTheme) -> [SwiftTerm.Color] {
        let ui = theme.ui
        let git = theme.git
        let dark = theme.isDark
        let black = dark ? (ui.borderStrong ?? ui.borderSubtle) : ui.textPrimary
        let white = dark ? ui.textPrimary : ui.appBackground
        let red = ui.error ?? "#E06C75"
        let green = ui.success ?? "#7CC08A"
        let yellow = ui.warning ?? "#D4A24E"
        let blue = ui.info ?? "#82A7F0"
        let magenta = git?.conflict ?? "#C678DD"
        let cyan = ui.remoteIndicator ?? "#74BFCB"
        let normal = [black, red, green, yellow, blue, magenta, cyan, white]
        let bright = [
            dark ? (ui.textMuted ?? ui.textSecondary) : black,
            red, green, yellow, blue, magenta, cyan,
            dark ? ui.textPrimary : white,
        ]
        return (normal + bright).map(terminalColor)
    }

    private static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let nsColor = NSColor(rafuHex: hex).usingColorSpace(.sRGB) ?? .black
        return SwiftTerm.Color(
            red: UInt16(max(0, min(1, nsColor.redComponent)) * 65535),
            green: UInt16(max(0, min(1, nsColor.greenComponent)) * 65535),
            blue: UInt16(max(0, min(1, nsColor.blueComponent)) * 65535)
        )
    }
}

/// Nonisolated shim between SwiftTerm's delegate (called on the main thread,
/// but not actor-annotated) and the MainActor controller.
private final class DelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    private weak var controller: WorkspaceTerminalController?

    init(controller: WorkspaceTerminalController) {
        self.controller = controller
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // SwiftTerm delivers delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            controller?.updateTitle(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            controller?.updateCurrentDirectory(directory)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            controller?.processDidTerminate(exitCode: exitCode)
        }
    }
}
