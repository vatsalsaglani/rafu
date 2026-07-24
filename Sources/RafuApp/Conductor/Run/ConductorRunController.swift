import Foundation
import Observation

/// Where a single-role C1 run stands. Every mutation is owned by
/// `ConductorRunController` on the main actor; persisted step status remains
/// the coarser, C0-defined evidence envelope.
nonisolated enum ConductorRunState: Equatable, Sendable {
    case idle
    case preparing
    case running
    case awaitingArtifact
    case awaitingMergeGate
    case completed
    case failed(String)
    case aborted
}

/// One visible, user-initiated role run.
nonisolated struct ConductorRunRequest: Sendable {
    let role: ConductorAgentDefinition
    let taskPrompt: String
    let baseReference: String
    let runID: String

    init(
        role: ConductorAgentDefinition,
        taskPrompt: String,
        baseReference: String = "HEAD",
        runID: String = UUID().uuidString.lowercased()
    ) {
        self.role = role
        self.taskPrompt = taskPrompt
        self.baseReference = baseReference
        self.runID = runID
    }
}

/// Item-driven sheet token. It is deliberately ephemeral and is never part
/// of workspace restoration, so reopening Rafu cannot resurrect a launch
/// form or start a process.
nonisolated struct ConductorNewRunPresentation: Equatable, Identifiable, Sendable {
    let id = UUID()
}

/// Structural failures only. Prompt, artifact, and process-output content
/// never appears in these values, so persisting a reason in the manifest
/// cannot leak run evidence into an app log later.
nonisolated enum ConductorRunError: Error, Equatable, LocalizedError, Sendable {
    case workspaceNotAttached
    case invalidRunID
    case invalidHandoffArtifact
    case emptyTaskPrompt
    case adapterUnavailable
    case worktreeFailure(ConductorWorktreeError)
    case processFailed(Int32?)
    case missingHandoffArtifact
    case unableToPersistEvidence

    var errorDescription: String? {
        switch self {
        case .workspaceNotAttached:
            "Open a local workspace before starting a run."
        case .invalidRunID:
            "The generated run identifier is invalid."
        case .invalidHandoffArtifact:
            "The role's handoff artifact must be a safe relative path."
        case .emptyTaskPrompt:
            "Enter a task prompt before starting the run."
        case .adapterUnavailable:
            "The selected agent adapter is unavailable."
        case .worktreeFailure(let error):
            error.errorDescription
        case .processFailed(let code):
            code.map { "The agent process exited with status \($0)." }
                ?? "The agent process exited without a status."
        case .missingHandoffArtifact:
            "The agent exited successfully without creating its handoff artifact."
        case .unableToPersistEvidence:
            "Rafu could not persist the run evidence."
        }
    }
}

/// Main-actor launch boundary used by the real terminal bridge in increment
/// 3 and by C1's controllable headless fake. The callback must not fire
/// synchronously from `launch`: the returned id is how the controller
/// attributes the later exit.
@MainActor
protocol ConductorRunProcessLaunching: AnyObject {
    func launch(
        specification: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID

    func terminate(sessionID: UUID)
}

/// The run's private evidence layout. The handoff and logs directories are
/// created before the process specification is handed to a launcher.
nonisolated struct ConductorRunEvidence: Equatable, Sendable {
    let runDirectory: URL
    let handoffDirectory: URL
    let logsDirectory: URL
    let promptURL: URL
    let artifactURL: URL
}

nonisolated struct ConductorRunEvidenceService: Sendable {
    @concurrent
    func prepare(
        directory: RafuDotDirectory,
        runID: String,
        handoffArtifact: String,
        prompt: String
    ) async throws -> ConductorRunEvidence {
        guard ConductorRunStore.isValidRunID(runID),
            let artifactComponents = Self.safePathComponents(handoffArtifact)
        else {
            throw ConductorRunError.invalidHandoffArtifact
        }

        let manager = FileManager.default
        let runDirectory = directory.runDirectoryURL(for: runID)
        let handoffDirectory = runDirectory.appending(path: "handoff", directoryHint: .isDirectory)
        let logsDirectory = runDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try manager.createDirectory(
            at: handoffDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(
            at: logsDirectory, withIntermediateDirectories: true)

        var artifactURL = handoffDirectory
        for component in artifactComponents {
            artifactURL.append(path: component)
        }
        try manager.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let promptURL = runDirectory.appending(path: "prompt.md", directoryHint: .notDirectory)
        try Data(prompt.utf8).write(to: promptURL, options: .atomic)
        return ConductorRunEvidence(
            runDirectory: runDirectory,
            handoffDirectory: handoffDirectory,
            logsDirectory: logsDirectory,
            promptURL: promptURL,
            artifactURL: artifactURL)
    }

    @concurrent
    func artifactExists(at url: URL) async -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func safePathComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return components.map(String.init)
    }
}

/// Injectable persistence boundary for ordering tests. The production saver
/// delegates to C0's atomic run store and deliberately keeps write failures
/// out of Rafu logs.
nonisolated protocol ConductorRunManifestSaving: Sendable {
    func save(_ manifest: ConductorRunManifest, to store: ConductorRunStore) async
}

nonisolated struct ConductorRunManifestSaver: ConductorRunManifestSaving {
    func save(_ manifest: ConductorRunManifest, to store: ConductorRunStore) async {
        try? await store.save(manifest)
    }
}

/// Atomic replacement guarantees each saved manifest is whole, but does not
/// serialize overlapping saves: an older lifecycle state can otherwise finish
/// last and replace a newer one. Cancellation cannot provide ordering because
/// it may not stop a store write already in progress, so each successor
/// explicitly awaits its predecessor before saving.
@MainActor
final class ConductorRunManifestWriteQueue {
    private let saver: any ConductorRunManifestSaving
    private var tail: Task<Void, Never>?
    private var generation: UUID?

