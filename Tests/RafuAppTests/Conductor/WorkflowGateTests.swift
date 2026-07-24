import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A two-step, all-`readOnly` pipeline with a gate declared after step 0.
private func gatedTwoStepRequest(runID: String) -> ConductorWorkflowRunRequest {
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md"),
        workflowRole(name: "implementor", handoffArtifact: "patch.md"),
    ]
    let workflow = workflowDefinition(
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: true),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
        ])
    return ConductorWorkflowRunRequest(
        workflow: workflow, roles: roles, taskPrompt: "Ship it.", runID: runID)
}

@MainActor
@Test("A declared gate parks the run without auto-advancing")
func gateParksWithoutAutoAdvance() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "gate-run"

    await controller.start(gatedTwoStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == .awaitingGate(index: 0))
    #expect(
        controller.manifest?.gate
            == ConductorRunManifest.Gate(kind: .step, stepIndex: 0))
    #expect(controller.manifest?.steps[0].status == .awaitingGate)
    #expect(launcher.recorded.count == 1)
}

@MainActor
@Test("Approving a gate advances to the next step and clears the gate")
func approveAdvancesAndClearsGate() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "approve-run"

    await controller.start(gatedTwoStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    await controller.approveGate()
    await controller.waitForPendingOperation()

    #expect(controller.state == .runningStep(index: 1))
    #expect(controller.manifest?.gate == nil)
    #expect(controller.manifest?.steps[0].status == .completed)
    #expect(launcher.recorded.count == 2)
}

@MainActor
@Test("A revised artifact — rewritten while parked at the gate — flows forward")
func revisedArtifactFlowsForward() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "revise-run"

    await controller.start(gatedTwoStepRequest(runID: runID), launcher: launcher)
    let artifactURL = root.appending(
        path: ".rafu/runs/\(runID)/steps/01-advisor-a1/handoff/brief.md")
    try FileManager.default.createDirectory(
        at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original".utf8).write(to: artifactURL)
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(controller.state == .awaitingGate(index: 0))

    // Simulate the user revising the artifact in an editor tab, then saving.
    try Data("REVISED CONTENT".utf8).write(to: artifactURL)

    await controller.approveGate()
    await controller.waitForPendingOperation()

    let promptArgument = try #require(launcher.recorded[1].specification.arguments.last)
    #expect(promptArgument.contains(artifactURL.path))
    let currentBytes = try String(contentsOf: artifactURL, encoding: .utf8)
    #expect(currentBytes == "REVISED CONTENT")
}

@MainActor
@Test("Revise opens the parked step's artifact as an editor tab without changing state")
func reviseOpensArtifactWithoutChangingState() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "revise-open-run"

    await controller.start(gatedTwoStepRequest(runID: runID), launcher: launcher)
    let artifactURL = root.appending(
        path: ".rafu/runs/\(runID)/steps/01-advisor-a1/handoff/brief.md")
    try FileManager.default.createDirectory(
        at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original".utf8).write(to: artifactURL)
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: root.lastPathComponent,
        location: .local(LocalWorkspaceReference(path: root.path)))
    controller.reviseArtifact(in: session)

    #expect(controller.state == .awaitingGate(index: 0))
    #expect(session.selectedDocument?.url == artifactURL)
}

@MainActor
@Test("Aborting at a gate parks the run, leaves later steps pending, and keeps evidence")
func abortAtGateLeavesEvidenceIntact() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "abort-gate-run"

    await controller.start(gatedTwoStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(controller.state == .awaitingGate(index: 0))

    controller.abortGate()
    await controller.waitForPendingOperation()

    #expect(controller.state == .aborted)
    #expect(controller.manifest?.steps[1].status == .pending)
    #expect(controller.manifest?.gate == nil)
    #expect(
        FileManager.default.fileExists(
            atPath: root.appending(
                path: ".rafu/runs/\(runID)/steps/01-advisor-a1/handoff/brief.md"
            ).path))
    #expect(launcher.recorded.count == 1)
}

