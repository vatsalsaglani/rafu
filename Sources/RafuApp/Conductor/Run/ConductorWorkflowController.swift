import Foundation
import Observation

/// Where a C5 pipeline run stands. Distinct from `ConductorRunState`
/// (C1's single-role FSM) because a pipeline tracks WHICH step is live —
/// `.awaitingGate(index:)` is a per-step user gate declared by the workflow
/// file (`[gate]`), separate from `.awaitingMergeGate`, which is the one
/// terminal worktree merge-back gate C1 already established and this
/// controller reuses unchanged.
nonisolated enum ConductorWorkflowState: Equatable, Sendable {
    case idle
    case preparing
    case runningStep(index: Int)
    case awaitingArtifact(index: Int)
    case awaitingGate(index: Int)
    /// Parked at the human plan gate (C8-04): a fully-validated
    /// `run --plan-gate` request with every step still `.pending` and NO
    /// AGENT spawned — no worktree, no agent process, no evidence directory.
    /// Validation itself is not free: reaching this state has already run
    /// read-only git queries and each step's adapter-version probe
    /// (`<cli> --version`), which is what makes the parked plan trustworthy.
    /// In-flight (counts against grant concurrency) but has no "current step
    /// index" the way `.runningStep`/`.awaitingGate` do.
    case awaitingPlanGate
    case awaitingMergeGate
    case completed
    case failed(step: Int, reason: String)
    case aborted
}

/// One visible, user-initiated pipeline run. `roles` is index-aligned with
/// `workflow.steps` and pre-resolved by `ConductorWorkflowBinder` — this
/// controller never resolves an agent name itself.
nonisolated struct ConductorWorkflowRunRequest: Sendable {
    let workflow: ConductorWorkflowDefinition
    let roles: [ConductorAgentDefinition]
    let taskPrompt: String
    let baseReference: String
    let runID: String
    var startedBy: String? = nil
    var label: String? = nil
    /// `run --plan-gate` (C8-04): park at a human plan gate instead of
    /// materializing a worktree and launching step 0.
    var planGateRequested: Bool = false
    /// Workspace-relative paths for the plan gate's "files as tabs" UI — the
    /// workflow file plus each matched agent file. Best-effort and
    /// presentation-only; empty when the caller does not supply real paths
    /// (e.g. a UI-started run, or a unit test).
    var planGateFiles: [String] = []

    init(
        workflow: ConductorWorkflowDefinition,
        roles: [ConductorAgentDefinition],
        taskPrompt: String,
        baseReference: String = "HEAD",
        runID: String = UUID().uuidString.lowercased(),
        startedBy: String? = nil,
        label: String? = nil,
        planGateRequested: Bool = false,
        planGateFiles: [String] = []
    ) {
        self.workflow = workflow
        self.roles = roles
        self.taskPrompt = taskPrompt
        self.baseReference = baseReference
        self.runID = runID
        self.startedBy = startedBy
        self.label = label
        self.planGateRequested = planGateRequested
        self.planGateFiles = planGateFiles
    }
}

/// A gate becoming ready. Typed rather than two loose strings so the
/// notification layer can decide which ACTIONS to offer: `Approve` exists only
/// when the workflow author opted that gate in (`[gate:remote]`), and never for
/// a merge gate, which writes to the user's workspace.
///
/// Carries identity and names only — never artifact, prompt, or captured
/// process output (ADR 0018).
nonisolated struct ConductorGateReadyEvent: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case step
        case merge
        /// A parked plan gate (C8-04). Like `.merge`, NEVER remotely
        /// approvable regardless of any workflow marker.
        case plan
    }

    let runID: String
    let kind: Kind
    let stepIndex: Int
    let workflowName: String
    let agentName: String
    /// `true` only for a `[gate:remote]` step gate. A merge gate is always
    /// `false`.
    let safeToApproveRemotely: Bool
}

/// Structural pipeline failures only — the same "never prompt, artifact, or
/// process-output content" contract as `ConductorRunError`, with a step index
/// attached where a failure is attributable to one step.
nonisolated enum ConductorWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case workspaceNotAttached
    case invalidRunID
    case emptyTaskPrompt
    case roleCountMismatch
    case adapterUnavailable(step: Int)
    case invalidHandoffArtifact(step: Int)
    case unresolvedInputArtifact(step: Int, artifact: String)
    case worktreeFailure(ConductorWorktreeError)
    case processFailed(step: Int, exitCode: Int32?)
    case missingHandoffArtifact(step: Int)
    case unableToPersistEvidence(step: Int)

    /// `nil` for failures that precede any specific step (an invalid
    /// request, or a whole-run seed/plan failure before step 0 launches).
    var stepIndex: Int? {
        switch self {
        case .adapterUnavailable(let step),
            .invalidHandoffArtifact(let step),
            .unresolvedInputArtifact(let step, _),
            .processFailed(let step, _),
            .missingHandoffArtifact(let step),
            .unableToPersistEvidence(let step):
            step
        case .workspaceNotAttached, .invalidRunID, .emptyTaskPrompt, .roleCountMismatch,
            .worktreeFailure:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .workspaceNotAttached:
            "Open a local workspace before starting a run."
        case .invalidRunID:
            "The generated run identifier is invalid."
        case .emptyTaskPrompt:
            "Enter a task prompt before starting the run."
        case .roleCountMismatch:
            "Every workflow step needs a resolved role."
        case .adapterUnavailable(let step):
            "Step \(step + 1)'s agent adapter is unavailable."
        case .invalidHandoffArtifact(let step):
            "Step \(step + 1)'s handoff artifact must be a safe relative path."
        case .unresolvedInputArtifact(let step, let artifact):
            "Step \(step + 1) requires \"\(artifact)\", which no earlier step produces."
        case .worktreeFailure(let error):
            error.errorDescription
        case .processFailed(let step, let code):
            code.map { "Step \(step + 1)'s agent process exited with status \($0)." }
                ?? "Step \(step + 1)'s agent process exited without a status."
        case .missingHandoffArtifact(let step):
            "Step \(step + 1) exited successfully without creating its handoff artifact."
        case .unableToPersistEvidence(let step):
            "Rafu could not persist step \(step + 1)'s run evidence."
        }
    }
}

/// The result of re-loading and re-parsing `.rafu/workflows`/`.rafu/agents`
/// at plan-gate approval time (D2: files are truth; the human may have
/// hand-edited at the gate). `.failure` NEVER falls back to the stale parked
/// parse — the park is kept and the issue surfaced instead (C8-04).
nonisolated enum ConductorPlanGateReparseOutcome: Sendable {
    case success(workflow: ConductorWorkflowDefinition, roles: [ConductorAgentDefinition])
    case failure(String)
}

