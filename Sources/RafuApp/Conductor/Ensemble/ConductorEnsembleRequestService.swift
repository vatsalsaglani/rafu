import Foundation
import RafuCore

nonisolated enum ConductorEnsembleStateProjection {
    /// The one state projection shared by snapshots and pushed run-change
    /// events. Precedence is deliberate and stable:
    /// merged > interrupted > failed > aborted > awaitingPlanGate >
    /// awaitingMergeGate > awaitingGate > running > pending > completed.
    static func runState(
        manifest: ConductorRunManifest,
        liveState: ConductorWorkflowState?
    ) -> EnsembleRunState {
        if manifest.mergedAt != nil { return .merged }
        if manifest.steps.contains(where: { $0.status == .interrupted }) {
            return .interrupted
        }
        if manifest.steps.contains(where: { if case .failed = $0.status { true } else { false } })
            || {
                if case .failed = liveState { return true }
                return false
            }()
        {
            return .failed
        }
        if manifest.steps.contains(where: { $0.status == .aborted })
            || liveState == .aborted
        {
            return .aborted
        }
        // A parked plan gate takes priority over every other open-gate/running
        // reading: nothing has spawned yet, so it can never simultaneously be
        // "running" or "awaiting" a step/merge gate (C8-04).
        if manifest.gate?.kind == .plan || liveState == .awaitingPlanGate {
            return .awaitingPlanGate
        }
        if manifest.gate?.kind == .merge || liveState == .awaitingMergeGate {
            return .awaitingMergeGate
        }
        if manifest.gate?.kind == .step
            || manifest.steps.contains(where: { $0.status == .awaitingGate })
            || {
                if case .awaitingGate = liveState { return true }
                return false
            }()
        {
            return .awaitingGate
        }
        if manifest.steps.contains(where: { $0.status == .running })
            || {
                switch liveState {
                case .preparing, .runningStep, .awaitingArtifact:
                    return true
                case .idle, .awaitingGate, .awaitingPlanGate, .awaitingMergeGate, .completed,
                    .failed, .aborted, nil:
                    return false
                }
            }()
        {
            return .running
        }
        if manifest.steps.isEmpty
            || manifest.steps.contains(where: { $0.status == .pending })
            || liveState == .idle
        {
            return .pending
        }
        return .completed
    }

    static func stepState(_ status: RunStepStatus) -> String {
        switch status {
        case .pending: "pending"
        case .running: "running"
        case .awaitingGate: "awaitingGate"
        case .completed: "completed"
        case .failed: "failed"
        case .aborted: "aborted"
        case .interrupted: "interrupted"
        }
    }
}

@MainActor
final class ConductorEnsembleRequestService {
    struct WorkspaceSnapshot {
        let rootURL: URL
        let session: WorkspaceSession
        let isKeyWindow: Bool
        let registrationOrder: Int
    }

    struct Dependencies {
        var workspaces: () -> [WorkspaceSnapshot]
        var liveState: (WorkspaceSession, String) -> ConductorWorkflowState?
        var workflowController: (WorkspaceSession, String) -> ConductorWorkflowController? = {
            session, runID in session.workflowController(forRunID: runID)
        }
        var startRun:
            (WorkspaceSession, ConductorWorkflowRunRequest) async throws
                -> ConductorWorkflowController = { session, request in
                    try await session.conductorConcurrentRuns.start(
                        request,
                        launcher: WorkspaceConductorRunLauncher(
                            workspaceSession: session,
                            runID: request.runID
                        )
                    )
                }
        var definitionLibrary = ConductorDefinitionLibrary()
        var userLibraryRoot: () -> URL = {
            ConductorDefinitionLibrary.defaultUserLibraryRoot
        }
        var tokenStore: ConductorEnsembleTokenStore = .shared
        /// Settings → Agents' per-CLI default model, the LAST fallback before
        /// "let the CLI decide". Injected so a test can point at its own
        /// `UserDefaults` suite instead of the user's.
        var defaultModelStore = ConductorDefaultModelStore()
        var eventCenter: ConductorEnsembleEventCenter
        var makeRunID: () -> String = {
            UUID().uuidString.lowercased()
        }
    }