@MainActor
@Test(
    "A worktreeWrite pipeline reaches the merge gate after its last step; an all-readOnly pipeline completes without one"
)
func worktreePipelineReachesMergeGateReadOnlyDoesNot() async throws {
    let writeRoot = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: writeRoot) }
    let (_, writeController) = makeWorkflowController(root: writeRoot)
    let writeLauncher = WorkflowFakeLauncher()
    let writeRunID = "merge-gate-run"
    let writeRoles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md"),
        workflowRole(
            name: "implementor", handoffArtifact: "patch.md", autonomy: .worktreeWrite),
    ]
    let writeWorkflow = workflowDefinition(
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: false),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
        ])
    await writeController.start(
        ConductorWorkflowRunRequest(
            workflow: writeWorkflow, roles: writeRoles, taskPrompt: "Ship it.",
            runID: writeRunID),
        launcher: writeLauncher)
    try writeHandoff(
        root: writeRoot, runID: writeRunID,
        relativePath: "steps/01-advisor-a1/handoff/brief.md")
    writeLauncher.finish(0, exitCode: 0)
    await writeController.waitForPendingOperation()
    try writeHandoff(
        root: writeRoot, runID: writeRunID,
        relativePath: "steps/02-implementor-a1/handoff/patch.md")
    writeLauncher.finish(1, exitCode: 0)
    await writeController.waitForPendingOperation()

    #expect(writeController.state == .awaitingMergeGate)
    #expect(
        writeController.manifest?.gate
            == ConductorRunManifest.Gate(kind: .merge, stepIndex: 1))

    let readRoot = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: readRoot) }
    let (_, readController) = makeWorkflowController(root: readRoot)
    let readLauncher = WorkflowFakeLauncher()
    let readRunID = "no-merge-gate-run"
    await readController.start(threeStepRequest(runID: readRunID), launcher: readLauncher)
    try writeHandoff(
        root: readRoot, runID: readRunID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    readLauncher.finish(0, exitCode: 0)
    await readController.waitForPendingOperation()
    try writeHandoff(
        root: readRoot, runID: readRunID,
        relativePath: "steps/02-implementor-a1/handoff/patch.md")
    readLauncher.finish(1, exitCode: 0)
    await readController.waitForPendingOperation()
    try writeHandoff(
        root: readRoot, runID: readRunID, relativePath: "steps/03-documentor-a1/handoff/docs.md")
    readLauncher.finish(2, exitCode: 0)
    await readController.waitForPendingOperation()

    #expect(readController.state == .completed)
    #expect(readController.manifest?.gate == nil)
}

@MainActor
@Test("Merge-gate verbs apply, keep, and discard mirror C1's single-role semantics")
func mergeGateVerbsMirrorSingleRoleSemantics() async throws {
    // Apply.
    let applyRoot = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: applyRoot) }
    let (_, applyController) = makeWorkflowController(root: applyRoot)
    let applyLauncher = WorkflowFakeLauncher()
    let applyRunID = "apply-run"
    let roles = [
        workflowRole(
            name: "implementor", handoffArtifact: "patch.md", autonomy: .worktreeWrite)
    ]
    let workflow = workflowDefinition(
        steps: [(agentName: "implementor", inputArtifacts: [], gateAfter: false)])
    await applyController.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Implement.", runID: applyRunID),
        launcher: applyLauncher)
    let applyWorktree = try #require(applyController.plan?.worktreeURL)
    try Data("applied\n".utf8).write(to: applyWorktree.appending(path: "fixture.txt"))
    try writeHandoff(
        root: applyRoot, runID: applyRunID, relativePath: "steps/01-implementor-a1/handoff/patch.md"
    )
    applyLauncher.finish(0, exitCode: 0)
    await applyController.waitForPendingOperation()
    #expect(applyController.state == .awaitingMergeGate)

    await applyController.applyToWorkspace()

    #expect(applyController.state == .completed)
    #expect(applyController.hasAppliedToWorkspace)
    #expect(applyController.mergeGateError == nil)
    #expect(
        try String(contentsOf: applyRoot.appending(path: "fixture.txt"), encoding: .utf8)
            == "applied\n")
    #expect(!FileManager.default.fileExists(atPath: applyWorktree.path))

    // Keep.
    let keepRoot = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: keepRoot) }
    let (_, keepController) = makeWorkflowController(root: keepRoot)
    let keepLauncher = WorkflowFakeLauncher()
    let keepRunID = "keep-run"
    await keepController.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Implement.", runID: keepRunID),
        launcher: keepLauncher)
    let keepWorktree = try #require(keepController.plan?.worktreeURL)
    try writeHandoff(
        root: keepRoot, runID: keepRunID, relativePath: "steps/01-implementor-a1/handoff/patch.md"
    )
    keepLauncher.finish(0, exitCode: 0)
    await keepController.waitForPendingOperation()

    await keepController.keepWorktree()

    #expect(keepController.state == .completed)
    #expect(FileManager.default.fileExists(atPath: keepWorktree.path))

    // Discard requires confirmation, then removes.
    let discardRoot = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: discardRoot) }
    let (_, discardController) = makeWorkflowController(root: discardRoot)
    let discardLauncher = WorkflowFakeLauncher()
    let discardRunID = "discard-run"
    await discardController.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Implement.", runID: discardRunID),
        launcher: discardLauncher)
    let discardWorktree = try #require(discardController.plan?.worktreeURL)
    try Data("dirty\n".utf8).write(to: discardWorktree.appending(path: "fixture.txt"))
    try writeHandoff(
        root: discardRoot, runID: discardRunID,
        relativePath: "steps/01-implementor-a1/handoff/patch.md")
    discardLauncher.finish(0, exitCode: 0)
    await discardController.waitForPendingOperation()

    let unconfirmed = await discardController.discardWorktree(confirmedDirty: false)
    #expect(unconfirmed == .confirmationRequired)
    #expect(discardController.state == .awaitingMergeGate)
    #expect(FileManager.default.fileExists(atPath: discardWorktree.path))

    let confirmed = await discardController.discardWorktree(confirmedDirty: true)
    #expect(confirmed == .removed)
    #expect(discardController.state == .completed)
    #expect(!FileManager.default.fileExists(atPath: discardWorktree.path))
}

