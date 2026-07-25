import Foundation

/// Wave-2 compatibility shape from C8-03. That parallel branch owns the
/// coordinator launcher and will supply this same value type at integration;
/// until then the graph can compile against the documented session contract.
nonisolated struct ConductorCoordinatorSession: Identifiable, Equatable, Sendable {
    let id: String
    let provider: ConductorCLIID
    let model: String?
    let goal: String
    let terminalSessionID: UUID?
    let startedAt: Date
    var endedAt: Date?
}

/// Pure coordinator input consumed by the graph projection. Keeping the
/// layout independent of `WorkspaceSession` makes ended-session synthesis and
/// deterministic placement headless-testable.
nonisolated struct CoordinatorNodeInput: Equatable, Sendable {
    let id: String
    let title: String
    let provider: ConductorCLIID
    let terminalSessionID: UUID?
    let startedAt: Date
    let endedAt: Date?
}

nonisolated struct ConductorGraphNode: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case coordinator
        case run
        case step
        case gate
    }

    let id: String
    let kind: Kind
    let title: String
    let runID: String?
    let stepIndex: Int?
    let provider: ConductorCLIID?
    let status: RunStepStatus?
    let runState: EnsembleGraphState
    let detail: String
    let column: Int
    let row: Int
}

nonisolated struct ConductorGraphEdge: Equatable, Sendable {
    let from: String
    let to: String
}

nonisolated struct ConductorGraph: Equatable, Sendable {
    let nodes: [ConductorGraphNode]
    let edges: [ConductorGraphEdge]

    static let empty = ConductorGraph(nodes: [], edges: [])

    var columnCount: Int {
        (nodes.map(\.column).max() ?? -1) + 1
    }

    var rowCount: Int {
        (nodes.map(\.row).max() ?? -1) + 1
    }
}