    init(saver: any ConductorRunManifestSaving = ConductorRunManifestSaver()) {
        self.saver = saver
    }

    @discardableResult
    func enqueue(
        _ manifest: ConductorRunManifest,
        to store: ConductorRunStore
    ) -> Task<Void, Never> {
        let previousTask = tail
        let generation = UUID()
        self.generation = generation
        let task = Task { [weak self, saver] in
            await previousTask?.value
            await saver.save(manifest, to: store)
            guard self?.generation == generation else { return }
            self?.tail = nil
            self?.generation = nil
        }
        tail = task
        return task
    }

    var pendingTask: Task<Void, Never>? {
        tail
    }
}

/// Window-scoped single-role run engine.
///
/// UI-visible transitions stay on `MainActor`. Directory preparation,
/// evidence reads, and manifest writes use `@concurrent` value services.
/// Reentrancy is guarded by `activeGeneration`: every result arriving after
/// abort or after a newer run is ignored.
@Observable
@MainActor
final class ConductorRunController {
    private(set) var state: ConductorRunState = .idle
    private(set) var manifest: ConductorRunManifest?
    private(set) var runs: [ConductorRunManifest] = []
    private(set) var runsLoadError: String?
    private(set) var mergeGateFiles: [ConductorMergeGateFile] = []
    private(set) var mergeGateError: String?
    private(set) var hasAppliedToWorkspace = false
    private(set) var isResolvingMergeGate = false
    var newRunPresentation: ConductorNewRunPresentation?

    var canStartNewRun: Bool {
        !Self.isInFlight(state)
    }

    @ObservationIgnored
    private(set) var store: ConductorRunStore?

    @ObservationIgnored
    private var attachedWorkspaceRoot: URL?

    @ObservationIgnored
    let adapters: [any ConductorCLIAdapter]

    @ObservationIgnored
    private let evidenceService = ConductorRunEvidenceService()

    @ObservationIgnored
    private let worktreeService = ConductorWorktreeService()

    @ObservationIgnored
    private let mergeGateService = ConductorMergeGateService()

    @ObservationIgnored
    private let manifestWrites: ConductorRunManifestWriteQueue

    @ObservationIgnored
    private var activeGeneration: UUID?

    @ObservationIgnored
    private var activeEvidence: ConductorRunEvidence?

    @ObservationIgnored
    private(set) var activeWorkspacePlan: ConductorWorkspacePlan?

    @ObservationIgnored
    private var activeLauncher: (any ConductorRunProcessLaunching)?

    @ObservationIgnored
    private var activeSessionID: UUID?

    @ObservationIgnored
    private var operationTask: Task<Void, Never>?

    init(
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        manifestSaver: any ConductorRunManifestSaving = ConductorRunManifestSaver()
    ) {
        self.adapters = adapters
        manifestWrites = ConductorRunManifestWriteQueue(saver: manifestSaver)
    }

    func adapter(for id: ConductorCLIID) -> (any ConductorCLIAdapter)? {
        adapters.first { $0.id == id }
    }