/// Composes C1's single-role primitives (`ConductorRunEvidenceService`,
/// `ConductorWorktreeService`, `ConductorMergeGateService`,
/// `ConductorRoleLaunchService`) into a sequential, gated, multi-role
/// pipeline. A PEER of `ConductorRunController`, not a wrapper around it:
/// every manifest write flows through the injected `runsPublisher`'s
/// `publish(_:)` seam, never through a store this controller owns directly.
///
/// One `ConductorWorkspacePlan` covers the whole run — every step executes
/// in `plan.executionRoot`, so mutating steps share one worktree and there is
/// exactly one merge gate at the end, exactly as C1's single-role merge gate
/// already behaves. This is deliberate duplication of C1's merge-gate verbs
/// (`applyToWorkspace`/`keepWorktree`/`discardWorktree`/
/// `refreshMergeGateFiles`/`presentMergeGateDiff`) rather than a shared base
/// class: both call the same underlying services, and unifying the two
/// controllers was explicitly deferred.
@Observable
@MainActor
final class ConductorWorkflowController {
    private(set) var state: ConductorWorkflowState = .idle
    private(set) var manifest: ConductorRunManifest?
    private(set) var mergeGateFiles: [ConductorMergeGateFile] = []
    private(set) var mergeGateError: String?
    private(set) var hasAppliedToWorkspace = false
    private(set) var isResolvingMergeGate = false
    /// Non-nil only while parked `.awaitingPlanGate` AND the last
    /// `approvePlanGate()` attempt's re-parse failed — the exact text is the
    /// re-parse error, never a stale-parse fallback (C8-04).
    private(set) var planGateIssue: String?
    /// Workspace-relative file paths for the plan gate's UI, copied from the
    /// parked request at park time. Empty once the gate clears.
    private(set) var planGateFiles: [String] = []

    var canStartNewRun: Bool {
        !Self.isInFlight(state)
    }

    /// Whether a run is currently mid-flight — the gating condition menu and
    /// palette commands (Stage B) disable "New Run…" with, mirroring
    /// `ConductorRunController`'s equivalent shape.
    var isInFlight: Bool {
        Self.isInFlight(state)
    }

    /// Raised the moment a gate parks the run (a step gate or the terminal
    /// merge gate) — the attention/HUD seam. Carries a typed event so the
    /// notification layer can offer Approve only for a gate the workflow author
    /// explicitly marked remotely approvable; it deliberately carries only
    /// identity and names, never artifact or prompt content (C7).
    @ObservationIgnored
    var onGateReady: ((ConductorGateReadyEvent) -> Void)?

    @ObservationIgnored
    private(set) var store: ConductorRunStore?

    @ObservationIgnored
    private var attachedWorkspaceRoot: URL?

    @ObservationIgnored
    let adapters: [any ConductorCLIAdapter]

    /// Every pipeline manifest write goes through this run's manifest list
    /// and its serialized write queue — see `ConductorRunController.publish`.
    @ObservationIgnored
    let runsPublisher: ConductorRunController

    @ObservationIgnored
    private let evidenceService = ConductorRunEvidenceService()

    @ObservationIgnored
    private let worktreeService = ConductorWorktreeService()

    @ObservationIgnored
    private let mergeGateService = ConductorMergeGateService()

    @ObservationIgnored
    private let roleLaunch = ConductorRoleLaunchService()

    @ObservationIgnored
    private var activeGeneration: UUID?

    @ObservationIgnored
    private(set) var plan: ConductorWorkspacePlan?

    @ObservationIgnored
    private var stepEvidence: [Int: ConductorRunEvidence] = [:]

    @ObservationIgnored
    private var stepSessionIDs: [Int: UUID] = [:]

    @ObservationIgnored
    private var activeSessionID: UUID?

    @ObservationIgnored
    private var activeLauncher: (any ConductorRunProcessLaunching)?

    @ObservationIgnored
    private var operationTask: Task<Void, Never>?

    @ObservationIgnored
    private var request: ConductorWorkflowRunRequest?

    @ObservationIgnored
    private var resolvedAdapters: [ConductorResolvedAdapter] = []

    /// The request a plan gate parked, held SEPARATELY from `request`
    /// (deliberately not assigned there) so `request != nil` keeps meaning
    /// exactly what `retryFailedStep()`/`launchStep()` already assert it
    /// means: "this run has materialized a plan and may launch a step" — a
    /// plan gate has done neither yet.
    @ObservationIgnored
    private var parkedPlanGateRequest: ConductorWorkflowRunRequest?

    /// Re-loads and re-parses the workflow/agent files at plan-gate approval
    /// time. `nil` (every existing call site, and most unit tests) falls back
    /// to the built-in library re-parse in `builtInPlanGateReparse(for:)`;
    /// `ConductorEnsembleRequestService.startRun` installs one that reruns
    /// its single override/artifact-appendix resolver against the SAME
    /// captured payload (advisor A2).
    @ObservationIgnored
    var planGateReparse:
        (@MainActor (ConductorWorkflowRunRequest) async -> ConductorPlanGateReparseOutcome)?

    /// The file-backed library used ONLY by the built-in plan-gate re-parse
    /// path. Defaults to the real on-disk library/user root exactly like
    /// `ConductorEnsembleRequestService.Dependencies` does, so every existing
    /// call site keeps compiling; tests MUST inject both an empty temp user
    /// root and a scoped enable store (advisor R5).
    @ObservationIgnored
    private let definitionLibrary: ConductorDefinitionLibrary

    @ObservationIgnored
    private let userLibraryRoot: () -> URL

    /// Best-effort per-step metering (C7). Injectable so headless tests drive
    /// fixture snapshots instead of the real provider registry.
    @ObservationIgnored
    private let usageMeter: ConductorRunUsageMeter

    /// The reading taken immediately before each step launched, keyed by step
    /// index. Dropped when the step finishes — a missing entry simply means
    /// "no usage to record", never an error.
    @ObservationIgnored
    private var stepUsageStart: [Int: ConductorRunUsageSnapshot] = [:]

    init(
        runsPublisher: ConductorRunController,
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        usageMeter: ConductorRunUsageMeter = ConductorRunUsageMeter(),
        definitionLibrary: ConductorDefinitionLibrary = ConductorDefinitionLibrary(),
        userLibraryRoot: @escaping () -> URL = {
            ConductorDefinitionLibrary.defaultUserLibraryRoot
        }
    ) {
        self.runsPublisher = runsPublisher
        self.adapters = adapters
        self.usageMeter = usageMeter
        self.definitionLibrary = definitionLibrary
        self.userLibraryRoot = userLibraryRoot
    }

    func adapter(for id: ConductorCLIID) -> (any ConductorCLIAdapter)? {
        adapters.first { $0.id == id }
    }

    /// Mirrors `ConductorRunController.attach(workspaceRoot:)`: reading
    /// nothing, aborting (never deleting) any in-flight work before swapping
    /// to the new workspace's store.
    func attach(workspaceRoot: URL?) {
        let root = workspaceRoot?.standardizedFileURL
        guard root != attachedWorkspaceRoot else { return }

        if Self.isInFlight(state) {
            abort()
            guard !Self.isInFlight(state) else { return }
        }

        attachedWorkspaceRoot = root
        store = root.map { ConductorRunStore(workspaceRoot: $0) }
        state = .idle
        manifest = nil
        plan = nil
        request = nil
        parkedPlanGateRequest = nil
        planGateIssue = nil
        planGateFiles = []
        resolvedAdapters = []
        stepEvidence = [:]
        stepSessionIDs = [:]
        mergeGateFiles = []
        mergeGateError = nil
        hasAppliedToWorkspace = false
        isResolvingMergeGate = false
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
    }