/// Pure, deterministic projection of durable run manifests plus ephemeral
/// live state. It never edits a workflow, manifest, or topology: graph
/// authoring remains file-based (ADR 0018 / C8 D3).
nonisolated enum ConductorGraphModel {
    /// Structured off-main entry point for SwiftUI's `.task(id:)`. The
    /// synchronous `build` remains the pure test seam; this wrapper opts the
    /// bounded projection out of the GUI target's default MainActor without
    /// creating an unstructured detached task.
    @concurrent
    static func project(
        manifests: [ConductorRunManifest],
        liveStates: [String: ConductorWorkflowState],
        coordinators: [CoordinatorNodeInput]
    ) async -> ConductorGraph {
        guard !Task.isCancelled else { return .empty }
        return build(
            manifests: manifests,
            liveStates: liveStates,
            coordinators: coordinators)
    }

    static func build(
        manifests: [ConductorRunManifest],
        liveStates: [String: ConductorWorkflowState],
        coordinators: [CoordinatorNodeInput]
    ) -> ConductorGraph {
        let orderedManifests = uniqueManifests(manifests)
        let orderedCoordinators = uniqueCoordinators(coordinators)
        let coordinatorIDs = Set(orderedCoordinators.map(\.id))
        let synthesizedIDs = Set(orderedManifests.compactMap(\.startedBy))
            .subtracting(coordinatorIDs)
            .sorted()

        var nodes: [ConductorGraphNode] = []
        var edges: [ConductorGraphEdge] = []
        var edgeKeys: Set<String> = []
        var nextRowByColumn: [Int: Int] = [:]

        func nextRow(in column: Int) -> Int {
            let row = nextRowByColumn[column, default: 0]
            nextRowByColumn[column] = row + 1
            return row
        }

        func appendEdge(from: String, to: String) {
            guard from != to else { return }
            let key = "\(from)\u{0}\(to)"
            guard edgeKeys.insert(key).inserted else { return }
            edges.append(ConductorGraphEdge(from: from, to: to))
        }

        for coordinator in orderedCoordinators {
            let isEnded = coordinator.endedAt != nil
            nodes.append(
                ConductorGraphNode(
                    id: coordinator.id,
                    kind: .coordinator,
                    title: isEnded
                        ? "Coordinator (ended)"
                        : bounded(coordinator.title, fallback: "Coordinator"),
                    runID: nil,
                    stepIndex: nil,
                    provider: coordinator.provider,
                    status: nil,
                    runState: isEnded ? .ended : .running,
                    detail: "\(coordinator.provider.displayName) • \(isEnded ? "ended" : "live")",
                    column: 0,
                    row: nextRow(in: 0)
                ))
        }

        for coordinatorID in synthesizedIDs {
            nodes.append(
                ConductorGraphNode(
                    id: coordinatorID,
                    kind: .coordinator,
                    title: "Coordinator (ended)",
                    runID: nil,
                    stepIndex: nil,
                    provider: nil,
                    status: nil,
                    runState: .ended,
                    detail: "Provider unavailable • ended",
                    column: 0,
                    row: nextRow(in: 0)
                ))
        }

        for manifest in orderedManifests {
            let runNodeID = "run-\(manifest.id)"
            let runColumn = manifest.startedBy == nil ? 0 : 1
            let runPresentation = ConductorRunPresentation.graphNode(
                for: manifest,
                live: liveStates[manifest.id])
            let runProvider = manifest.steps.first?.binding.provider
            nodes.append(
                ConductorGraphNode(
                    id: runNodeID,
                    kind: .run,
                    title: bounded(manifest.label, fallback: manifest.workflowName),
                    runID: manifest.id,
                    stepIndex: nil,
                    provider: runProvider,
                    status: ConductorRunPresentation.overallStatus(for: manifest),
                    runState: runPresentation.state,
                    detail:
                        "\(manifest.steps.count) step\(manifest.steps.count == 1 ? "" : "s") • \(branchLabel(manifest))",
                    column: runColumn,
                    row: nextRow(in: runColumn)
                ))
            if let startedBy = manifest.startedBy {
                appendEdge(from: startedBy, to: runNodeID)
            }

            var producerByArtifact: [String: String] = [:]
            var priorStepNodeID: String?
            for (index, step) in manifest.steps.enumerated() {
                let stepNodeID = "\(runNodeID)/step-\(index + 1)"
                let unresolvedInputs = step.inputArtifacts.filter { artifact in
                    guard
                        let producerIndex = manifest.steps[..<index].firstIndex(where: {
                            $0.handoffArtifact == artifact
                        })
                    else { return true }
                    let producerStatus = manifest.steps[producerIndex].status
                    return producerStatus != .completed && producerStatus != .awaitingGate
                }
                let isBlocked = step.status == .pending && !unresolvedInputs.isEmpty
                let stepPresentation = ConductorRunPresentation.graphNode(
                    for: step.status,
                    blocked: isBlocked)
                nodes.append(
                    ConductorGraphNode(
                        id: stepNodeID,
                        kind: .step,
                        title: bounded(step.agentName, fallback: "Step \(index + 1)"),
                        runID: manifest.id,
                        stepIndex: index,
                        provider: step.binding.provider,
                        status: step.status,
                        runState: stepPresentation.state,
                        detail: stepDetail(
                            step: step,
                            index: index,
                            unresolvedInputs: unresolvedInputs),
                        column: runColumn + index + 1,
                        row: nextRow(in: runColumn + index + 1)
                    ))

                appendEdge(from: priorStepNodeID ?? runNodeID, to: stepNodeID)
                for artifact in step.inputArtifacts {
                    if let producerNodeID = producerByArtifact[artifact] {
                        appendEdge(from: producerNodeID, to: stepNodeID)
                    }
                }
                producerByArtifact[step.handoffArtifact, default: stepNodeID] = stepNodeID
                priorStepNodeID = stepNodeID
            }

            if let gate = manifest.gate {
                let gateNodeID = "\(runNodeID)/gate"
                let gateColumn = runColumn + manifest.steps.count + 1
                let gateState: EnsembleGraphState =
                    gate.kind == .merge ? .mergeGate : .awaitingGate
                let provider =
                    manifest.steps.indices.contains(gate.stepIndex)
                    ? manifest.steps[gate.stepIndex].binding.provider
                    : manifest.steps.last?.binding.provider
                nodes.append(
                    ConductorGraphNode(
                        id: gateNodeID,
                        kind: .gate,
                        title: gate.kind == .merge ? "Merge gate" : "Step gate",
                        runID: manifest.id,
                        stepIndex: gate.stepIndex,
                        provider: provider,
                        status: manifest.steps.indices.contains(gate.stepIndex)
                            ? manifest.steps[gate.stepIndex].status : nil,
                        runState: gateState,
                        detail: gate.kind == .merge
                            ? "Review worktree changes"
                            : "Review step \(gate.stepIndex + 1)'s artifact",
                        column: gateColumn,
                        row: nextRow(in: gateColumn)
                    ))
                let sourceID =
                    manifest.steps.indices.contains(gate.stepIndex)
                    ? "\(runNodeID)/step-\(gate.stepIndex + 1)"
                    : priorStepNodeID ?? runNodeID
                appendEdge(from: sourceID, to: gateNodeID)
            }
        }

        // Column-major ordering is both deterministic and the VoiceOver
        // traversal order. Rendering uses a default node-kind path so C8-04's
        // proposed/ghost extension can degrade to a plain card until it gains
        // bespoke presentation.
        nodes.sort {
            if $0.column != $1.column { return $0.column < $1.column }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.id < $1.id
        }
        edges.sort {
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.to < $1.to
        }
        return ConductorGraph(nodes: nodes, edges: edges)
    }

    private static func uniqueManifests(
        _ manifests: [ConductorRunManifest]
    ) -> [ConductorRunManifest] {
        var seen: Set<String> = []
        return manifests.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueCoordinators(
        _ coordinators: [CoordinatorNodeInput]
    ) -> [CoordinatorNodeInput] {
        var seen: Set<String> = []
        return coordinators.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }.filter { seen.insert($0.id).inserted }
    }

    private static func stepDetail(
        step: ConductorRunManifest.Step,
        index: Int,
        unresolvedInputs: [String]
    ) -> String {
        if !unresolvedInputs.isEmpty {
            return
                "Waiting for \(bounded(unresolvedInputs.joined(separator: ", "), fallback: "dependency"))"
        }
        if case .failed(let reason) = step.status {
            return bounded(reason, fallback: "Step \(index + 1) failed")
        }
        let model = step.binding.model.isEmpty ? "adapter default" : step.binding.model
        return
            "\(step.binding.provider.displayName) • \(bounded(model, fallback: "adapter default"))"
    }

    private static func branchLabel(_ manifest: ConductorRunManifest) -> String {
        manifest.worktreeBranch.isEmpty ? "main workspace" : "worktree"
    }

    private static func bounded(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(120))
    }
}