    static let shared = ConductorEnsembleRequestService()

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func handle(_ envelope: LauncherIPCEnvelope) -> LauncherIPCResponse {
        guard envelope.kind.isEnsemble, !envelope.kind.isStreaming,
            let payload = envelope.ensemble
        else {
            return .ensemble(.failure(code: 64, message: "invalid Ensemble request payload"))
        }
        guard let workspace = matchingWorkspace(for: payload.workingDirectory) else {
            return .ensemble(.failure(code: 69, message: "workspace not open in Rafu"))
        }

        switch envelope.kind {
        case .ensembleStatus:
            guard payload.verb == "status" else {
                return .ensemble(.failure(code: 64, message: "invalid status payload"))
            }
            return .ensemble(.status(status(payload: payload, workspace: workspace)))
        case .ensembleArtifact:
            guard payload.verb == "artifact" else {
                return .ensemble(.failure(code: 64, message: "invalid artifact payload"))
            }
            return .ensemble(artifact(payload: payload, workspace: workspace))
        case .handshake, .openFolder, .goto, .ensembleSubscribe,
            .ensembleRun, .ensembleAbort, .ensembleNote, .ensembleGrant,
            .ensembleProposeMerge, .unknown:
            return .ensemble(.failure(code: 64, message: "unsupported Ensemble request"))
        }
    }

    func handleAsync(_ envelope: LauncherIPCEnvelope) async -> LauncherIPCResponse {
        guard envelope.kind.isEnsemble, !envelope.kind.isStreaming,
            let payload = envelope.ensemble
        else {
            return .ensemble(.failure(code: 64, message: "invalid Ensemble request payload"))
        }
        guard let workspace = matchingWorkspace(for: payload.workingDirectory) else {
            return .ensemble(.failure(code: 69, message: "workspace not open in Rafu"))
        }

        switch envelope.kind {
        case .ensembleStatus:
            guard payload.verb == "status" else {
                return .ensemble(.failure(code: 64, message: "invalid status payload"))
            }
            return .ensemble(.status(status(payload: payload, workspace: workspace)))
        case .ensembleArtifact:
            guard payload.verb == "artifact" else {
                return .ensemble(.failure(code: 64, message: "invalid artifact payload"))
            }
            return .ensemble(artifact(payload: payload, workspace: workspace))
        case .ensembleRun:
            guard payload.verb == "run" else {
                return .ensemble(.failure(code: 64, message: "invalid run payload"))
            }
            return .ensemble(await startRun(payload: payload, workspace: workspace))
        case .ensembleAbort:
            guard payload.verb == "abort" else {
                return .ensemble(.failure(code: 64, message: "invalid abort payload"))
            }
            return .ensemble(abort(payload: payload, workspace: workspace))
        case .ensembleNote:
            guard payload.verb == "note" else {
                return .ensemble(.failure(code: 64, message: "invalid note payload"))
            }
            return .ensemble(await note(payload: payload, workspace: workspace))
        case .ensembleGrant:
            guard payload.verb == "grant" else {
                return .ensemble(.failure(code: 64, message: "invalid grant payload"))
            }
            return .ensemble(grant(payload: payload, workspace: workspace))
        case .ensembleProposeMerge:
            guard payload.verb == "propose-merge" else {
                return .ensemble(.failure(code: 64, message: "invalid propose-merge payload"))
            }
            return .ensemble(await proposeMerge(payload: payload, workspace: workspace))
        case .handshake, .openFolder, .goto, .ensembleSubscribe, .unknown:
            return .ensemble(.failure(code: 64, message: "unsupported Ensemble request"))
        }
    }

