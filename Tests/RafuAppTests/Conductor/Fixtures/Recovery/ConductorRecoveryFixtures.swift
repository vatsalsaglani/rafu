import Foundation

@testable import RafuApp

enum ConductorRecoveryFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func manifest(
        id: String = "recovery-run",
        worktreeBranch: String = "rafu/run-recovery-run",
        statuses: [RunStepStatus]
    ) -> ConductorRunManifest {
        ConductorRunManifest(
            id: id,
            workflowName: "Review and implement",
            baseCommit: "0123456789abcdef",
            worktreeBranch: worktreeBranch,
            createdAt: date,
            updatedAt: date,
            steps: statuses.enumerated().map { index, status in
                ConductorRunManifest.Step(
                    agentName: index == 0 ? "advisor" : "implementor",
                    binding: ConductorRunManifest.AgentBinding(
                        provider: index == 0 ? .claudeCode : .codex,
                        model: "",
                        autonomy: worktreeBranch.isEmpty ? .readOnly : .worktreeWrite,
                        adapterVersion: "fixture"),
                    inputArtifacts: [],
                    handoffArtifact: "step-\(index + 1).md",
                    gateAfter: false,
                    status: status,
                    startedAt: status == .pending ? nil : date,
                    finishedAt: nil,
                    attempt: 1,
                    evidencePath: "steps/0\(index + 1)-fixture-a1")
            })
    }
}