@MainActor
@Test("Two back-to-back approveGate() calls never launch a step twice (D1 regression)")
func approveGateNeverDoubleLaunches() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "double-approve-run"

    await controller.start(gatedTwoStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(controller.state == .awaitingGate(index: 0))

    // Fire two approvals back-to-back. Both start on the MainActor, so the
    // FIRST call's synchronous prefix (mutate manifest, publish, mint a
    // fresh generation, leave `.awaitingGate`) runs to completion before
    // either call can hit its first `await` — the second call must then see
    // the FSM guard (and the menu/palette predicates that key on the same
    // `state`) already false, never racing past it into a second launch.
    async let first: Void = controller.approveGate()
    async let second: Void = controller.approveGate()
    _ = await (first, second)
    await controller.waitForPendingOperation()

    #expect(launcher.recorded.count == 2)
    #expect(controller.state == .runningStep(index: 1))
    #expect(controller.manifest?.steps[0].status == .completed)
}

@MainActor
@Test("An all-readOnly pipeline completes with no merge gate; the merge verbs stay unreachable")
func allReadOnlyPipelineCompletesWithNoMergeGateAndVerbsUnreachable() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "readonly-only-run"
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md", autonomy: .readOnly),
        workflowRole(name: "implementor", handoffArtifact: "patch.md", autonomy: .readOnly),
    ]
    let workflow = workflowDefinition(
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: false),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
        ])
    await controller.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Review.", runID: runID),
        launcher: launcher)
    #expect(controller.plan?.worktreeURL == nil)

    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/02-implementor-a1/handoff/patch.md")
    launcher.finish(1, exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == .completed)
    #expect(controller.manifest?.gate == nil)

    // The merge-gate verbs all guard on `state == .awaitingMergeGate`, which
    // an all-readOnly pipeline never reaches — every one must be a no-op.
    await controller.applyToWorkspace()
    #expect(controller.state == .completed)
    #expect(!controller.hasAppliedToWorkspace)

    await controller.keepWorktree()
    #expect(controller.state == .completed)

    let discardResult = await controller.discardWorktree(confirmedDirty: false)
    #expect(discardResult == nil)
    #expect(controller.state == .completed)
}

@Test("A C1-era manifest with no gate or attempt keys decodes")
func c1EraManifestDecodesWithoutGateOrAttemptKeys() throws {
    let json = """
        {
          "id": "c1-run",
          "workflowName": "advisor",
          "baseCommit": "0123456789012345678901234567890123456789",
          "worktreeBranch": "",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "steps": [
            {
              "agentName": "advisor",
              "binding": {
                "provider": "claudeCode",
                "model": "fake-fast",
                "autonomy": "readOnly",
                "adapterVersion": "fake-1.0"
              },
              "inputArtifacts": [],
              "handoffArtifact": "brief.md",
              "gateAfter": true,
              "status": {"state": "completed"}
            }
          ]
        }
        """
    let manifest = try ConductorRunStore.makeDecoder().decode(
        ConductorRunManifest.self, from: Data(json.utf8))

    #expect(manifest.gate == nil)
    #expect(manifest.steps[0].attempt == nil)
    #expect(manifest.steps[0].evidencePath == nil)
    #expect(manifest.steps[0].status == .completed)
}
