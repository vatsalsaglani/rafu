import Foundation

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
    /// The coordinator's chosen model, `nil`/empty when none was set and the
    /// CLI decides. Declared `var` with a default so the synthesized
    /// memberwise init stays additive — a `let` with a default value is
    /// EXCLUDED from that init (see `ConductorRunManifest.gate`'s note).
    var model: String? = nil
}

nonisolated struct ConductorGraphNode: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case coordinator
        case run
        case step
        case gate
        /// One entry from a completed step's `Step.proposals` (C8-04) — an
        /// advisory suggestion the step's artifact declared, not a run the
        /// coordinator has admitted. No verbs in v1: admission is the
        /// coordinator's own `run` decision. Dismissed-vs-admitted
        /// bookkeeping is a recorded follow-up, not built here.
        case proposedGhost
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
    /// Chip-sized model name for this node, so two nodes running the same CLI
    /// are distinguishable at a glance. `nil` only when the node has no model
    /// concept at all — a synthesized coordinator whose provider is unknown,
    /// or a run with no steps.
    ///
    /// The node card truncates this; `modelDetailLabel` is what its `help` and
    /// accessibility label carry, so the model is never the only distinguishing
    /// value AND only present in truncated form.
    var modelLabel: String? = nil
    /// The untruncated form, naming the source of the choice.
    var modelDetailLabel: String? = nil
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
            let model = ConductorRunPresentation.modelResolution(
                forModel: coordinator.model,
                provider: coordinator.provider)
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
                    row: nextRow(in: 0),
                    modelLabel: model.label,
                    modelDetailLabel:
                        "\(coordinator.provider.displayName) — \(model.detailedLabel)"
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
            let runModels = ConductorRunPresentation.modelSummary(
                for: manifest.steps.map(\.binding))
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
                    row: nextRow(in: runColumn),
                    modelLabel: runModels?.label,
                    modelDetailLabel: runModels?.detailedLabel
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
                let stepModel = ConductorRunPresentation.modelResolution(for: step.binding)
                let stepModelDetail =
                    "\(step.binding.provider.displayName) — \(stepModel.detailedLabel)"
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
                        row: nextRow(in: runColumn + index + 1),
                        modelLabel: stepModel.label,
                        modelDetailLabel: stepModelDetail
                    ))

                appendEdge(from: priorStepNodeID ?? runNodeID, to: stepNodeID)
                for artifact in step.inputArtifacts {
                    if let producerNodeID = producerByArtifact[artifact] {
                        appendEdge(from: producerNodeID, to: stepNodeID)
                    }
                }
                producerByArtifact[step.handoffArtifact, default: stepNodeID] = stepNodeID
                priorStepNodeID = stepNodeID

                // Ghost nodes from this step's declared `proposes:` list
                // (C8-04) — advisory only, never a run the coordinator has
                // admitted. `Step.proposals` is already capped at 16 by the
                // controller that parsed it; `prefix(16)` here is belt-and-
                // braces against a future producer of this field forgetting
                // that cap.
                for (proposalIndex, proposal) in (step.proposals ?? []).prefix(16).enumerated() {
                    let ghostColumn = runColumn + index + 2
                    let ghostNodeID = "\(stepNodeID)/proposal-\(proposalIndex + 1)"
                    nodes.append(
                        ConductorGraphNode(
                            id: ghostNodeID,
                            kind: .proposedGhost,
                            title: "Proposed",
                            runID: manifest.id,
                            stepIndex: index,
                            provider: step.binding.provider,
                            status: nil,
                            runState: .pending,
                            detail: bounded(proposal, fallback: "Proposal"),
                            column: ghostColumn,
                            row: nextRow(in: ghostColumn),
                            modelLabel: stepModel.label,
                            modelDetailLabel: stepModelDetail
                        ))
                    appendEdge(from: stepNodeID, to: ghostNodeID)
                }
            }

            if let gate = manifest.gate {
                let gateNodeID = "\(runNodeID)/gate"
                let gateColumn = runColumn + manifest.steps.count + 1
                let gateState: EnsembleGraphState =
                    gate.kind == .merge ? .mergeGate : .awaitingGate
                let gateTitle: String =
                    switch gate.kind {
                    case .merge: "Merge gate"
                    case .plan: "Plan gate"
                    case .step: "Step gate"
                    }
                let gateBinding =
                    manifest.steps.indices.contains(gate.stepIndex)
                    ? manifest.steps[gate.stepIndex].binding
                    : manifest.steps.last?.binding
                let provider = gateBinding?.provider
                let gateModel = gateBinding.map(ConductorRunPresentation.modelResolution(for:))
                nodes.append(
                    ConductorGraphNode(
                        id: gateNodeID,
                        kind: .gate,
                        title: gateTitle,
                        runID: manifest.id,
                        stepIndex: gate.stepIndex,
                        provider: provider,
                        status: manifest.steps.indices.contains(gate.stepIndex)
                            ? manifest.steps[gate.stepIndex].status : nil,
                        runState: gateState,
                        detail: gate.kind == .merge
                            ? "Review worktree changes"
                            : gate.kind == .plan
                                ? "Review the proposed plan"
                                : "Review step \(gate.stepIndex + 1)'s artifact",
                        column: gateColumn,
                        row: nextRow(in: gateColumn),
                        modelLabel: gateModel?.label,
                        modelDetailLabel: gateBinding.map {
                            "\($0.provider.displayName) — "
                                + (gateModel?.detailedLabel ?? "")
                        }
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
        // The CLI is the node's provider badge and the model is its own chip,
        // so this line no longer repeats either. It names what the step will
        // actually produce, which nothing else on the card says.
        return "→ \(bounded(step.handoffArtifact, fallback: "handoff artifact"))"
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