    private func matchingWorkspace(for workingDirectory: String) -> WorkspaceSnapshot? {
        guard workingDirectory.hasPrefix("/") else { return nil }
        let target = normalizedURL(workingDirectory).path
        return
            dependencies.workspaces()
            .enumerated()
            .compactMap { index, workspace -> (WorkspaceSnapshot, Int, Int, Bool)? in
                let root = normalizedURL(workspace.rootURL.path).path
                guard target == root || target.hasPrefix(rootWithSeparator(root)) else {
                    return nil
                }
                return (
                    workspace,
                    root.count,
                    min(index, workspace.registrationOrder),
                    workspace.isKeyWindow
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.3 != rhs.3 { return lhs.3 }
                return lhs.2 < rhs.2
            }
            .first?.0
    }

    private func status(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) -> EnsembleStatusResult {
        let requested = Set(payload.runIDs)
        var manifests = workspace.session.conductorRuns.filter {
            requested.isEmpty || requested.contains($0.id)
        }
        if payload.tree == true {
            manifests = treeOrdered(manifests)
        }
        let runs = manifests.map { manifest in
            summary(
                manifest: manifest,
                rootURL: workspace.rootURL,
                liveState: dependencies.liveState(workspace.session, manifest.id)
            )
        }
        let events = payload.sinceCursor.map(dependencies.eventCenter.eventsSince) ?? []
        return EnsembleStatusResult(
            runs: runs,
            cursor: dependencies.eventCenter.cursor,
            verbVersion: LauncherIPCProtocol.ensembleVerbVersion,
            tree: payload.tree == true,
            events: events
        )
    }

    private func artifact(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) -> EnsembleResponsePayload {
        guard payload.runIDs.count == 1, let stepIndex = payload.stepIndex else {
            return .failure(code: 64, message: "artifact requires one run and one step")
        }
        guard
            let manifest = workspace.session.conductorRuns.first(where: {
                $0.id == payload.runIDs[0]
            }),
            manifest.steps.indices.contains(stepIndex)
        else {
            return .failure(code: 65, message: "Ensemble run or step not found")
        }
        return .artifact(
            EnsembleArtifactResult(
                runID: manifest.id,
                stepIndex: stepIndex,
                artifacts: artifactPaths(
                    manifest: manifest,
                    step: manifest.steps[stepIndex],
                    rootURL: workspace.rootURL
                )
            ))
    }

    /// `resolveRunDefinitions`'s outcome. A bespoke enum rather than
    /// `Result<_, EnsembleResponsePayload>`: the standard library constrains
    /// `Result`'s `Failure` to `Swift.Error`, and `EnsembleResponsePayload`
    /// deliberately does NOT conform to it — it is a wire DTO, not a thrown
    /// error type, and widening its conformance surface for this one
    /// internal seam is not worth doing.
    private enum RunDefinitionsResolution {
        case success((workflow: ConductorWorkflowDefinition, roles: [ConductorAgentDefinition]))
        case failure(EnsembleResponsePayload)
    }

    /// Loads the definition library, resolves `payload.workflow`'s steps
    /// against it, and applies `--role` overrides and the `--artifact`
    /// input-reference appendix — the ONE implementation of "what a payload's
    /// workflow/roles resolve to". Shared by `startRun` and the
    /// `planGateReparse` closure `startRun` installs on every controller it
    /// creates (advisor A2): re-parsing at plan-gate approval time must apply
    /// the SAME override/appendix semantics the original request used, never
    /// a second, drifting implementation.
    private func resolveRunDefinitions(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) async -> RunDefinitionsResolution {
        guard
            let workflowName = payload.workflow?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !workflowName.isEmpty
        else {
            return .failure(.failure(code: 64, message: "run requires a workflow"))
        }

        let snapshot: ConductorDefinitionLibrarySnapshot
        do {
            snapshot = try await dependencies.definitionLibrary.load(
                workspaceRoot: workspace.rootURL,
                userLibraryRoot: dependencies.userLibraryRoot()
            )
        } catch is CancellationError {
            return .failure(.failure(code: 75, message: "Ensemble run preparation was cancelled"))
        } catch {
            return .failure(.failure(code: 65, message: "Ensemble definitions could not be loaded"))
        }

        guard
            let libraryWorkflow = snapshot.workflows.first(where: {
                $0.stem == workflowName || $0.definition?.name == workflowName
            }),
            libraryWorkflow.isLaunchable,
            let workflow = libraryWorkflow.definition
        else {
            return .failure(.failure(code: 65, message: "Ensemble workflow not found or invalid"))
        }

        var roles: [ConductorAgentDefinition]
        do {
            roles = try ConductorWorkflowBinder.resolve(
                workflow: workflow,
                agents: snapshot.agents.filter(\.isLaunchable).compactMap(\.agentFile)
            )
        } catch {
            return .failure(
                .failure(code: 65, message: "Ensemble workflow role could not be resolved"))
        }

        for override in payload.roleOverrides ?? [] {
            guard let provider = ConductorCLIID(rawValue: override.provider) else {
                return .failure(.failure(code: 65, message: "Ensemble provider is unknown"))
            }
            let matchingIndices = roles.indices.filter { index in
                roles[index].name == override.name
                    || workflow.steps[index].agentName == override.name
            }
            guard !matchingIndices.isEmpty else {
                return .failure(.failure(code: 65, message: "Ensemble workflow role is unknown"))
            }
            for index in matchingIndices {
                let role = roles[index]
                roles[index] = ConductorAgentDefinition(
                    name: role.name,
                    provider: provider,
                    model: override.model ?? role.model,
                    autonomy: role.autonomy,
                    handoffArtifact: role.handoffArtifact,
                    promptBody: role.promptBody
                )
            }
        }

        roles = applyModelDefaults(to: roles, payload: payload, workspace: workspace)

        let artifacts = payload.artifacts ?? []
        guard artifacts.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
            return .failure(.failure(code: 64, message: "run artifacts must be absolute paths"))
        }
        if !artifacts.isEmpty, !roles.isEmpty {
            let role = roles[0]
            let references = artifacts.enumerated().map { index, path in
                "- input-\(index + 1): \(path)"
            }.joined(separator: "\n")
            roles[0] = ConductorAgentDefinition(
                name: role.name,
                provider: role.provider,
                model: role.model,
                autonomy: role.autonomy,
                handoffArtifact: role.handoffArtifact,
                promptBody:
                    role.promptBody
                    + "\n\nInput artifacts (read these files before you begin):\n"
                    + references
            )
        }

        return .success((workflow, roles))
    }

