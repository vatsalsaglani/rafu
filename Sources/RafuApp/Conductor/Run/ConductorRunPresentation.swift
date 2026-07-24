import Foundation

/// One run row for `ConductorRunsPanelView` (C5) — pure derivation from
/// `ConductorRunManifest` (+ whatever live workflow state the caller has for
/// the ACTIVE run), no SwiftUI import, so it stays headless-testable exactly
/// like `TerminalSessionRow`/`TerminalSessionPresentation`.
nonisolated struct ConductorRunRowModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let statusSymbol: String
    let statusLabel: String
    let needsAttention: Bool
    let isLive: Bool
    /// `nil` when no gate is currently open for this run.
    let gateBadge: String?
}

/// One step row for `ConductorRunDetailCanvas`'s timeline (C5).
nonisolated struct ConductorStepRowModel: Identifiable, Equatable, Sendable {
    let index: Int
    let agentName: String
    let providerLabel: String
    let modelLabel: String
    let statusSymbol: String
    let statusLabel: String
    /// `nil` before the step has started.
    let durationLabel: String?
    /// `nil` for attempt 1 — only shown once a step has actually been
    /// retried, so a fresh run's timeline carries no attempt noise.
    let attemptLabel: String?
    let isGateReady: Bool
    /// Workspace-root-relative path — what `WorkspaceSession
    /// .openFile(atRelativePath:)` expects, not a run-relative one.
    let artifactRelativePath: String
    let hasLiveTerminal: Bool

    var id: Int { index }
}

/// Derives `ConductorRunRowModel`/`ConductorStepRowModel` from a persisted
/// `ConductorRunManifest`. Every status pairs a SHAPE-distinct SF Symbol with
/// a text label (AGENTS: never color alone), mirroring
/// `TerminalSessionPresentation.symbol(_:)`'s established four-symbol
/// pattern one-for-one with `RunStepStatus`'s six cases.
nonisolated enum ConductorRunPresentation {
    static func symbol(for status: RunStepStatus) -> String {
        switch status {
        case .pending: "circle.dotted"
        case .running: "circle.fill"
        case .awaitingGate: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .aborted: "xmark.circle.fill"
        }
    }

    static func label(for status: RunStepStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .running: "Running"
        case .awaitingGate: "Awaiting gate"
        case .completed: "Completed"
        case .failed(let reason): reason
        case .aborted: "Aborted"
        }
    }

    static func needsAttention(for status: RunStepStatus) -> Bool {
        switch status {
        case .awaitingGate, .failed: true
        case .pending, .running, .completed, .aborted: false
        }
    }

    /// The step index a `ConductorWorkflowState` is currently attributed to,
    /// or `nil` when the run has no single "current" step (idle, preparing,
    /// awaiting the merge gate, or terminal). Mirrors
    /// `ConductorWorkflowController`'s own private `activeStepIndex(in:)`.
    static func liveStepIndex(in state: ConductorWorkflowState) -> Int? {
        switch state {
        case .runningStep(let index), .awaitingArtifact(let index), .awaitingGate(let index):
            index
        case .idle, .preparing, .awaitingMergeGate, .completed, .failed, .aborted:
            nil
        }
    }

    /// One run row. `isLive` is true only when `liveState` is provided and
    /// currently in flight — i.e. this manifest IS the workflow controller's
    /// active run, not merely a historical one with the same last-known
    /// status.
    static func runRow(
        for manifest: ConductorRunManifest,
        liveState: ConductorWorkflowState? = nil
    ) -> ConductorRunRowModel {
        let overallStatus = manifest.steps.last?.status ?? .pending
        let completedCount = manifest.steps.count { $0.status == .completed }
        let branchDescription =
            manifest.worktreeBranch.isEmpty ? "Main workspace" : manifest.worktreeBranch
        let subtitle = "\(completedCount)/\(manifest.steps.count) steps · \(branchDescription)"
        let isLive = liveState.map(isInFlight) ?? false
        return ConductorRunRowModel(
            id: manifest.id,
            title: manifest.workflowName,
            subtitle: subtitle,
            statusSymbol: manifest.gate != nil ? "pause.circle.fill" : symbol(for: overallStatus),
            statusLabel: gateBadge(for: manifest) ?? label(for: overallStatus),
            needsAttention: manifest.gate != nil || needsAttention(for: overallStatus),
            isLive: isLive,
            gateBadge: gateBadge(for: manifest))
    }

    /// Every step row for `manifest`'s timeline. `liveStepIndex` should come
    /// from `liveStepIndex(in:)` applied to the workflow controller's
    /// CURRENT state, and ONLY when that controller's current manifest id
    /// matches `manifest.id` — otherwise pass `nil` for a historical run.
    static func stepRows(
        for manifest: ConductorRunManifest,
        liveStepIndex: Int? = nil
    ) -> [ConductorStepRowModel] {
        manifest.steps.enumerated().map { index, step in
            let attempt = step.attempt ?? 1
            return ConductorStepRowModel(
                index: index,
                agentName: step.agentName,
                providerLabel: step.binding.provider.displayName,
                modelLabel: step.binding.model.isEmpty ? "Adapter default" : step.binding.model,
                statusSymbol: symbol(for: step.status),
                statusLabel: label(for: step.status),
                durationLabel: durationLabel(
                    startedAt: step.startedAt, finishedAt: step.finishedAt),
                attemptLabel: attempt > 1 ? "Attempt \(attempt)" : nil,
                isGateReady: step.status == .awaitingGate,
                artifactRelativePath: artifactRelativePath(runID: manifest.id, step: step),
                hasLiveTerminal: liveStepIndex == index)
        }
    }

    private static func isInFlight(_ state: ConductorWorkflowState) -> Bool {
        switch state {
        case .preparing, .runningStep, .awaitingArtifact, .awaitingGate, .awaitingMergeGate:
            true
        case .idle, .completed, .failed, .aborted:
            false
        }
    }

    private static func gateBadge(for manifest: ConductorRunManifest) -> String? {
        guard let gate = manifest.gate else { return nil }
        return switch gate.kind {
        case .step: "Gate: step \(gate.stepIndex + 1)"
        case .merge: "Merge gate"
        }
    }

    private static func durationLabel(startedAt: Date?, finishedAt: Date?) -> String? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? Date()
        let seconds = max(0, end.timeIntervalSince(startedAt))
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(remainingSeconds)s"
    }

    /// `.rafu/runs/<id>/[<evidencePath>/]handoff/<handoffArtifact>`, relative
    /// to the WORKSPACE ROOT — what `WorkspaceSession
    /// .openFile(atRelativePath:)` expects. `evidencePath` is `nil` for a
    /// C1-flat step (nothing to nest under) and a run-relative
    /// `"steps/NN-slug-aN"` string for a C5 step (`ConductorRunEvidenceLayout
    /// .step`'s exact `stepComponents.joined(separator: "/")` shape).
    private static func artifactRelativePath(
        runID: String, step: ConductorRunManifest.Step
    ) -> String {
        var components = [".rafu", "runs", runID]
        if let evidencePath = step.evidencePath, !evidencePath.isEmpty {
            components.append(contentsOf: evidencePath.split(separator: "/").map(String.init))
        }
        components.append("handoff")
        components.append(contentsOf: step.handoffArtifact.split(separator: "/").map(String.init))
        return components.joined(separator: "/")
    }
}