    /// Attaching reads and writes nothing. Starting the explicit run is the
    /// only path that seeds `.rafu/`. Moving this window to another workspace
    /// aborts (but never deletes) an in-flight run before replacing the store.
    func attach(workspaceRoot: URL?) {
        let root = workspaceRoot?.standardizedFileURL
        guard root != attachedWorkspaceRoot else { return }

        if Self.isInFlight(state) {
            abort()
            guard !Self.isInFlight(state) else {
                runsLoadError = "Finish the current run action before opening another workspace."
                return
            }
        }

        attachedWorkspaceRoot = root
        store = root.map { ConductorRunStore(workspaceRoot: $0) }
        state = .idle
        manifest = nil
        runs = []
        runsLoadError = nil
        mergeGateFiles = []
        mergeGateError = nil
        hasAppliedToWorkspace = false
        isResolvingMergeGate = false
        activeGeneration = nil
        activeEvidence = nil
        activeWorkspacePlan = nil
        activeLauncher = nil
        activeSessionID = nil
    }

    /// Reloads persisted manifests for the attached workspace. This is a
    /// read-only evidence operation: no adapter is probed and no terminal is
    /// reconstructed.
    func reloadRuns() async {
        guard let store, let attachedWorkspaceRoot else {
            runs = []
            runsLoadError = nil
            return
        }

        do {
            let ids = try await store.listRunIDs()
            var loaded: [ConductorRunManifest] = []
            loaded.reserveCapacity(ids.count)
            for id in ids {
                try Task.checkCancellation()
                if let manifest = try await store.load(runID: id) {
                    loaded.append(manifest)
                }
            }
            try Task.checkCancellation()
            guard self.attachedWorkspaceRoot == attachedWorkspaceRoot else { return }
            runs = Self.sortedRuns(loaded)
            if let manifest {
                upsertRun(manifest)
            }
            runsLoadError = nil
        } catch is CancellationError {
            return
        } catch let error as ConductorRunStoreError {
            guard self.attachedWorkspaceRoot == attachedWorkspaceRoot else { return }
            runs = []
            runsLoadError = error.errorDescription
        } catch {
            guard self.attachedWorkspaceRoot == attachedWorkspaceRoot else { return }
            runs = []
            runsLoadError = "Rafu could not read the saved run manifests."
        }
    }

    func attachAndReload(workspaceRoot: URL?) async {
        attach(workspaceRoot: workspaceRoot)
        await reloadRuns()
    }

    func presentNewRun() {
        guard canStartNewRun else { return }
        newRunPresentation = ConductorNewRunPresentation()
    }

    func revealLiveTerminal(
        for runID: String,
        in workspaceSession: WorkspaceSession
    ) {
        guard manifest?.id == runID, let activeSessionID else { return }
        workspaceSession.revealTerminalSession(activeSessionID)
    }

    /// Synchronous UI bridge. The owned task is cancellable through
    /// `abort()`; tests can call and await `start` directly.
    func begin(
        _ request: ConductorRunRequest,
        launcher: any ConductorRunProcessLaunching
    ) {
        guard !Self.isInFlight(state) else { return }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.start(request, launcher: launcher)
            if !Self.isInFlight(self.state) {
                self.operationTask = nil
            }
        }
    }