    /// Fills in each role's model through the ONE shared resolver:
    /// `role.model` (the agent file's own choice, or a `--role` override) →
    /// this Ensemble's per-provider default → the user's Settings default →
    /// nothing, in which case no `--model` flag is passed and the CLI applies
    /// its own configuration.
    ///
    /// Applied AFTER `--role` overrides deliberately: an override is the
    /// coordinator's explicit per-run choice and must outrank an
    /// ensemble-wide preference. Applied inside `resolveRunDefinitions` so
    /// the plan-gate re-parse gets identical semantics rather than a second,
    /// drifting implementation.
    private func applyModelDefaults(
        to roles: [ConductorAgentDefinition],
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) -> [ConductorAgentDefinition] {
        let ensembleDefaults = ensembleModelDefaults(payload: payload, workspace: workspace)
        return roles.map { role in
            let resolution = ConductorModelResolution.resolve(
                explicit: role.model,
                ensembleDefault: ensembleDefaults[role.provider],
                settingsDefault: dependencies.defaultModelStore.defaultModel(for: role.provider))
            let model = resolution.modelID ?? ""
            guard model != role.model else { return role }
            return ConductorAgentDefinition(
                name: role.name,
                provider: role.provider,
                model: model,
                autonomy: role.autonomy,
                handoffArtifact: role.handoffArtifact,
                promptBody: role.promptBody)
        }
    }

    /// The launching Ensemble's per-provider model preferences, read from the
    /// coordinator record the request's own token identifies. These ride
    /// ALONGSIDE the grant, never inside it: the grant is a permission
    /// contract (ADR 0018), and a model preference is not a permission. An
    /// unknown or already-revoked token simply contributes no defaults.
    private func ensembleModelDefaults(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) -> [ConductorCLIID: String] {
        guard let coordinatorID = dependencies.tokenStore.validate(payload.token)?.coordinatorID
        else { return [:] }
        return workspace.session.conductorCoordinatorSessions
            .first { $0.id == coordinatorID }?
            .providerModelDefaults ?? [:]
    }

