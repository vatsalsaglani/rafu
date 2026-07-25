import Foundation
import Testing

@testable import RafuApp

@Test("A persisted running step becomes an explicit interrupted recovery plan")
func runningStepPlansInterruptedRecovery() {
    let manifest = ConductorRecoveryFixtures.manifest(
        statuses: [.completed, .running, .pending])

    let plan = ConductorRunRecoveryService.plan(
        for: manifest, worktreeExists: true)

    #expect(plan.disposition == .interrupted(stepIndices: [1]))
    #expect(
        plan.verbs
            == [
                .retryStep(index: 1),
                .abort,
                .keepWorktree,
            ])
    #expect(plan.note?.contains("process was not restored") == true)
    #expect(plan.verbs.map(\.title) == ["Retry Step", "Abort", "Keep Worktree"])
}

@Test("Read-only interrupted runs omit the inapplicable Keep Worktree verb")
func readOnlyInterruptedRunRecovery() {
    let manifest = ConductorRecoveryFixtures.manifest(
        worktreeBranch: "",
        statuses: [.running])

    let plan = ConductorRunRecoveryService.plan(
        for: manifest, worktreeExists: true)

    #expect(plan.disposition == .interrupted(stepIndices: [0]))
    #expect(plan.verbs == [.retryStep(index: 0), .abort])
}

@Test("A vanished worktree degrades to explicit history before offering retry")
func vanishedWorktreeDegradesToHistory() {
    let manifest = ConductorRecoveryFixtures.manifest(
        statuses: [.completed, .running])

    let plan = ConductorRunRecoveryService.plan(
        for: manifest, worktreeExists: false)

    #expect(plan.disposition == .historyOnly)
    #expect(plan.note?.contains("removed outside Rafu") == true)
    #expect(plan.verbs.isEmpty)
}

@Test("Terminal and user-gated runs need no process recovery")
func terminalRunsRemainUnchanged() {
    for statuses in [
        [RunStepStatus.completed],
        [RunStepStatus.failed("fixture failure")],
        [RunStepStatus.aborted],
        [RunStepStatus.awaitingGate],
        [RunStepStatus.pending],
    ] {
        let plan = ConductorRunRecoveryService.plan(
            for: ConductorRecoveryFixtures.manifest(statuses: statuses),
            worktreeExists: true)
        #expect(plan.disposition == .unchanged)
        #expect(plan.note == nil)
        #expect(plan.verbs.isEmpty)
    }
}

@Test("Recovery scanning uses only the deterministic run worktree locations")
func recoveryScanUsesFixtureWorktreePresence() async {
    let workspaceRoot = URL(fileURLWithPath: "/fixture/repository", isDirectory: true)
    let existingID = "existing-run"
    let expectedURL = ConductorRunRecoveryService.worktreeURL(
        workspaceRoot: workspaceRoot, runID: existingID)
    let service = ConductorRunRecoveryService { url in url == expectedURL }
    let manifests = [
        ConductorRecoveryFixtures.manifest(
            id: existingID,
            worktreeBranch: "rafu/run-\(existingID)",
            statuses: [.running]),
        ConductorRecoveryFixtures.manifest(
            id: "missing-run",
            worktreeBranch: "rafu/run-missing-run",
            statuses: [.completed]),
        ConductorRecoveryFixtures.manifest(
            id: "readonly-run",
            worktreeBranch: "",
            statuses: [.completed]),
    ]

    let plans = await service.plans(for: manifests, workspaceRoot: workspaceRoot)

    #expect(
        plans.map(\.disposition) == [
            .interrupted(stepIndices: [0]),
            .historyOnly,
            .unchanged,
        ])
}