    /// Prepares and launches one role. Returns once the child has been
    /// attributed and the FSM has entered `.running`.
    func start(
        _ request: ConductorRunRequest,
        launcher: any ConductorRunProcessLaunching
    ) async {
        guard !Self.isInFlight(state) else { return }

        let generation = UUID()
        activeGeneration = generation
        activeLauncher = launcher
        activeSessionID = nil
        activeEvidence = nil
        activeWorkspacePlan = nil
        manifest = nil
        mergeGateFiles = []
        mergeGateError = nil
        hasAppliedToWorkspace = false
        isResolvingMergeGate = false
        transition(to: .preparing)

        do {
            let prompt = try Self.resolvedPrompt(for: request)
            guard ConductorRunStore.isValidRunID(request.runID) else {
                throw ConductorRunError.invalidRunID
            }
            guard let store else {
                throw ConductorRunError.workspaceNotAttached
            }
            guard let adapter = adapter(for: request.role.provider) else {
                throw ConductorRunError.adapterUnavailable
            }

            try Task.checkCancellation()
            _ = try await store.directory.seed()
            try Self.requireCurrent(generation, activeGeneration)

            let evidence = try await evidenceService.prepare(
                directory: store.directory,
                runID: request.runID,
                handoffArtifact: request.role.handoffArtifact,
                prompt: prompt)
            try Self.requireCurrent(generation, activeGeneration)
            activeEvidence = evidence

            let probe = await adapter.probe()
            try Task.checkCancellation()
            try Self.requireCurrent(generation, activeGeneration)
            guard probe.installed, probe.executableURL != nil else {
                throw ConductorRunError.adapterUnavailable
            }

            let workspacePlan: ConductorWorkspacePlan
            do {
                workspacePlan = try await worktreeService.plan(
                    workspaceRoot: store.directory.workspaceRoot,
                    runID: request.runID,
                    autonomy: request.role.autonomy,
                    baseReference: request.baseReference)
            } catch let error as ConductorWorktreeError {
                throw ConductorRunError.worktreeFailure(error)
            }
            try Self.requireCurrent(generation, activeGeneration)
            activeWorkspacePlan = workspacePlan

            let now = Date()
            var newManifest = ConductorRunManifest(
                id: request.runID,
                workflowName: request.role.name,
                baseCommit: workspacePlan.baseCommit,
                worktreeBranch: workspacePlan.branchName ?? "",
                createdAt: now,
                updatedAt: now,
                steps: [
                    ConductorRunManifest.Step(
                        agentName: request.role.name,
                        binding: ConductorRunManifest.AgentBinding(
                            provider: request.role.provider,
                            model: request.role.model,
                            autonomy: request.role.autonomy,
                            adapterVersion: probe.version),
                        inputArtifacts: [],
                        handoffArtifact: request.role.handoffArtifact,
                        gateAfter: true,
                        status: .pending,
                        startedAt: nil,
                        finishedAt: nil)
                ])
            manifest = newManifest
            try await store.save(newManifest)
            try Self.requireCurrent(generation, activeGeneration)
            upsertRun(newManifest)

            do {
                try await worktreeService.materialize(workspacePlan)
            } catch let error as ConductorWorktreeError {
                throw ConductorRunError.worktreeFailure(error)
            }
            try Self.requireCurrent(generation, activeGeneration)

            let invocation = adapter.invocation(
                prompt: prompt,
                model: request.role.model,
                autonomy: request.role.autonomy,
                workingDirectory: workspacePlan.executionRoot,
                runDirectory: evidence.runDirectory,
                handoffDirectory: evidence.handoffDirectory)
            let specification = TerminalProcessSpec(
                executableURL: invocation.executableURL,
                arguments: invocation.arguments,
                currentDirectoryPath: workspacePlan.executionRoot.path,
                environment: invocation.environment,
                roleBadge: request.role.name)

            newManifest.steps[0].status = .running
            newManifest.steps[0].startedAt = Date()
            newManifest.updatedAt = Date()
            manifest = newManifest
            try await store.save(newManifest)
            try Self.requireCurrent(generation, activeGeneration)
            upsertRun(newManifest)

            transition(to: .running)
            let sessionID = try launcher.launch(
                specification: specification
            ) { [weak self] sessionID, exitCode in
                self?.processDidExit(sessionID: sessionID, exitCode: exitCode)
            }
            activeSessionID = sessionID
        } catch is CancellationError {
            guard activeGeneration == generation else { return }
            markAborted()
        } catch let error as ConductorRunError {
            guard activeGeneration == generation else { return }
            recordFailure(error)
        } catch {
            guard activeGeneration == generation else { return }
            recordFailure(.unableToPersistEvidence)
        }
    }

    /// Natural terminal exit. Exit zero advances to an off-main artifact
    /// check; any other status fails without inspecting captured output.
    func processDidExit(sessionID: UUID, exitCode: Int32?) {
        guard activeSessionID == sessionID, state == .running else { return }
        activeSessionID = nil

        guard exitCode == 0 else {
            recordFailure(.processFailed(exitCode))
            return
        }
        guard let evidence = activeEvidence, let generation = activeGeneration else {
            recordFailure(.missingHandoffArtifact)
            return
        }

        transition(to: .awaitingArtifact)
        operationTask?.cancel()
        operationTask = Task { [weak self, evidenceService] in
            let exists = await evidenceService.artifactExists(at: evidence.artifactURL)
            try? Task.checkCancellation()
            guard let self, self.activeGeneration == generation else { return }
            if exists {
                self.markAwaitingMergeGate()
                await self.refreshMergeGateFiles()
            } else {
                self.recordFailure(.missingHandoffArtifact)
            }
            self.operationTask = nil
        }
    }