    /// Synchronous UI bridge, mirroring `ConductorRunController.begin`.
    func begin(
        _ request: ConductorWorkflowRunRequest,
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

    /// Validates the whole request, resolves every step's adapter up front,
    /// and computes (but does not yet materialize) the one shared worktree
    /// plan. Nothing spawns until every step's provider, handoff artifact,
    /// and input-artifact reference has been checked. Shared verbatim by
    /// `start(_:launcher:)` and `approvePlanGate()` (advisor A2/A3): a
    /// plan-gate approval must run the identical validation a fresh start
    /// would, against whatever the human just hand-edited.
    private func prepare(
        _ request: ConductorWorkflowRunRequest,
        generation: UUID,
        store: ConductorRunStore
    ) async throws -> (
        resolved: [ConductorResolvedAdapter],
        plan: ConductorWorkspacePlan,
        steps: [ConductorRunManifest.Step]
    ) {
        let task = request.taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw ConductorWorkflowError.emptyTaskPrompt }
        guard ConductorRunStore.isValidRunID(request.runID) else {
            throw ConductorWorkflowError.invalidRunID
        }
        guard request.roles.count == request.workflow.steps.count else {
            throw ConductorWorkflowError.roleCountMismatch
        }

        var stepAdapters: [any ConductorCLIAdapter] = []
        stepAdapters.reserveCapacity(request.roles.count)
        for (index, role) in request.roles.enumerated() {
            guard let stepAdapter = adapter(for: role.provider) else {
                throw ConductorWorkflowError.adapterUnavailable(step: index)
            }
            guard Self.isSafeRelativePath(role.handoffArtifact) else {
                throw ConductorWorkflowError.invalidHandoffArtifact(step: index)
            }
            stepAdapters.append(stepAdapter)
        }
        for (index, workflowStep) in request.workflow.steps.enumerated() {
            for artifact in workflowStep.inputArtifacts {
                guard
                    request.roles[..<index].contains(where: {
                        $0.handoffArtifact == artifact
                    })
                else {
                    throw ConductorWorkflowError.unresolvedInputArtifact(
                        step: index, artifact: artifact)
                }
            }
        }

        try Task.checkCancellation()
        _ = try await store.directory.seed()
        try Self.requireCurrent(generation, activeGeneration)

        let anyWorktreeWrite = request.roles.contains { $0.autonomy == .worktreeWrite }
        let workspacePlan: ConductorWorkspacePlan
        do {
            workspacePlan = try await worktreeService.plan(
                workspaceRoot: store.directory.workspaceRoot,
                runID: request.runID,
                autonomy: anyWorktreeWrite ? .worktreeWrite : .readOnly,
                baseReference: request.baseReference)
        } catch let error as ConductorWorktreeError {
            throw ConductorWorkflowError.worktreeFailure(error)
        }
        try Self.requireCurrent(generation, activeGeneration)

        var resolved: [ConductorResolvedAdapter] = []
        resolved.reserveCapacity(stepAdapters.count)
        for (index, stepAdapter) in stepAdapters.enumerated() {
            do {
                resolved.append(try await roleLaunch.resolve(stepAdapter))
            } catch {
                throw ConductorWorkflowError.adapterUnavailable(step: index)
            }
            try Self.requireCurrent(generation, activeGeneration)
        }

        let steps = request.roles.enumerated().map { index, role in
            ConductorRunManifest.Step(
                agentName: role.name,
                binding: ConductorRoleLaunchService.binding(
                    role: role, resolved: resolved[index]),
                inputArtifacts: request.workflow.steps[index].inputArtifacts,
                handoffArtifact: role.handoffArtifact,
                gateAfter: request.workflow.steps[index].gateAfter,
                status: .pending,
                startedAt: nil,
                finishedAt: nil,
                attempt: 1,
                evidencePath: nil,
                // Snapshotted now, so editing the workflow file mid-run
                // cannot make an already-open gate remotely approvable.
                safeToApproveRemotely: request.workflow.steps[index].safeToApproveRemotely)
        }

        return (resolved, workspacePlan, steps)
    }

    /// Validates the whole request (`prepare`), publishes manifest v0 with
    /// every step `.pending`, then either parks at the human plan gate
    /// (`request.planGateRequested`) or materializes the one shared worktree
    /// plan and launches step 0.
    func start(
        _ request: ConductorWorkflowRunRequest,
        launcher: any ConductorRunProcessLaunching
    ) async {
        guard !Self.isInFlight(state) else { return }

        let generation = UUID()
        activeGeneration = generation
        activeLauncher = launcher
        activeSessionID = nil
        stepSessionIDs = [:]
        stepEvidence = [:]
        manifest = nil
        plan = nil
        self.request = nil
        parkedPlanGateRequest = nil
        planGateIssue = nil
        planGateFiles = []
        resolvedAdapters = []
        mergeGateFiles = []
        mergeGateError = nil
        hasAppliedToWorkspace = false
        isResolvingMergeGate = false
        state = .preparing

        do {
            guard let store else { throw ConductorWorkflowError.workspaceNotAttached }
            let prepared = try await prepare(request, generation: generation, store: store)
            resolvedAdapters = prepared.resolved
            plan = prepared.plan

            let now = Date()
            let newManifest = ConductorRunManifest(
                id: request.runID,
                workflowName: request.workflow.name,
                baseCommit: prepared.plan.baseCommit,
                worktreeBranch: prepared.plan.branchName ?? "",
                createdAt: now,
                updatedAt: now,
                steps: prepared.steps,
                startedBy: request.startedBy,
                label: request.label,
                gate: request.planGateRequested
                    ? ConductorRunManifest.Gate(kind: .plan, stepIndex: 0) : nil)
            manifest = newManifest
            runsPublisher.publish(newManifest)
            try Self.requireCurrent(generation, activeGeneration)

            if request.planGateRequested {
                // No AGENT spawns behind a plan gate (advisor A1): `prepare`
                // above ran read-only git queries and each step's
                // adapter-version probe, but no worktree, no agent process,
                // and no evidence directory exists yet. Park and return
                // BEFORE materialize/launch.
                planGateFiles = request.planGateFiles
                parkedPlanGateRequest = request
                state = .awaitingPlanGate
                onGateReady?(
                    ConductorGateReadyEvent(
                        runID: newManifest.id,
                        kind: .plan,
                        stepIndex: 0,
                        workflowName: newManifest.workflowName,
                        agentName: newManifest.steps.first?.agentName ?? "",
                        // A plan gate is never remotely approvable, exactly
                        // like the terminal merge gate.
                        safeToApproveRemotely: false))
                return
            }

            do {
                try await worktreeService.materialize(prepared.plan)
            } catch let error as ConductorWorktreeError {
                throw ConductorWorkflowError.worktreeFailure(error)
            }
            try Self.requireCurrent(generation, activeGeneration)

            self.request = request
            await launchStep(0)
        } catch is CancellationError {
            guard activeGeneration == generation else { return }
            markAborted()
        } catch let error as ConductorWorkflowError {
            guard activeGeneration == generation else { return }
            recordFailure(
                step: error.stepIndex ?? 0, reason: error.errorDescription ?? "The run failed.")
        } catch {
            guard activeGeneration == generation else { return }
            recordFailure(step: 0, reason: "Rafu could not persist the run evidence.")
        }
    }

