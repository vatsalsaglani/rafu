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

    static func worktreeURL(workspaceRoot: URL, runID: String) -> URL {
        workspaceRoot.standardizedFileURL
            .appending(path: ".rafu-worktrees", directoryHint: .isDirectory)
            .appending(path: runID, directoryHint: .isDirectory)
    }
}