    /// Stops the child or pending evidence work and records `.aborted`.
    /// User files and worktrees are deliberately untouched.
    func abort() {
        guard Self.isInFlight(state) else { return }
        guard state != .awaitingMergeGate || !isResolvingMergeGate else { return }
        operationTask?.cancel()
        operationTask = nil
        if let activeSessionID {
            activeLauncher?.terminate(sessionID: activeSessionID)
        }
        markAborted()
    }

    /// Leaves the attributed branch/worktree untouched for manual handling.
    func keepWorktree() async {
        guard state == .awaitingMergeGate, !isResolvingMergeGate else { return }
        isResolvingMergeGate = true
        defer { isResolvingMergeGate = false }
        await completeGate()
    }

    /// Applies the Git-derived run patch to an unchanged workspace and
    /// removes the worktree through the non-force cleanup path. A rejected
    /// patch leaves both locations untouched and the gate open.
    func applyToWorkspace() async {
        guard state == .awaitingMergeGate, !isResolvingMergeGate, !hasAppliedToWorkspace,
            let activeWorkspacePlan
        else { return }
        isResolvingMergeGate = true
        defer { isResolvingMergeGate = false }
        mergeGateError = nil
        do {
            _ = try await mergeGateService.apply(activeWorkspacePlan)
            hasAppliedToWorkspace = true
            await completeGate()
        } catch is CancellationError {
            return
        } catch let error as ConductorMergeGateError {
            if error == .appliedButCleanupFailed {
                hasAppliedToWorkspace = true
            }
            mergeGateError = error.errorDescription
        } catch {
            mergeGateError = ConductorMergeGateError.applyRejected.errorDescription
        }
    }

    /// Discard is two-step when Git reports changes. The first call returns
    /// `.confirmationRequired`; only an explicit confirmed retry sanitizes
    /// that exact registered worktree before non-force removal.
    @discardableResult
    func discardWorktree(
        confirmedDirty: Bool
    ) async -> ConductorWorktreeDiscardResult? {
        guard state == .awaitingMergeGate, !isResolvingMergeGate,
            let activeWorkspacePlan
        else {
            return nil
        }
        isResolvingMergeGate = true
        defer { isResolvingMergeGate = false }
        mergeGateError = nil
        do {
            let result = try await worktreeService.discard(
                activeWorkspacePlan,
                confirmedDirty: confirmedDirty)
            if result == .removed {
                await completeGate()
            }
            return result
        } catch is CancellationError {
            return nil
        } catch let error as ConductorWorktreeError {
            mergeGateError = error.errorDescription
            return nil
        } catch {
            mergeGateError = ConductorWorktreeError.unableToDiscardWorktree.errorDescription
            return nil
        }
    }

    func refreshMergeGateFiles() async {
        guard state == .awaitingMergeGate, let activeWorkspacePlan,
            let generation = activeGeneration
        else { return }
        do {
            let files = try await mergeGateService.files(for: activeWorkspacePlan)
            guard
                state == .awaitingMergeGate,
                activeGeneration == generation,
                self.activeWorkspacePlan == activeWorkspacePlan
            else { return }
            mergeGateFiles = files
            mergeGateError = nil
        } catch is CancellationError {
            return
        } catch let error as ConductorMergeGateError {
            guard
                state == .awaitingMergeGate,
                activeGeneration == generation,
                self.activeWorkspacePlan == activeWorkspacePlan
            else { return }
            mergeGateError = error.errorDescription
        } catch {
            guard
                state == .awaitingMergeGate,
                activeGeneration == generation,
                self.activeWorkspacePlan == activeWorkspacePlan
            else { return }
            mergeGateError = ConductorMergeGateError.patchGenerationFailed.errorDescription
        }
    }

    func presentMergeGateDiff(
        _ file: ConductorMergeGateFile,
        in workspaceSession: WorkspaceSession
    ) async {
        guard state == .awaitingMergeGate, let activeWorkspacePlan else { return }
        do {
            let diff = try await mergeGateService.diff(
                for: file,
                plan: activeWorkspacePlan)
            guard
                state == .awaitingMergeGate,
                self.activeWorkspacePlan == activeWorkspacePlan
            else { return }
            workspaceSession.presentConductorDiff(
                diff,
                file: file,
                plan: activeWorkspacePlan)
            mergeGateError = nil
        } catch is CancellationError {
            return
        } catch let error as ConductorMergeGateError {
            guard
                state == .awaitingMergeGate,
                self.activeWorkspacePlan == activeWorkspacePlan
            else { return }
            mergeGateError = error.errorDescription
        } catch {
            guard
                state == .awaitingMergeGate,
                self.activeWorkspacePlan == activeWorkspacePlan
            else { return }
            mergeGateError = ConductorMergeGateError.patchGenerationFailed.errorDescription
        }
    }

