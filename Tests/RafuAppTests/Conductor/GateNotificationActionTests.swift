import Foundation
import Testing

@testable import RafuApp

/// Handoff 4 (C7 → coordinator): gate notifications had no actions and the
/// companion tile was not mutually exclusive with the notch drop-down. These
/// cover the `[gate:remote]` grammar, the typed event, and which action set a
/// gate is allowed to offer.
@Test("The workflow grammar accepts an opt-in remote-approval gate")
func remoteGateMarkerParses() throws {
    let text = """
        ---
        name: Ship a change
        steps:
          - advisor [gate:remote]
          - implementor <- brief.md [gate]
          - documentor
        ---
        """
    let workflow = try ConductorWorkflowFileParser.parse(text, defaultName: "ship")

    #expect(workflow.steps.count == 3)
    // Opt-in: only the step that asked for it is remotely approvable.
    #expect(workflow.steps[0].gateAfter)
    #expect(workflow.steps[0].safeToApproveRemotely)
    #expect(workflow.steps[0].agentName == "advisor")
    // A plain `[gate]` is still a gate, but NOT remotely approvable.
    #expect(workflow.steps[1].gateAfter)
    #expect(!workflow.steps[1].safeToApproveRemotely)
    #expect(workflow.steps[1].inputArtifacts == ["brief.md"])
    // No marker at all: no gate, and certainly no remote approval.
    #expect(!workflow.steps[2].gateAfter)
    #expect(!workflow.steps[2].safeToApproveRemotely)
}

@Test("A remote marker written in the wrong position is rejected, not absorbed into the name")
func misplacedRemoteGateMarkerThrows() {
    let text = """
        ---
        name: Broken
        steps:
          - advisor [gate:remote] <- brief.md
        ---
        """
    #expect(throws: (any Error).self) {
        _ = try ConductorWorkflowFileParser.parse(text, defaultName: "broken")
    }
}

@MainActor
@Test("A remote-marked step gate offers Approve; a plain gate offers only Open Run")
func gateEventCarriesRemoteApprovalOnlyWhenOptedIn() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Two steps: the first opted in to remote approval, the second did not.
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md"),
        workflowRole(name: "implementor", handoffArtifact: "patch.md"),
    ]
    let workflow = ConductorWorkflowDefinition(
        name: "pipeline",
        steps: [
            ConductorWorkflowDefinition.Step(
                agentName: "advisor", inputArtifacts: [], gateAfter: true,
                safeToApproveRemotely: true),
            ConductorWorkflowDefinition.Step(
                agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: true,
                safeToApproveRemotely: false),
        ])
    let (_, controller) = makeWorkflowController(root: root)
    var events: [ConductorGateReadyEvent] = []
    controller.onGateReady = { events.append($0) }
    let launcher = WorkflowFakeLauncher()

    await controller.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Ship it.", runID: "remote-gate"),
        launcher: launcher)
    try writeHandoff(
        root: root, runID: "remote-gate", relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    let first = try #require(events.first)
    #expect(first.kind == .step)
    #expect(first.stepIndex == 0)
    #expect(first.runID == "remote-gate")
    #expect(first.safeToApproveRemotely)
    // Snapshotted into the manifest, so editing the workflow file later cannot
    // retroactively make this open gate remotely approvable.
    #expect(controller.manifest?.steps[0].safeToApproveRemotely == true)
    #expect(controller.manifest?.steps[1].safeToApproveRemotely == false)

    await controller.approveGate()
    try writeHandoff(
        root: root, runID: "remote-gate", relativePath: "steps/02-implementor-a1/handoff/patch.md")
    launcher.finish(1, exitCode: 0)
    await controller.waitForPendingOperation()

    // The second gate is a plain one: no Approve action may be offered.
    let second = try #require(events.last)
    #expect(second.stepIndex == 1)
    #expect(!second.safeToApproveRemotely)

    controller.abort()
}

@MainActor
@Test("A merge gate is never remotely approvable, whatever its step declared")
func mergeGateIsNeverRemotelyApprovable() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Mutating pipeline whose only step opted in to remote approval — the
    // terminal MERGE gate must still refuse, because applying a diff to the
    // user's workspace is not something a workflow file can pre-authorize.
    let workflow = ConductorWorkflowDefinition(
        name: "pipeline",
        steps: [
            ConductorWorkflowDefinition.Step(
                agentName: "worker", inputArtifacts: [], gateAfter: false,
                safeToApproveRemotely: true)
        ])
    let (_, controller) = makeWorkflowController(root: root)
    var events: [ConductorGateReadyEvent] = []
    controller.onGateReady = { events.append($0) }
    let launcher = WorkflowFakeLauncher()

    await controller.start(
        ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: [
                workflowRole(
                    name: "worker", handoffArtifact: "result.md", autonomy: .worktreeWrite)
            ],
            taskPrompt: "Ship it.",
            runID: "merge-remote"),
        launcher: launcher)
    try writeHandoff(
        root: root, runID: "merge-remote", relativePath: "steps/01-worker-a1/handoff/result.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == ConductorWorkflowState.awaitingMergeGate)
    let mergeEvent = try #require(events.last)
    #expect(mergeEvent.kind == .merge)
    #expect(!mergeEvent.safeToApproveRemotely)
}

@Test("A gate notification carries the run id and its allowed action set")
func gateNotificationKindCarriesRunAndApproval() {
    let approvable = TerminalAttentionNotification(
        sessionID: UUID(),
        title: "Ship a change",
        body: "Advisor is ready for review.",
        kind: .ensembleGate(runID: "run-9", allowsApprove: true))
    #expect(approvable.kind == .ensembleGate(runID: "run-9", allowsApprove: true))

    // A terminal bell keeps the default kind, so its Reply category is
    // unchanged by this work.
    let bell = TerminalAttentionNotification(
        sessionID: UUID(), title: "Terminal 1", body: "done")
    #expect(bell.kind == .terminalReply)
}
