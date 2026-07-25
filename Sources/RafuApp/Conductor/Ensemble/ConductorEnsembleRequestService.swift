import Foundation
import RafuCore

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
        var eventCenter: ConductorEnsembleEventCenter
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
        case .handshake, .openFolder, .goto, .ensembleSubscribe, .unknown:
            return .ensemble(.failure(code: 64, message: "unsupported Ensemble request"))
        }
    }

    /// The one state projection shared by snapshots and pushed run-change
    /// events. Precedence is deliberate and stable:
    /// merged > interrupted > failed > aborted > awaiting* > running >
    /// pending > completed.
    nonisolated static func runState(
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

    nonisolated static func stepState(_ status: RunStepStatus) -> String {
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

    private func summary(
        manifest: ConductorRunManifest,
        rootURL: URL,
        liveState: ConductorWorkflowState?
    ) -> EnsembleRunSummary {
        EnsembleRunSummary(
            runID: manifest.id,
            workflowName: manifest.workflowName,
            label: manifest.label,
            state: Self.runState(manifest: manifest, liveState: liveState),
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
                    state: Self.stepState(step.status),
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
        let children = Dictionary(grouping: manifests) { manifest in
            manifest.startedBy.flatMap { ids.contains($0) ? $0 : nil }
        }
        var result: [ConductorRunManifest] = []
        var visited = Set<String>()

        func appendTree(_ manifest: ConductorRunManifest) {
            guard visited.insert(manifest.id).inserted else { return }
            result.append(manifest)
            for child in children[manifest.id] ?? [] {
                appendTree(child)
            }
        }

        for root in children[nil] ?? [] {
            appendTree(root)
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
            // C8-02 needs the registry to expose weak session snapshots
            // alongside its existing root/window metadata. That shared-file
            // seam is intentionally left to the coordinator handoff.
            workspaces: { [] },
            liveState: { session, runID in
                session.workflowController(forRunID: runID)?.state
            },
            eventCenter: .shared
        )
    }
}