    /// Prepares this step's evidence (a fresh attempt directory), resolves
    /// its declared input artifacts from producing steps' CURRENT evidence
    /// (read at launch time — the mechanism that lets a revised artifact
    /// flow forward), and launches it.
    private func launchStep(_ index: Int) async {
        // A missing generation means there is no active run to attribute
        // anything to at all (already aborted, already attached to a
        // different workspace, or never started) — a silent return is
        // correct here, not a bug.
        guard let generation = activeGeneration else { return }
        // Everything else being nil WHILE a generation is active is an
        // internal invariant violation, not a quiet no-op (advisor D2): a
        // materialize failure leaves `request` unset until AFTER it
        // succeeds, so a caller that reaches `launchStep` before that
        // (or after some other unexpected reset) must surface a failure —
        // silently returning left `retryFailedStep()` publishing `.pending`
        // and launching nothing, repeatably, with nothing telling the user.
        guard let request, let plan, let launcher = activeLauncher,
            var currentManifest = manifest, currentManifest.steps.indices.contains(index)
        else {
            recordFailure(
                step: index,
                reason: "Rafu could not launch step \(index + 1): the run's context is unavailable."
            )
            return
        }
        let role = request.roles[index]
        let workflowStep = request.workflow.steps[index]
        let attempt = currentManifest.steps[index].attempt ?? 1

        do {
            var inputs: [(name: String, url: URL)] = []
            for artifactName in workflowStep.inputArtifacts {
                guard
                    let producingIndex = request.roles[..<index].lastIndex(where: {
                        $0.handoffArtifact == artifactName
                    }),
                    let producingEvidence = stepEvidence[producingIndex]
                else {
                    throw ConductorWorkflowError.unresolvedInputArtifact(
                        step: index, artifact: artifactName)
                }
                inputs.append((name: artifactName, url: producingEvidence.artifactURL))
            }
            let prompt = ConductorPromptComposer.step(
                role: role, taskPrompt: request.taskPrompt, inputs: inputs)

            guard let store else { throw ConductorWorkflowError.workspaceNotAttached }
            let layout = ConductorRunEvidenceLayout.step(
                index: index, agentName: role.name, attempt: attempt)
            let evidence: ConductorRunEvidence
            do {
                evidence = try await evidenceService.prepare(
                    directory: store.directory,
                    runID: request.runID,
                    layout: layout,
                    handoffArtifact: role.handoffArtifact,
                    prompt: prompt)
            } catch let error as ConductorRunError where error == .unableToPersistEvidence {
                throw ConductorWorkflowError.unableToPersistEvidence(step: index)
            }
            try Self.requireCurrent(generation, activeGeneration)
            stepEvidence[index] = evidence

            let specification = roleLaunch.specification(
                role: role,
                prompt: prompt,
                evidence: evidence,
                plan: plan,
                resolved: resolvedAdapters[index],
                roleBadge: role.name)

            // Metered immediately before launch so the delta brackets only
            // this step's child. A provider that cannot be read yields no
            // baseline, and the step simply records no usage (C7 honesty).
            stepUsageStart[index] = await usageMeter.snapshot(at: Date())
            try Self.requireCurrent(generation, activeGeneration)

            currentManifest.steps[index].status = .running
            currentManifest.steps[index].startedAt = Date()
            currentManifest.steps[index].finishedAt = nil
            currentManifest.steps[index].attempt = attempt
            currentManifest.steps[index].evidencePath = layout.stepComponents.joined(
                separator: "/")
            currentManifest.steps[index].usage = nil
            currentManifest.updatedAt = Date()
            manifest = currentManifest
            runsPublisher.publish(currentManifest)
            try Self.requireCurrent(generation, activeGeneration)

            state = .runningStep(index: index)
            let sessionID = try launcher.launch(
                specification: specification
            ) { [weak self] sessionID, exitCode in
                self?.processDidExit(sessionID: sessionID, exitCode: exitCode)
            }
            activeSessionID = sessionID
            stepSessionIDs[index] = sessionID
        } catch is CancellationError {
            guard activeGeneration == generation else { return }
            markAborted()
        } catch let error as ConductorWorkflowError {
            guard activeGeneration == generation else { return }
            recordFailure(step: index, reason: error.errorDescription ?? "The run failed.")
        } catch let error as ConductorRunError {
            guard activeGeneration == generation else { return }
            recordFailure(step: index, reason: error.errorDescription ?? "The run failed.")
        } catch {
            guard activeGeneration == generation else { return }
            recordFailure(step: index, reason: "Rafu could not launch step \(index + 1).")
        }
    }

    /// Natural terminal exit. A stale session id (a previous step's, or one
    /// from a prior generation) is rejected exactly like C1's controller.
    func processDidExit(sessionID: UUID, exitCode: Int32?) {
        guard activeSessionID == sessionID, case .runningStep(let index) = state else { return }
        activeSessionID = nil

        guard let evidence = stepEvidence[index], let generation = activeGeneration else {
            recordFailure(
                step: index,
                reason: "Rafu could not locate step \(index + 1)'s run evidence.")
            return
        }

        state = .awaitingArtifact(index: index)
        operationTask?.cancel()
        operationTask = Task { [weak self, evidenceService] in
            let exists = await evidenceService.artifactExists(at: evidence.artifactURL)
            try? Task.checkCancellation()
            guard let self, self.activeGeneration == generation else { return }
            // Recorded for EVERY terminal outcome, success or failure: a step
            // that failed still consumed quota, and hiding that would be the
            // dishonest reading C7 exists to avoid.
            await self.recordStepUsage(index)
            guard self.activeGeneration == generation else { return }
            switch ConductorStepOutcome.of(exitCode: exitCode, artifactExists: exists) {
            case .completed:
                await self.stepDidComplete(index)
            case .processFailed(let code):
                self.recordFailure(
                    step: index,
                    reason: ConductorWorkflowError.processFailed(step: index, exitCode: code)
                        .errorDescription ?? "The run failed.")
            case .missingArtifact:
                self.recordFailure(
                    step: index,
                    reason: ConductorWorkflowError.missingHandoffArtifact(step: index)
                        .errorDescription ?? "The run failed.")
            }
            self.operationTask = nil
        }
    }

    // MARK: - Recovery (C7)

    /// Adopts a persisted run the relaunch janitor marked `.interrupted`, so
    /// its verbs become reachable in this app process. Starts NOTHING and
    /// resurrects no process (ADR 0004/0014) — it only re-establishes enough
    /// context for Retry Step / Abort / Keep Worktree.
    ///
    /// The workspace plan is rebuilt from the manifest itself (base commit,
    /// worktree branch, and the run-id-derived worktree path), so a caller
    /// needs nothing a relaunched app does not already have on disk.
    ///
    /// Returns `false` when there is nothing to adopt — this controller is
    /// already busy, or no step is interrupted — so the caller leaves the run
    /// as read-only history rather than showing dead verbs.
    @discardableResult
    func restoreInterrupted(
        manifest restored: ConductorRunManifest,
        workspaceRoot: URL,
        launcher: any ConductorRunProcessLaunching
    ) -> Bool {
        guard !isInFlight else { return false }
        guard restored.steps.contains(where: { $0.status == .interrupted }) else { return false }

        attach(workspaceRoot: workspaceRoot)
        let root = workspaceRoot.standardizedFileURL
        let worktreeURL: URL? =
            restored.worktreeBranch.isEmpty
            ? nil
            : ConductorRunRecoveryService.worktreeURL(workspaceRoot: root, runID: restored.id)
        manifest = restored
        plan = ConductorWorkspacePlan(
            repositoryRoot: root,
            executionRoot: worktreeURL ?? root,
            baseCommit: restored.baseCommit,
            branchName: restored.worktreeBranch.isEmpty ? nil : restored.worktreeBranch,
            worktreeURL: worktreeURL)
        activeLauncher = launcher
        activeGeneration = UUID()
        stepEvidence = [:]
        stepSessionIDs = [:]
        activeSessionID = nil
        state = .idle
        return true
    }

