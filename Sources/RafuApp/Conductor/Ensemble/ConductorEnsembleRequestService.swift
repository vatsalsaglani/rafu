import Foundation
import RafuCore

nonisolated enum ConductorEnsembleStateProjection {
    /// The one state projection shared by snapshots and pushed run-change
    /// events. Precedence is deliberate and stable:
    /// merged > interrupted > failed > aborted > awaiting* > running >
    /// pending > completed.
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
                case .idle, .awaitingGate, .awaitingMergeGate, .completed, .failed, .aborted, nil:
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
            .ensembleRun, .ensembleAbort, .ensembleNote, .ensembleGrant, .unknown:
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

    private func startRun(
        payload: EnsembleRequestPayload,
        workspace: WorkspaceSnapshot
    ) async -> EnsembleResponsePayload {
        guard let token = payload.token,
            let tokenEntry = dependencies.tokenStore.validate(token)
        else {
            return failure(.noToken)
        }
        guard
            let workflowName = payload.workflow?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !workflowName.isEmpty
        else {
            return .failure(code: 64, message: "run requires a workflow")
        }

        let snapshot: ConductorDefinitionLibrarySnapshot
        do {
            snapshot = try await dependencies.definitionLibrary.load(
                workspaceRoot: workspace.rootURL,
                userLibraryRoot: dependencies.userLibraryRoot()
            )
        } catch is CancellationError {
            return .failure(code: 75, message: "Ensemble run preparation was cancelled")
        } catch {
            return .failure(code: 65, message: "Ensemble definitions could not be loaded")
        }

        guard
            let libraryWorkflow = snapshot.workflows.first(where: {
                $0.stem == workflowName || $0.definition?.name == workflowName
            }),
            libraryWorkflow.isLaunchable,
            let workflow = libraryWorkflow.definition
        else {
            return .failure(code: 65, message: "Ensemble workflow not found or invalid")
        }

        var roles: [ConductorAgentDefinition]
        do {
            roles = try ConductorWorkflowBinder.resolve(
                workflow: workflow,
                agents: snapshot.agents.filter(\.isLaunchable).compactMap(\.agentFile)
            )
        } catch {
            return .failure(code: 65, message: "Ensemble workflow role could not be resolved")
        }

        for override in payload.roleOverrides ?? [] {
            guard let provider = ConductorCLIID(rawValue: override.provider) else {
                return .failure(code: 65, message: "Ensemble provider is unknown")
            }
            let matchingIndices = roles.indices.filter { index in
                roles[index].name == override.name
                    || workflow.steps[index].agentName == override.name
            }
            guard !matchingIndices.isEmpty else {
                return .failure(code: 65, message: "Ensemble workflow role is unknown")
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

        let artifacts = payload.artifacts ?? []
        guard artifacts.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
            return .failure(code: 64, message: "run artifacts must be absolute paths")
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
            label: label?.isEmpty == false ? label : nil
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
