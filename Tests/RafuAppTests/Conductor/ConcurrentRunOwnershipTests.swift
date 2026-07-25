import Foundation
import Testing

@testable import RafuApp

/// Local to this file: `LibraryLaunchTests` keeps its own `oneStepRequest`
/// file-private, and widening another phase's test helper is worse than a
/// three-line duplicate.
private func ownershipRequest(runID: String) -> ConductorWorkflowRunRequest {
    ConductorWorkflowRunRequest(
        workflow: workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
        roles: [workflowRole(name: "worker", handoffArtifact: "result.md", autonomy: .readOnly)],
        taskPrompt: "Perform the task.",
        runID: runID)
}

/// Handoff 1 (C6 → coordinator): `WorkspaceSession` owns a bounded pool of
/// pipeline engines, and every gate/abort/retry/reveal verb resolves the engine
/// that owns the SELECTED run. Before this seam the GUI drove one singular
/// controller, so C6's concurrency was unreachable and a verb could act on the
/// wrong run.
@MainActor
@Test("A session resolves the concurrent-pool engine that owns a run id")
func sessionResolvesConcurrentPoolOwner() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession()
    session.conductorRunController.attach(workspaceRoot: root)
    session.conductorConcurrentRuns.attach(workspaceRoot: root)

    let controller = try await session.conductorConcurrentRuns.start(
        ownershipRequest(runID: "owned-run"),
        launcher: WorkflowFakeLauncher())

    #expect(session.workflowController(forRunID: "owned-run") === controller)
    // Resolution is per-run, not "whatever ran last": an id nothing owns must
    // resolve to nil so the UI shows no verbs rather than acting on another run.
    #expect(session.workflowController(forRunID: "never-started") == nil)
    #expect(session.workflowController(forRunID: nil) == nil)

    session.selectedConductorRunID = "owned-run"
    #expect(session.selectedWorkflowController === controller)

    controller.abort()
}

@MainActor
@Test("New Run stays available while runs are in flight until the window cap")
func newRunGuardIsCapAwareNotBusyAware() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession()
    session.conductorRunController.attach(workspaceRoot: root)
    session.conductorConcurrentRuns.attach(workspaceRoot: root)

    #expect(session.canStartConductorWorkflowRun)

    // The pre-C6 guard was `!isInFlight`, which would go false here and keep
    // concurrency permanently unreachable through the GUI.
    for index in 1..<session.conductorConcurrentRuns.activeLimit {
        _ = try await session.conductorConcurrentRuns.start(
            ownershipRequest(runID: "cap-\(index)"),
            launcher: WorkflowFakeLauncher())
        #expect(session.canStartConductorWorkflowRun)
    }

    _ = try await session.conductorConcurrentRuns.start(
        ownershipRequest(runID: "cap-limit"),
        launcher: WorkflowFakeLauncher())
    #expect(session.conductorConcurrentRuns.activeCount == 3)
    #expect(!session.canStartConductorWorkflowRun)

    for controller in session.conductorConcurrentRuns.controllers {
        controller.abort()
    }
}

@MainActor
@Test("A gate in a concurrent run raises attention through the session")
func concurrentRunGateRaisesAttention() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession()
    session.conductorConcurrentRuns.attach(workspaceRoot: root)

    // The coordinator creates its controllers internally, so without the
    // forwarding hook a concurrent run's gate would be silent while the
    // singular controller's gate still notified.
    var observed: [ConductorGateReadyEvent] = []
    session.conductorConcurrentRuns.onGateReady = { event in
        observed.append(event)
    }
    let controller = try await session.conductorConcurrentRuns.start(
        ownershipRequest(runID: "gate-attention"),
        launcher: WorkflowFakeLauncher())
    controller.onGateReady?(
        ConductorGateReadyEvent(
            runID: "gate-attention",
            kind: .step,
            stepIndex: 0,
            workflowName: "pipeline",
            agentName: "advisor",
            safeToApproveRemotely: false))

    #expect(observed.count == 1)
    #expect(observed.first?.workflowName == "pipeline")
    #expect(observed.first?.agentName == "advisor")
    #expect(observed.first?.runID == "gate-attention")

    controller.abort()
}