    /// Workspace-relative paths for the plan gate's "files as tabs" UI: the
    /// workflow file plus each step's matched agent file, in step order,
    /// deduplicated. Best-effort — a step whose agent could not be matched by
    /// name or stem simply contributes no row rather than failing the run.
    private func planGateFilePaths(
        workflow: ConductorWorkflowDefinition,
        libraryWorkflowFileURL: URL,
        agents: [ConductorLibraryAgent],
        rootURL: URL
    ) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        func append(_ url: URL) {
            let relative = Self.relativeWorkspacePath(of: url, root: rootURL)
            guard seen.insert(relative).inserted else { return }
            paths.append(relative)
        }
        append(libraryWorkflowFileURL)
        for step in workflow.steps {
            guard
                let agentFile = agents.first(where: {
                    $0.definition?.name == step.agentName
                        || $0.stem == step.agentName
                })
            else { continue }
            append(agentFile.fileURL)
        }
        return paths
    }

    private static func relativeWorkspacePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func startRun(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) async -> EnsembleResponsePayload {
        guard let token = payload.token,
            let tokenEntry = dependencies.tokenStore.validate(token)
        else {
            return failure(.noToken)
        }

        let workflow: ConductorWorkflowDefinition
        let roles: [ConductorAgentDefinition]
        switch await resolveRunDefinitions(payload: payload, workspace: workspace) {
        case .failure(let response):
            return response
        case .success(let resolved):
            workflow = resolved.workflow
            roles = resolved.roles
        }

        var planGateFiles: [String] = []
        if payload.planGate == true {
            let snapshot = try? await dependencies.definitionLibrary.load(
                workspaceRoot: workspace.rootURL,
                userLibraryRoot: dependencies.userLibraryRoot()
            )
            if let snapshot,
                let libraryWorkflow = snapshot.workflows.first(where: {
                    $0.definition?.name == workflow.name
                })
            {
                planGateFiles = planGateFilePaths(
                    workflow: workflow,
                    libraryWorkflowFileURL: libraryWorkflow.fileURL,
                    agents: snapshot.agents,
                    rootURL: workspace.rootURL
                )
            }
        }

        let inFlight = inFlightRunIDs(workspace: workspace)
        switch dependencies.tokenStore.enforce(
            token: token,
            providers: roles.map(\.provider),
            inFlightRunIDs: inFlight,
            manifests: workspace.session.conductorRuns
        ) {
        case .failure(let violation):
            return failure(violation)
        case .success:
            break
        }

        let runID = dependencies.makeRunID()
        guard ConductorRunStore.isValidRunID(runID),
            dependencies.tokenStore.reserveChildRun(token: token, runID: runID)
        else {
            return .failure(code: 75, message: "Ensemble could not reserve a child run")
        }
        var didStart = false
        defer {
            if !didStart {
                dependencies.tokenStore.cancelChildRunReservation(
                    token: token,
                    runID: runID
                )
            }
        }

        let prompt = payload.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = payload.baseReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = payload.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskPrompt = prompt.map { $0.isEmpty ? workflow.name : $0 } ?? workflow.name
        let baseReference = base.map { $0.isEmpty ? "HEAD" : $0 } ?? "HEAD"
        let request = ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: roles,
            taskPrompt: taskPrompt,
            baseReference: baseReference,
            runID: runID,
            startedBy: tokenEntry.coordinatorID,
            label: label?.isEmpty == false ? label : nil,
            planGateRequested: payload.planGate == true,
            planGateFiles: planGateFiles
        )

        let controller: ConductorWorkflowController
        do {
            controller = try await dependencies.startRun(workspace.session, request)
        } catch let error as ConductorConcurrentRunError {
            return .failure(
                code: 75,
                message: error.errorDescription ?? "The Ensemble run window cap was reached"
            )
        } catch is CancellationError {
            return .failure(code: 75, message: "Ensemble run preparation was cancelled")
        } catch {
            return .failure(code: 75, message: "Ensemble could not start the child run")
        }

        // Installed unconditionally (harmless when the run never parks): the
        // approve-time re-parse must apply the SAME `--role`/`--artifact`
        // semantics this request just used (advisor A2), so it re-runs the
        // one shared resolver against the SAME captured payload/workspace
        // rather than reconstructing overrides from the parked manifest.
        // `session` is captured WEAKLY and the snapshot rebuilt inside. The
        // session transitively owns this closure — session →
        // `conductorConcurrentRuns` → `controllersByRunID` → controller →
        // `planGateReparse` — so capturing `workspace` (which holds a strong
        // `session`) would retain the whole workspace, its terminal sessions,
        // and its text storages for the app's lifetime, since the only pruner
        // is a manual UI action. `onGateReady` uses `[weak self]` for exactly
        // this reason; this follows that discipline.
        let workspaceRootURL = workspace.rootURL
        let workspaceIsKeyWindow = workspace.isKeyWindow
        let workspaceRegistrationOrder = workspace.registrationOrder
        controller.planGateReparse = { [weak self, weak session = workspace.session] _ in
            guard let self, let session else {
                return .failure("Ensemble definitions could not be re-read.")
            }
            let workspace = WorkspaceSnapshot(
                rootURL: workspaceRootURL,
                session: session,
                isKeyWindow: workspaceIsKeyWindow,
                registrationOrder: workspaceRegistrationOrder)
            switch await self.resolveRunDefinitions(payload: payload, workspace: workspace) {
            case .success(let resolved):
                return .success(workflow: resolved.workflow, roles: resolved.roles)
            case .failure(let response):
                if case .failure(_, let message) = response {
                    return .failure(message)
                }
                return .failure("Ensemble definitions could not be re-read.")
            }
        }

        guard let manifest = controller.manifest, let plan = controller.plan else {
            return .failure(code: 65, message: "Ensemble child run preparation failed")
        }
        if case .failed = controller.state {
            return .failure(code: 65, message: "Ensemble child run preparation failed")
        }
        if controller.state == .aborted {
            return .failure(code: 75, message: "Ensemble child run was aborted while starting")
        }

        dependencies.tokenStore.recordChildRun(token: token, runID: runID)
        didStart = true
        return .runStarted(
            EnsembleRunStartResult(
                runID: runID,
                workflow: workflow.name,
                worktree: plan.executionRoot.path,
                branch: plan.branchName ?? manifest.worktreeBranch,
                state: ConductorEnsembleStateProjection.runState(
                    manifest: manifest,
                    liveState: controller.state
                ),
                startedBy: tokenEntry.coordinatorID
            ))
    }

    private func abort(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) -> EnsembleResponsePayload {
        guard let entry = dependencies.tokenStore.validate(payload.token) else {
            return failure(.noToken)
        }
        guard payload.runIDs.count == 1 else {
            return .failure(code: 64, message: "abort requires one run")
        }
        let runID = payload.runIDs[0]
        guard
            let manifest = workspace.session.conductorRuns.first(where: { $0.id == runID })
        else {
            return .failure(code: 65, message: "Ensemble run not found")
        }
        guard manifest.startedBy == entry.coordinatorID else {
            return .failure(code: 77, message: "This coordinator does not own that run")
        }
        guard
            let controller = dependencies.workflowController(workspace.session, runID)
        else {
            return .failure(code: 65, message: "Ensemble run is not active")
        }
        controller.abort()
        return .mutation(
            EnsembleMutationResult(verb: "aborted", runID: runID, state: .aborted))
    }

    private func note(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) async -> EnsembleResponsePayload {
        guard let entry = dependencies.tokenStore.validate(payload.token) else {
            return failure(.noToken)
        }
        guard payload.runIDs.count == 1, let text = payload.text, !text.isEmpty else {
            return .failure(code: 64, message: "note requires one run and nonempty text")
        }
        guard text.count <= ConductorEnsembleNoteStore.maximumTextCharacters else {
            return .failure(code: 64, message: "note text exceeds 1000 characters")
        }
        let runID = payload.runIDs[0]
        guard
            let manifest = workspace.session.conductorRuns.first(where: { $0.id == runID })
        else {
            return .failure(code: 65, message: "Ensemble run not found")
        }
        guard manifest.startedBy == entry.coordinatorID else {
            return .failure(code: 77, message: "This coordinator does not own that run")
        }

        do {
            _ = try await ConductorEnsembleNoteStore(
                workspaceRoot: workspace.rootURL,
                eventCenter: dependencies.eventCenter
            ).append(
                runID: runID,
                from: entry.coordinatorID,
                text: text
            )
            return .mutation(EnsembleMutationResult(verb: "noted", runID: runID))
        } catch ConductorEnsembleNoteStoreError.textTooLong {
            return .failure(code: 64, message: "note text exceeds 1000 characters")
        } catch ConductorEnsembleNoteStoreError.fileFull {
            return .failure(code: 75, message: "This run's Ensemble notes are full")
        } catch {
            return .failure(code: 65, message: "Ensemble note could not be persisted")
        }
    }

    /// Token-scoped: re-raises the human merge gate for every named run this
    /// coordinator started, optionally attaching a note. NEVER applies,
    /// commits, or merges anything — applying stays the user's
    /// `applyToWorkspace()` verb in the UI. Validates EVERY named run before
    /// mutating or raising attention for ANY of them (all-or-nothing).
    private func proposeMerge(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) async -> EnsembleResponsePayload {
        guard let entry = dependencies.tokenStore.validate(payload.token) else {
            return failure(.noToken)
        }
        guard !payload.runIDs.isEmpty else {
            return .failure(code: 64, message: "propose-merge requires at least one run")
        }
        if let text = payload.text,
            text.count > ConductorEnsembleNoteStore.maximumTextCharacters
        {
            return .failure(code: 64, message: "note text exceeds 1000 characters")
        }

        var manifests: [ConductorRunManifest] = []
        for runID in payload.runIDs {
            guard
                let manifest = workspace.session.conductorRuns.first(where: { $0.id == runID })
            else {
                return .failure(code: 65, message: "Ensemble run not found")
            }
            guard manifest.startedBy == entry.coordinatorID else {
                return .failure(code: 77, message: "This coordinator does not own that run")
            }
            let state = ConductorEnsembleStateProjection.runState(
                manifest: manifest,
                liveState: dependencies.liveState(workspace.session, runID)
            )
            guard state == .awaitingMergeGate else {
                return .failure(
                    code: 65,
                    message: "\(runID) is \(state.rawValue), not awaiting a merge gate"
                )
            }
            manifests.append(manifest)
        }

        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        for manifest in manifests {
            if let text, !text.isEmpty {
                _ = try? await ConductorEnsembleNoteStore(
                    workspaceRoot: workspace.rootURL,
                    eventCenter: dependencies.eventCenter
                ).append(runID: manifest.id, from: entry.coordinatorID, text: text)
            }
            let stepIndex = manifest.gate?.stepIndex ?? max(0, manifest.steps.count - 1)
            let agentName =
                manifest.steps.indices.contains(stepIndex)
                ? manifest.steps[stepIndex].agentName
                : (manifest.steps.last?.agentName ?? manifest.workflowName)
            // Reuses the exact same seam a live pipeline gate raises through
            // (publishes the gate event + applies ADR 0016 HUD/notification
            // arbitration) — no separate policy to keep in sync.
            workspace.session.raiseConductorGateAttention(
                ConductorGateReadyEvent(
                    runID: manifest.id,
                    kind: .merge,
                    stepIndex: stepIndex,
                    workflowName: manifest.workflowName,
                    agentName: agentName,
                    safeToApproveRemotely: false
                ))
        }

        return .proposeMerge(
            EnsembleProposeMergeResult(accepted: payload.runIDs, state: "awaiting_human"))
    }

    private func grant(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) -> EnsembleResponsePayload {
        let status = dependencies.tokenStore.status(
            token: payload.token,
            inFlightRunIDs: inFlightRunIDs(workspace: workspace),
            manifests: workspace.session.conductorRuns
        )
        switch status {
        case .failure(let violation):
            return failure(violation)
        case .success(let enforcement):
            let grant = enforcement.entry.grant
            return .grant(
                EnsembleGrantResult(
                    maxConcurrentChildRuns: grant.maxConcurrentChildRuns,
                    activeChildRuns: enforcement.activeChildRuns,
                    maxTotalChildRuns: grant.maxTotalChildRuns,
                    startedChildRuns: enforcement.entry.startedRunIDs.count,
                    allowedProviders: grant.allowedProviders.map(\.rawValue),
                    deadline: grant.deadline,
                    usageConsumedPercentPoints: enforcement.usageConsumedPercentPoints,
                    usageCeilingPercentPoints: grant.usageCeilingPercentPoints
                ))
        }
    }

    private func inFlightRunIDs(workspace: WorkspaceSnapshot) -> Set<String> {
        var runIDs = Set<String>()
        for manifest in workspace.session.conductorRuns {
            let state = ConductorEnsembleStateProjection.runState(
                manifest: manifest,
                liveState: dependencies.liveState(workspace.session, manifest.id)
            )
            switch state {
            case .pending, .running, .awaitingGate, .awaitingPlanGate,
                .awaitingMergeGate:
                runIDs.insert(manifest.id)
            case .completed, .failed, .aborted, .interrupted, .merged:
                break
            }
        }
        return runIDs
    }

    private func failure(
        _ violation: ConductorEnsembleGrantViolation
    ) -> EnsembleResponsePayload {
        .failure(code: violation.exitCode, message: violation.reason)
    }

    private func summary(
        manifest: ConductorRunManifest,
        rootURL: URL,
        liveState: ConductorWorkflowState?
    ) -> EnsembleRunSummary {
        EnsembleRunSummary(
            runID: manifest.id,
            workflowName: manifest.workflowName,
            label: manifest.label,
            state: ConductorEnsembleStateProjection.runState(
                manifest: manifest,
                liveState: liveState
            ),
            startedBy: manifest.startedBy,
            gate: manifest.gate.map {
                EnsembleGateSummary(
                    kind: $0.kind == .merge ? "merge" : "step",
                    stepIndex: $0.stepIndex
                )
            },
            steps: manifest.steps.enumerated().map { index, step in
                EnsembleStepSummary(
                    index: index,
                    agentName: step.agentName,
                    provider: step.binding.provider.rawValue,
                    model: step.binding.model,
                    state: ConductorEnsembleStateProjection.stepState(step.status),
                    attempt: step.attempt ?? 1,
                    evidencePath: evidencePath(
                        manifest: manifest,
                        step: step,
                        rootURL: rootURL
                    ),
                    artifacts: artifactPaths(
                        manifest: manifest,
                        step: step,
                        rootURL: rootURL
                    )
                )
            },
            usageLines: ConductorRunPresentation.runUsageLines(for: manifest)
        )
    }

    private func treeOrdered(_ manifests: [ConductorRunManifest]) -> [ConductorRunManifest] {
        let ids = Set(manifests.map(\.id))
        let children = Dictionary(
            grouping: manifests.filter { manifest in
                manifest.startedBy.map(ids.contains) == true
            },
            by: { $0.startedBy ?? "" }
        )
        var result: [ConductorRunManifest] = []
        var visited = Set<String>()

        func appendTree(_ manifest: ConductorRunManifest) {
            guard visited.insert(manifest.id).inserted else { return }
            result.append(manifest)
            for child in children[manifest.id] ?? [] {
                appendTree(child)
            }
        }

        for root in manifests where root.startedBy == nil {
            appendTree(root)
        }
        var externalCoordinatorIDs: [String] = []
        for manifest in manifests {
            guard let startedBy = manifest.startedBy, !ids.contains(startedBy),
                !externalCoordinatorIDs.contains(startedBy)
            else { continue }
            externalCoordinatorIDs.append(startedBy)
        }
        for coordinatorID in externalCoordinatorIDs {
            for child in manifests where child.startedBy == coordinatorID {
                appendTree(child)
            }
        }
        for manifest in manifests {
            appendTree(manifest)
        }
        return result
    }

    private func evidencePath(
        manifest: ConductorRunManifest,
        step: ConductorRunManifest.Step,
        rootURL: URL
    ) -> String? {
        guard let relative = step.evidencePath, !relative.isEmpty else { return nil }
        return
            rootURL
            .appending(path: ".rafu/runs/\(manifest.id)/\(relative)", directoryHint: .isDirectory)
            .standardizedFileURL.path
    }

    private func artifactPaths(
        manifest: ConductorRunManifest,
        step: ConductorRunManifest.Step,
        rootURL: URL
    ) -> [String] {
        var base =
            rootURL
            .appending(path: ".rafu/runs/\(manifest.id)", directoryHint: .isDirectory)
        if let evidencePath = step.evidencePath, !evidencePath.isEmpty {
            base.append(path: evidencePath, directoryHint: .isDirectory)
        }
        return [
            base
                .appending(path: "handoff", directoryHint: .isDirectory)
                .appending(path: step.handoffArtifact, directoryHint: .notDirectory)
                .standardizedFileURL.path
        ]
    }

    private func normalizedURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func rootWithSeparator(_ path: String) -> String {
        path == "/" ? "/" : path + "/"
    }
}

extension ConductorEnsembleRequestService.Dependencies {
    fileprivate static var live: Self {
        Self(
            workspaces: {
                WorkspaceWindowRegistry.shared.sessionSnapshots().map {
                    ConductorEnsembleRequestService.WorkspaceSnapshot(
                        rootURL: $0.rootURL,
                        session: $0.session,
                        isKeyWindow: $0.isKeyWindow,
                        registrationOrder: $0.registrationOrder
                    )
                }
            },
            liveState: { session, runID in
                session.workflowController(forRunID: runID)?.state
            },
            eventCenter: .shared
        )
    }
}