    /// Loads persisted evidence for display and starts no process.
    func showRun(id: String) async throws {
        guard let store else { return }
        manifest = try await store.load(runID: id)
        if let manifest {
            upsertRun(manifest)
        }
    }

    /// Headless tests await the exact task that owns the current artifact
    /// check or manifest write; no sleeps or polling.
    func waitForPendingOperation() async {
        let operationTask = operationTask
        await operationTask?.value
        let persistenceTask = manifestWrites.pendingTask
        await persistenceTask?.value
    }

    private func markAwaitingMergeGate() {
        transition(to: .awaitingMergeGate)
        updateStep(status: .awaitingGate, finishedAt: Date())
        scheduleManifestSave()
    }

    private func completeGate() async {
        transition(to: .completed)
        updateStep(status: .completed, finishedAt: Date())
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
        await persistCurrentManifest()
    }

    private func markAborted() {
        transition(to: .aborted)
        updateStep(status: .aborted, finishedAt: Date())
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
        scheduleManifestSave()
    }

    private func recordFailure(_ error: ConductorRunError) {
        let reason = error.errorDescription ?? "The run failed."
        transition(to: .failed(reason))
        updateStep(status: .failed(reason), finishedAt: Date())
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
        scheduleManifestSave()
    }

    private func updateStep(status: RunStepStatus, finishedAt: Date?) {
        guard var manifest, !manifest.steps.isEmpty else { return }
        manifest.steps[0].status = status
        manifest.steps[0].finishedAt = finishedAt
        manifest.updatedAt = Date()
        self.manifest = manifest
        upsertRun(manifest)
    }

    @discardableResult
    private func scheduleManifestSave() -> Task<Void, Never>? {
        guard let store, let manifest else {
            return nil
        }
        return manifestWrites.enqueue(manifest, to: store)
    }

    private func persistCurrentManifest() async {
        let persistenceTask = scheduleManifestSave()
        await persistenceTask?.value
    }

    private func upsertRun(_ manifest: ConductorRunManifest) {
        if let index = runs.firstIndex(where: { $0.id == manifest.id }) {
            runs[index] = manifest
        } else {
            runs.append(manifest)
        }
        runs = Self.sortedRuns(runs)
    }

    private static func sortedRuns(
        _ runs: [ConductorRunManifest]
    ) -> [ConductorRunManifest] {
        runs.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id > $1.id
        }
    }

    private func transition(to next: ConductorRunState) {
        precondition(
            Self.canTransition(from: state, to: next),
            "Invalid Conductor run transition: \(state) -> \(next)")
        state = next
    }

    private static func resolvedPrompt(for request: ConductorRunRequest) throws -> String {
        let task = request.taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw ConductorRunError.emptyTaskPrompt }
        let rolePrompt = request.role.promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            \(rolePrompt)

            Task:
            \(task)

            Write the required handoff artifact to \
            $\(RafuConductorEnvironment.handoff)/\(request.role.handoffArtifact).
            """
    }

    private static func requireCurrent(_ expected: UUID, _ actual: UUID?) throws {
        try Task.checkCancellation()
        guard actual == expected else { throw CancellationError() }
    }

    private static func isInFlight(_ state: ConductorRunState) -> Bool {
        switch state {
        case .preparing, .running, .awaitingArtifact, .awaitingMergeGate:
            true
        case .idle, .completed, .failed, .aborted:
            false
        }
    }

    private static func canTransition(
        from current: ConductorRunState,
        to next: ConductorRunState
    ) -> Bool {
        switch (current, next) {
        case (.idle, .preparing),
            (.completed, .preparing),
            (.failed, .preparing),
            (.aborted, .preparing),
            (.preparing, .running),
            (.preparing, .failed),
            (.preparing, .aborted),
            (.running, .awaitingArtifact),
            (.running, .failed),
            (.running, .aborted),
            (.awaitingArtifact, .awaitingMergeGate),
            (.awaitingArtifact, .failed),
            (.awaitingArtifact, .aborted),
            (.awaitingMergeGate, .completed),
            (.awaitingMergeGate, .failed),
            (.awaitingMergeGate, .aborted):
            true
        default:
            false
        }
    }
}