    /// Relaunches an interrupted step from the evidence the previous app
    /// process already wrote: its persisted `prompt.md` is reused verbatim
    /// (never recomposed, never an adapter-native `--resume`), the saved
    /// provider binding is re-probed, and a FRESH attempt directory receives
    /// the new evidence so the interrupted attempt stays intact.
    func retryInterruptedStep(_ index: Int) async {
        guard !isInFlight, let currentManifest = manifest, let plan,
            currentManifest.steps.indices.contains(index),
            currentManifest.steps[index].status == .interrupted,
            let store, let launcher = activeLauncher
        else { return }

        let step = currentManifest.steps[index]
        let generation = UUID()
        activeGeneration = generation
        state = .preparing

        do {
            // The prompt the interrupted attempt actually used. Without it
            // there is nothing honest to relaunch, so this fails loudly rather
            // than inventing a prompt.
            guard let priorEvidencePath = step.evidencePath else {
                throw ConductorWorkflowError.unableToPersistEvidence(step: index)
            }
            let priorPromptURL = store.directory
                .runDirectoryURL(for: currentManifest.id)
                .appending(path: priorEvidencePath, directoryHint: .isDirectory)
                .appending(path: "prompt.md", directoryHint: .notDirectory)
            let prompt = try await Self.readPersistedPrompt(at: priorPromptURL)
            try Self.requireCurrent(generation, activeGeneration)

            guard let adapter = adapter(for: step.binding.provider) else {
                throw ConductorWorkflowError.adapterUnavailable(step: index)
            }
            let resolved = try await roleLaunch.resolve(adapter)
            try Self.requireCurrent(generation, activeGeneration)

            let attempt = (step.attempt ?? 1) + 1
            let layout = ConductorRunEvidenceLayout.step(
                index: index, agentName: step.agentName, attempt: attempt)
            let evidence = try await evidenceService.prepare(
                directory: store.directory,
                runID: currentManifest.id,
                layout: layout,
                handoffArtifact: step.handoffArtifact,
                prompt: prompt)
            try Self.requireCurrent(generation, activeGeneration)
            stepEvidence[index] = evidence

            let role = ConductorAgentDefinition(
                name: step.agentName,
                provider: step.binding.provider,
                model: step.binding.model,
                autonomy: step.binding.autonomy,
                handoffArtifact: step.handoffArtifact,
                promptBody: "")
            let specification = roleLaunch.specification(
                role: role,
                prompt: prompt,
                evidence: evidence,
                plan: plan,
                resolved: resolved,
                roleBadge: step.agentName)

            stepUsageStart[index] = await usageMeter.snapshot(at: Date())
            try Self.requireCurrent(generation, activeGeneration)

            var updated = currentManifest
            updated.steps[index].status = .running
            updated.steps[index].startedAt = Date()
            updated.steps[index].finishedAt = nil
            updated.steps[index].attempt = attempt
            updated.steps[index].evidencePath = layout.stepComponents.joined(separator: "/")
            updated.steps[index].usage = nil
            updated.recoveryNote = nil
            updated.updatedAt = Date()
            manifest = updated
            runsPublisher.publish(updated)

            state = .runningStep(index: index)
            let sessionID = try launcher.launch(specification: specification) {
                [weak self] sessionID, exitCode in
                self?.processDidExit(sessionID: sessionID, exitCode: exitCode)
            }
            activeSessionID = sessionID
            stepSessionIDs[index] = sessionID
        } catch is CancellationError {
            guard activeGeneration == generation else { return }
            markAborted()
        } catch {
            guard activeGeneration == generation else { return }
            recordFailure(
                step: index,
                reason: (error as? LocalizedError)?.errorDescription
                    ?? "Rafu could not retry step \(index + 1).")
        }
    }

    /// Marks an adopted interrupted run aborted. Touches no evidence and no
    /// worktree — the user's work is never deleted by a state change.
    func abortInterruptedRun() {
        guard var currentManifest = manifest, !isInFlight else { return }
        for index in currentManifest.steps.indices
        where currentManifest.steps[index].status == .interrupted {
            currentManifest.steps[index].status = .aborted
            currentManifest.steps[index].finishedAt = Date()
        }
        currentManifest.gate = nil
        currentManifest.recoveryNote = nil
        currentManifest.updatedAt = Date()
        manifest = currentManifest
        runsPublisher.publish(currentManifest)
        state = .aborted
    }

    /// Leaves the attributed branch and worktree in place for manual handling
    /// and closes the run out. Nothing is removed.
    func keepInterruptedWorktree() {
        guard var currentManifest = manifest, !isInFlight else { return }
        for index in currentManifest.steps.indices
        where currentManifest.steps[index].status == .interrupted {
            currentManifest.steps[index].status = .aborted
            currentManifest.steps[index].finishedAt = Date()
        }
        currentManifest.gate = nil
        currentManifest.recoveryNote =
            "The run worktree was kept for manual handling."
        currentManifest.updatedAt = Date()
        manifest = currentManifest
        runsPublisher.publish(currentManifest)
        state = .completed
    }

