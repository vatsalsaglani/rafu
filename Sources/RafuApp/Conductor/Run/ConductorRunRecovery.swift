import Foundation

/// User-visible recovery actions for a process that cannot survive app
/// relaunch. These are deliberately explicit verbs; there is no generic
/// "Resume" action because no child process is resurrected.
nonisolated enum ConductorRunRecoveryVerb: Equatable, Sendable {
    case retryStep(index: Int)
    case abort
    case keepWorktree

    var title: String {
        switch self {
        case .retryStep: "Retry Step"
        case .abort: "Abort"
        case .keepWorktree: "Keep Worktree"
        }
    }
}

/// What the relaunch janitor learned from one persisted run.
nonisolated struct ConductorRunRecoveryPlan: Equatable, Sendable {
    nonisolated enum Disposition: Equatable, Sendable {
        /// No process was in flight and the attributed worktree still has
        /// the expected on-disk location.
        case unchanged
        /// These persisted `.running` steps lost their processes when the
        /// previous app process ended.
        case interrupted(stepIndices: [Int])
        /// The run remains readable evidence, but its externally removed
        /// worktree can no longer participate in merge/retry actions.
        case historyOnly
        /// The app closed while the run was still parked at its plan gate, so
        /// nothing was ever started: no worktree, no agent process, no
        /// evidence. There is no live controller to approve or decline it
        /// after a restart, so it is abandoned truthfully rather than left as
        /// a zombie no human verb and no coordinator verb can reach.
        case abandonedAtPlanGate
    }

    let runID: String
    let disposition: Disposition
    let note: String?
    let verbs: [ConductorRunRecoveryVerb]
}

/// Pure recovery policy plus an injectable, off-main worktree-existence
/// scan. It never probes an adapter and never launches a vendor CLI.
nonisolated struct ConductorRunRecoveryService: Sendable {
    typealias FileExists = @Sendable (URL) -> Bool

    /// The literal note for historical evidence whose run manifest was lost.
    /// Keep it stable: it tells the user both what remains on disk and why no
    /// normal run details or recovery verbs are available.
    static let manifestlessEvidenceNote =
        "Evidence present, manifest missing. This run is available as degraded history."

    private let fileExists: FileExists

    init(
        fileExists: @escaping FileExists = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) {
        self.fileExists = fileExists
    }

    /// File-system work is explicitly offloaded from RafuApp's default main
    /// actor. The result is a value plan; applying it to the manifest belongs
    /// to the run controller's serialized persistence seam.
    @concurrent
    func plans(
        for manifests: [ConductorRunManifest],
        workspaceRoot: URL
    ) async -> [ConductorRunRecoveryPlan] {
        manifests.map { manifest in
            let worktreeExists: Bool
            if manifest.worktreeBranch.isEmpty {
                worktreeExists = true
            } else {
                worktreeExists = fileExists(
                    Self.worktreeURL(workspaceRoot: workspaceRoot, runID: manifest.id))
            }
            return Self.plan(for: manifest, worktreeExists: worktreeExists)
        }
    }

    static func plan(
        for manifest: ConductorRunManifest,
        worktreeExists: Bool
    ) -> ConductorRunRecoveryPlan {
        // Checked BEFORE the worktree probe: a plan-gated run parks before
        // materialization, so a `worktreeWrite` role leaves a non-empty
        // `worktreeBranch` with nothing on disk. That would otherwise fall
        // into `.historyOnly` and claim "the worktree was removed outside
        // Rafu", which is false — it was never created.
        if manifest.gate?.kind == .plan {
            return ConductorRunRecoveryPlan(
                runID: manifest.id,
                disposition: .abandonedAtPlanGate,
                note:
                    "Rafu closed while this run was waiting at its plan gate. Nothing had started, so the run was abandoned. Submit it again to run it.",
                verbs: [])
        }

        if !manifest.worktreeBranch.isEmpty, !worktreeExists {
            return ConductorRunRecoveryPlan(
                runID: manifest.id,
                disposition: .historyOnly,
                note:
                    "The run worktree was removed outside Rafu. The saved run remains available as history.",
                verbs: [])
        }

        let interruptedIndices = manifest.steps.indices.filter { index in
            manifest.steps[index].status == .running
        }
        guard !interruptedIndices.isEmpty else {
            return ConductorRunRecoveryPlan(
                runID: manifest.id,
                disposition: .unchanged,
                note: nil,
                verbs: [])
        }

        var verbs = interruptedIndices.map {
            ConductorRunRecoveryVerb.retryStep(index: $0)
        }
        verbs.append(.abort)
        if !manifest.worktreeBranch.isEmpty {
            verbs.append(.keepWorktree)
        }
        return ConductorRunRecoveryPlan(
            runID: manifest.id,
            disposition: .interrupted(stepIndices: interruptedIndices),
            note:
                "The app closed while this step was running. Its process was not restored.",
            verbs: verbs)
    }

    /// A missing manifest is not repaired or guessed at. This value exists
    /// only in memory so the Runs surface can show the evidence directory and
    /// the explicit degradation note without overwriting the user's disk
    /// state with invented workflow metadata.
    static func manifestlessEvidenceHistory(
        runID: String,
        evidenceDate: Date
    ) -> ConductorRunManifest {
        var manifest = ConductorRunManifest(
            id: runID,
            workflowName: "Recovered evidence",
            baseCommit: "",
            worktreeBranch: "",
            createdAt: evidenceDate,
            updatedAt: evidenceDate,
            steps: [])
        manifest.recoveryNote = manifestlessEvidenceNote
        return manifest
    }

    static func worktreeURL(workspaceRoot: URL, runID: String) -> URL {
        workspaceRoot.standardizedFileURL
            .appending(path: ".rafu-worktrees", directoryHint: .isDirectory)
            .appending(path: runID, directoryHint: .isDirectory)
    }
}