    /// Reads a persisted prompt off the main actor, bounded so a corrupted or
    /// enormous evidence file cannot be pulled wholesale into memory.
    @concurrent
    private static func readPersistedPrompt(at url: URL) async throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= 1_048_576,
            let text = String(data: data, encoding: .utf8)
        else {
            throw ConductorWorkflowError.emptyTaskPrompt
        }
        return text
    }

    /// Reads a step's completed handoff artifact (bounded 1 MiB, same cap as
    /// `readPersistedPrompt`) and extracts its `proposes:` frontmatter list,
    /// if any (`ConductorStepProposalsParser`). NEVER throws: a malformed,
    /// oversize, binary, or unreadable artifact still completes the step —
    /// proposals are advisory only (C8-04).
    @concurrent
    private static func readProposals(at url: URL) async -> [String]? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            !data.isEmpty, data.count <= 1_048_576,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return ConductorStepProposalsParser.parse(text)
    }

    /// Resolves and persists this step's usage delta, if metering produced an
    /// honest one. Writes nothing when there is no baseline, no resolvable
    /// delta, or the step vanished from the manifest — never a zero.
    private func recordStepUsage(_ index: Int) async {
        guard let start = stepUsageStart.removeValue(forKey: index) else { return }
        guard let steps = manifest?.steps, steps.indices.contains(index) else { return }
        let attempt = steps[index].attempt ?? 1
        guard let record = await usageMeter.finish(from: start, attempt: attempt, at: Date())
        else { return }
        guard var currentManifest = manifest, currentManifest.steps.indices.contains(index)
        else { return }
        currentManifest.steps[index].usage = record
        currentManifest.updatedAt = Date()
        manifest = currentManifest
        runsPublisher.publish(currentManifest)
    }

    /// Marks the step complete; parks at a step gate when the workflow file
    /// declares one, otherwise advances immediately.
    private func stepDidComplete(_ index: Int) async {
        guard var currentManifest = manifest, currentManifest.steps.indices.contains(index)
        else { return }
        let generation = activeGeneration
        let gateAfter = currentManifest.steps[index].gateAfter
        currentManifest.steps[index].finishedAt = Date()
        currentManifest.steps[index].status = gateAfter ? .awaitingGate : .completed
        currentManifest.updatedAt = Date()
        if gateAfter {
            currentManifest.gate = ConductorRunManifest.Gate(kind: .step, stepIndex: index)
        }
        if let artifactURL = stepEvidence[index]?.artifactURL {
            let proposals = await Self.readProposals(at: artifactURL)
            // Re-checked after the off-main read: an abort/reset arriving
            // during it must not resurrect a manifest write for a run that
            // is no longer this generation's (same discipline as every other
            // `requireCurrent` gap in this controller).
            guard activeGeneration == generation else { return }
            currentManifest.steps[index].proposals = proposals
        }
        manifest = currentManifest
        runsPublisher.publish(currentManifest)

        if gateAfter {
            state = .awaitingGate(index: index)
            onGateReady?(
                ConductorGateReadyEvent(
                    runID: currentManifest.id,
                    kind: .step,
                    stepIndex: index,
                    workflowName: currentManifest.workflowName,
                    agentName: currentManifest.steps[index].agentName,
                    safeToApproveRemotely: currentManifest.steps[index].safeToApproveRemotely
                        ?? false))
        } else {
            await advance(after: index)
        }
    }

    /// Launches the next step, or — when the pipeline is out of steps —
    /// opens the one terminal merge gate for a `worktreeWrite` run, or
    /// completes a fully `readOnly` run outright.
    private func advance(after index: Int) async {
        guard let request else { return }
        let nextIndex = index + 1
        if request.workflow.steps.indices.contains(nextIndex) {
            await launchStep(nextIndex)
            return
        }
        guard var currentManifest = manifest else { return }
        if let plan, plan.worktreeURL != nil {
            currentManifest.gate = ConductorRunManifest.Gate(kind: .merge, stepIndex: index)
            currentManifest.updatedAt = Date()
            manifest = currentManifest
            runsPublisher.publish(currentManifest)
            state = .awaitingMergeGate
            // A merge gate applies a diff to the user's workspace, so it is
            // NEVER remotely approvable regardless of any step marker.
            onGateReady?(
                ConductorGateReadyEvent(
                    runID: currentManifest.id,
                    kind: .merge,
                    stepIndex: index,
                    workflowName: currentManifest.workflowName,
                    agentName: currentManifest.steps[index].agentName,
                    safeToApproveRemotely: false))
            await refreshMergeGateFiles()
        } else {
            currentManifest.gate = nil
            currentManifest.updatedAt = Date()
            manifest = currentManifest
            runsPublisher.publish(currentManifest)
            state = .completed
        }
    }

    /// Approves the run currently parked at the plan gate. Re-loads and
    /// re-parses the workflow/agent files at THIS moment (`planGateReparse`
    /// when installed, otherwise `builtInPlanGateReparse(for:)`) — D2: files
    /// are truth, and the human may have hand-edited them at the gate — then
    /// rebuilds the manifest from the FRESH roles (advisor A3: a hand-edit
    /// may add a step or flip a role's autonomy, changing the whole
    /// `ConductorWorkspacePlan`) before materializing and launching step 0.
    /// A re-parse failure NEVER falls back to the stale parked parse: it
    /// keeps the park and surfaces `planGateIssue`.
    ///
    /// The state change AND a fresh `activeGeneration` happen SYNCHRONOUSLY,
    /// before the first `await` — the same reentrancy rule `approveGate()`
    /// documents below, so a second Approve arriving mid-reparse cannot pass
    /// this guard and launch a second child.
    func approvePlanGate() async {
        guard case .awaitingPlanGate = state, let parkedRequest = parkedPlanGateRequest else {
            return
        }
        let generation = UUID()
        activeGeneration = generation
        state = .preparing
        planGateIssue = nil

        let outcome: ConductorPlanGateReparseOutcome =
            if let planGateReparse {
                await planGateReparse(parkedRequest)
            } else {
                await builtInPlanGateReparse(for: parkedRequest)
            }
        guard activeGeneration == generation else { return }

        let resolvedWorkflow: ConductorWorkflowDefinition
        let resolvedRoles: [ConductorAgentDefinition]
        switch outcome {
        case .success(let workflow, let roles):
            resolvedWorkflow = workflow
            resolvedRoles = roles
        case .failure(let issue):
            state = .awaitingPlanGate
            planGateIssue = issue
            return
        }

        let refreshedRequest = ConductorWorkflowRunRequest(
            workflow: resolvedWorkflow,
            roles: resolvedRoles,
            taskPrompt: parkedRequest.taskPrompt,
            baseReference: parkedRequest.baseReference,
            runID: parkedRequest.runID,
            startedBy: parkedRequest.startedBy,
            label: parkedRequest.label,
            planGateRequested: false,
            planGateFiles: parkedRequest.planGateFiles)

        do {
            guard let store else { throw ConductorWorkflowError.workspaceNotAttached }
            let prepared = try await prepare(refreshedRequest, generation: generation, store: store)
            try Self.requireCurrent(generation, activeGeneration)
            resolvedAdapters = prepared.resolved
            plan = prepared.plan

            guard let currentManifest = manifest else {
                throw ConductorWorkflowError.workspaceNotAttached
            }
            // A3: REBUILD the manifest value — `workflowName`/`baseCommit`/
            // `worktreeBranch` are `let`, and a hand-edit may have changed
            // any of them (a new step, a flipped autonomy, a different base).
            // Same `id`/`createdAt`/`startedBy`/`label` ⇒ same run file, one
            // write.
            let rebuiltManifest = ConductorRunManifest(
                id: currentManifest.id,
                workflowName: resolvedWorkflow.name,
                baseCommit: prepared.plan.baseCommit,
                worktreeBranch: prepared.plan.branchName ?? "",
                createdAt: currentManifest.createdAt,
                updatedAt: Date(),
                steps: prepared.steps,
                startedBy: currentManifest.startedBy,
                label: currentManifest.label)
            manifest = rebuiltManifest
            runsPublisher.publish(rebuiltManifest)
            try Self.requireCurrent(generation, activeGeneration)

            do {
                try await worktreeService.materialize(prepared.plan)
            } catch let error as ConductorWorktreeError {
                throw ConductorWorkflowError.worktreeFailure(error)
            }
            try Self.requireCurrent(generation, activeGeneration)

            parkedPlanGateRequest = nil
            planGateFiles = []
            self.request = refreshedRequest
            await launchStep(0)
        } catch is CancellationError {
            guard activeGeneration == generation else { return }
            markAborted()
        } catch let error as ConductorWorkflowError {
            guard activeGeneration == generation else { return }
            recordFailure(
                step: error.stepIndex ?? 0, reason: error.errorDescription ?? "The run failed.")
        } catch {
            guard activeGeneration == generation else { return }
            recordFailure(step: 0, reason: "Rafu could not persist the run evidence.")
        }
    }

    /// The built-in plan-gate re-parse used when no `planGateReparse` closure
    /// is installed (every existing call site: UI-started runs, unit tests).
    /// Re-locates the workflow by NAME — mirroring
    /// `ConductorEnsembleRequestService.startRun`'s own stem-or-name lookup —
    /// and rebuilds roles via `ConductorWorkflowBinder`. It does not reapply
    /// `--role`/`--artifact` semantics: this path has no originating payload
    /// to read those from (that is exactly why the Ensemble request service
    /// installs its own closure — advisor A2).
    private func builtInPlanGateReparse(
        for request: ConductorWorkflowRunRequest
    ) async -> ConductorPlanGateReparseOutcome {
        guard let store else {
            return .failure("Open a local workspace before approving a plan gate.")
        }
        let snapshot: ConductorDefinitionLibrarySnapshot
        do {
            snapshot = try await definitionLibrary.load(
                workspaceRoot: store.directory.workspaceRoot,
                userLibraryRoot: userLibraryRoot())
        } catch is CancellationError {
            return .failure("Ensemble run preparation was cancelled.")
        } catch {
            return .failure("Ensemble definitions could not be re-read.")
        }
        guard
            let libraryWorkflow = snapshot.workflows.first(where: {
                $0.stem == request.workflow.name || $0.definition?.name == request.workflow.name
            }),
            libraryWorkflow.isLaunchable,
            let workflow = libraryWorkflow.definition
        else {
            return .failure("The workflow file could not be re-read, or is now invalid.")
        }
        do {
            let roles = try ConductorWorkflowBinder.resolve(
                workflow: workflow,
                agents: snapshot.agents.filter(\.isLaunchable).compactMap(\.agentFile))
            return .success(workflow: workflow, roles: roles)
        } catch {
            return .failure(
                "A workflow step's agent file could not be re-read, or is now invalid.")
        }
    }

    /// "Request Changes" from the plan gate: nothing ever launched, so
    /// declining leaves every step `.pending` and simply records why. The
    /// coordinator reads the note via `status`/events and — per the design
    /// contract — submits a NEW `run --plan-gate` after revising files.
    func declinePlanGate(note: String) {
        guard case .awaitingPlanGate = state, var currentManifest = manifest else { return }
        // Every step is marked `.aborted`, not left `.pending`: a declined
        // plan gate means none of them will ever run, and
        // `ConductorEnsembleStateProjection.runState` can ONLY derive
        // `.aborted` for a manifest-only event from a step actually carrying
        // that status — `runChanged(manifest:)` has no live-state parameter
        // to fall back on. Leaving every step `.pending` (as `markAborted`
        // does for an in-progress step's SIBLINGS) would make this decline
        // invisible to `status`/events and project as `.pending` forever,
        // breaking the exact round-trip the coordinator depends on.
        for index in currentManifest.steps.indices {
            currentManifest.steps[index].status = .aborted
            currentManifest.steps[index].finishedAt = Date()
        }
        currentManifest.gate = nil
        currentManifest.recoveryNote = String(note.prefix(1_000))
        currentManifest.updatedAt = Date()
        manifest = currentManifest
        runsPublisher.publish(currentManifest)
        state = .aborted
        parkedPlanGateRequest = nil
        planGateFiles = []
        planGateIssue = nil
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
    }

    /// Approves the step gate the run is currently parked at: marks the step
    /// complete, clears the gate, and advances.
    ///
    /// Both the state change AND a fresh `activeGeneration` happen
    /// SYNCHRONOUSLY, before the first `await` (`advance`/`launchStep`'s
    /// first suspension is `evidenceService.prepare`, off-main) — otherwise
    /// a second `approveGate()` arriving while the first is still suspended
    /// there would pass both this guard (`state` was still `.awaitingGate`)
    /// and `launchStep`'s `requireCurrent` (no generation had changed),
    /// spawning two children into the same worktree (advisor D1, mirroring
    /// the same protection `retryFailedStep()` already has). `.preparing` is
    /// a real, existing FSM value — reused here rather than inventing a
    /// bespoke transitional case — and is already `isInFlight`, so the menu
    /// and command-palette predicates (which key on `state`) also go false
    /// immediately.
    func approveGate() async {
        // The single user-facing "Approve" verb also covers the plan gate:
        // a plan gate parks the whole run, not one step, so it forwards
        // rather than duplicating a second entry point.
        if case .awaitingPlanGate = state {
            await approvePlanGate()
            return
        }
        guard case .awaitingGate(let index) = state, var currentManifest = manifest,
            currentManifest.steps.indices.contains(index)
        else { return }
        currentManifest.steps[index].status = .completed
        currentManifest.gate = nil
        currentManifest.updatedAt = Date()
        manifest = currentManifest
        runsPublisher.publish(currentManifest)
        activeGeneration = UUID()
        state = .preparing
        await advance(after: index)
    }

    /// Opens the parked step's handoff artifact as a normal editor tab so
    /// the user can revise it before approving. No state change: the file on
    /// disk is what the next step reads at ITS launch time, so an edit here
    /// simply changes what that later read sees.
    func reviseArtifact(in session: WorkspaceSession) {
        guard case .awaitingGate(let index) = state, let evidence = stepEvidence[index],
            let store
        else { return }
        let relative = Self.relativePath(
            of: evidence.artifactURL, from: store.directory.workspaceRoot)
        session.openFile(atRelativePath: relative)
    }

    /// Reveals the live terminal for `stepIndex`, mirroring
    /// `ConductorRunController.revealLiveTerminal(for:in:)` — a no-op unless
    /// this step is the run's CURRENTLY active one and a session is recorded
    /// for it (encapsulates `stepSessionIDs`, which stays private).
    func revealLiveTerminal(stepIndex: Int, in workspaceSession: WorkspaceSession) {
        guard Self.activeStepIndex(in: state) == stepIndex,
            let sessionID = stepSessionIDs[stepIndex]
        else { return }
        workspaceSession.revealTerminalSession(sessionID)
    }

    /// Stops the live child (if any) and parks the run. Evidence and the
    /// worktree are never touched — a later step stays `.pending`.
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

    /// Alias for `abort()` used while parked at a gate — same behavior,
    /// named for the gate-verb call site.
    func abortGate() {
        abort()
    }

    /// Retries the step this run is currently `.failed` at: a new attempt
    /// number, a fresh (never-mixed) evidence directory, input artifacts
    /// re-read from their producing steps' current evidence, and only that
    /// step relaunched. The prior attempt's evidence is never mutated.
    func retryFailedStep() async {
        guard case .failed(let index, _) = state, let currentManifest = manifest,
            currentManifest.steps.indices.contains(index)
        else { return }
        // Validate the run's context BEFORE mutating or publishing anything
        // (advisor D2): `request` is only assigned in `start()` AFTER
        // `materialize` succeeds, so a materialize failure leaves it `nil`
        // while `state` is still `.failed`. Mutating the manifest to
        // `.pending` first and only THEN discovering `launchStep` cannot
        // proceed left the run silently stuck: a surfaced-looking `.failed`
        // manifest that actually read `.pending`, with nothing launched and
        // nothing telling the user why.
        guard request != nil, plan != nil, activeLauncher != nil else {
            recordFailure(
                step: index,
                reason:
                    "Rafu could not retry step \(index + 1): the run's context is unavailable.")
            return
        }
        var updatedManifest = currentManifest
        let nextAttempt = (updatedManifest.steps[index].attempt ?? 1) + 1
        updatedManifest.steps[index].attempt = nextAttempt
        updatedManifest.steps[index].status = .pending
        updatedManifest.steps[index].startedAt = nil
        updatedManifest.steps[index].finishedAt = nil
        updatedManifest.steps[index].evidencePath = nil
        updatedManifest.updatedAt = Date()
        manifest = updatedManifest
        runsPublisher.publish(updatedManifest)
        stepEvidence.removeValue(forKey: index)
        activeGeneration = UUID()
        await launchStep(index)
    }

    /// Leaves the attributed branch/worktree untouched for manual handling.
    func keepWorktree() async {
        guard state == .awaitingMergeGate, !isResolvingMergeGate else { return }
        isResolvingMergeGate = true
        defer { isResolvingMergeGate = false }
        await completeMergeGate()
    }

    /// Applies the Git-derived run patch to an unchanged workspace and
    /// removes the worktree through the non-force cleanup path — identical
    /// contract to `ConductorRunController.applyToWorkspace()`.
    func applyToWorkspace() async {
        guard state == .awaitingMergeGate, !isResolvingMergeGate, !hasAppliedToWorkspace,
            let plan
        else { return }
        isResolvingMergeGate = true
        defer { isResolvingMergeGate = false }
        mergeGateError = nil
        do {
            _ = try await mergeGateService.apply(plan)
            hasAppliedToWorkspace = true
            // Stamped BEFORE `completeMergeGate()` reads `self.manifest`, so
            // the ONE publish it performs already carries `mergedAt` — the
            // event center derives `kind: "merged"` / `state: .merged` from
            // exactly this field, which is what completes a coordinator's
            // `await --state merged`.
            manifest?.mergedAt = Date()
            await completeMergeGate()
        } catch is CancellationError {
            return
        } catch let error as ConductorMergeGateError {
            if error == .appliedButCleanupFailed {
                // The merge-back already happened; only the cosmetic
                // worktree cleanup failed. Stamping (and completing) here
                // too is deliberate (advisor A5) — NOT stamping would hang a
                // coordinator's `await --state merged` forever on that.
                hasAppliedToWorkspace = true
                manifest?.mergedAt = Date()
                await completeMergeGate()
            }
            mergeGateError = error.errorDescription
        } catch {
            mergeGateError = ConductorMergeGateError.applyRejected.errorDescription
        }
    }

    /// Discard is two-step when Git reports changes, identical to C1's.
    @discardableResult
    func discardWorktree(
        confirmedDirty: Bool
    ) async -> ConductorWorktreeDiscardResult? {
        guard state == .awaitingMergeGate, !isResolvingMergeGate, let plan else { return nil }
        isResolvingMergeGate = true
        defer { isResolvingMergeGate = false }
        mergeGateError = nil
        do {
            let result = try await worktreeService.discard(plan, confirmedDirty: confirmedDirty)
            if result == .removed {
                await completeMergeGate()
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
        guard state == .awaitingMergeGate, let plan, let generation = activeGeneration else {
            return
        }
        do {
            let files = try await mergeGateService.files(for: plan)
            guard state == .awaitingMergeGate, activeGeneration == generation, self.plan == plan
            else { return }
            mergeGateFiles = files
            mergeGateError = nil
        } catch is CancellationError {
            return
        } catch let error as ConductorMergeGateError {
            guard state == .awaitingMergeGate, activeGeneration == generation, self.plan == plan
            else { return }
            mergeGateError = error.errorDescription
        } catch {
            guard state == .awaitingMergeGate, activeGeneration == generation, self.plan == plan
            else { return }
            mergeGateError = ConductorMergeGateError.patchGenerationFailed.errorDescription
        }
    }

    func presentMergeGateDiff(
        _ file: ConductorMergeGateFile,
        in workspaceSession: WorkspaceSession
    ) async {
        guard state == .awaitingMergeGate, let plan else { return }
        do {
            let diff = try await mergeGateService.diff(for: file, plan: plan)
            guard state == .awaitingMergeGate, self.plan == plan else { return }
            workspaceSession.presentConductorDiff(diff, file: file, plan: plan)
            mergeGateError = nil
        } catch is CancellationError {
            return
        } catch let error as ConductorMergeGateError {
            guard state == .awaitingMergeGate, self.plan == plan else { return }
            mergeGateError = error.errorDescription
        } catch {
            guard state == .awaitingMergeGate, self.plan == plan else { return }
            mergeGateError = ConductorMergeGateError.patchGenerationFailed.errorDescription
        }
    }

    /// Headless tests await the exact task that owns the current step launch,
    /// artifact check, or manifest write; no sleeps or polling.
    func waitForPendingOperation() async {
        let operationTask = operationTask
        await operationTask?.value
        let persistenceTask = runsPublisher.pendingManifestWrite
        await persistenceTask?.value
    }

    private func completeMergeGate() async {
        state = .completed
        guard var currentManifest = manifest else {
            activeGeneration = nil
            activeLauncher = nil
            activeSessionID = nil
            return
        }
        currentManifest.gate = nil
        currentManifest.updatedAt = Date()
        manifest = currentManifest
        let task = runsPublisher.publish(currentManifest)
        await task?.value
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
    }

    private func markAborted() {
        let previousState = state
        state = .aborted
        if var currentManifest = manifest {
            if previousState == .awaitingPlanGate {
                // Same observability rule as `declinePlanGate`: nothing ran,
                // so there is no active step for `activeStepIndex` to stamp,
                // and `runChanged(manifest:)` derives state from step status
                // alone. Leaving every step `.pending` would publish an abort
                // no coordinator could ever see — `await <run> --state
                // aborted` would block until timeout while the run sat
                // projecting `.pending` forever. Reachable whenever the human
                // clicks "Abort Run" on a parked plan gate instead of
                // "Request Changes".
                for index in currentManifest.steps.indices {
                    currentManifest.steps[index].status = .aborted
                    currentManifest.steps[index].finishedAt = Date()
                }
            } else if let index = Self.activeStepIndex(in: previousState),
                currentManifest.steps.indices.contains(index)
            {
                currentManifest.steps[index].status = .aborted
                currentManifest.steps[index].finishedAt = Date()
            }
            currentManifest.gate = nil
            currentManifest.updatedAt = Date()
            manifest = currentManifest
            runsPublisher.publish(currentManifest)
        }
        activeGeneration = nil
        activeLauncher = nil
        activeSessionID = nil
    }

    private func recordFailure(step: Int, reason: String) {
        state = .failed(step: step, reason: reason)
        if var currentManifest = manifest, currentManifest.steps.indices.contains(step) {
            currentManifest.steps[step].status = .failed(reason)
            currentManifest.steps[step].finishedAt = Date()
            currentManifest.gate = nil
            currentManifest.updatedAt = Date()
            manifest = currentManifest
            runsPublisher.publish(currentManifest)
        }
        // Unlike C1's terminal `.failed`, a workflow failure is retryable:
        // `retryFailedStep()` re-establishes a fresh `activeGeneration` and
        // reuses THIS launcher, so it is deliberately kept (not nilled out
        // like `activeGeneration`/`activeSessionID`, which a stale in-flight
        // callback could otherwise still match).
        activeGeneration = nil
        activeSessionID = nil
    }

    private static func activeStepIndex(in state: ConductorWorkflowState) -> Int? {
        switch state {
        case .runningStep(let index), .awaitingArtifact(let index), .awaitingGate(let index):
            index
        default:
            nil
        }
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func requireCurrent(_ expected: UUID, _ actual: UUID?) throws {
        try Task.checkCancellation()
        guard actual == expected else { throw CancellationError() }
    }

    private static func isInFlight(_ state: ConductorWorkflowState) -> Bool {
        switch state {
        case .preparing, .runningStep, .awaitingArtifact, .awaitingGate, .awaitingPlanGate,
            .awaitingMergeGate:
            true
        case .idle, .completed, .failed, .aborted:
            false
        }
    }
}
