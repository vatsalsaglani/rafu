import Foundation
import Testing

@testable import RafuApp

/// C8-04: `run --plan-gate` parks a fully validated run before ANYTHING
/// spawns; Approve re-parses the workflow/agent files at approval time
/// (hand-edited files win, a parse failure keeps the park); Request Changes
/// aborts with a bounded note; a plan gate is never remotely approvable.
@Suite("Plan gate")
struct PlanGateTests {
    @MainActor
    @Test("run --plan-gate parks a validated run before anything spawns")
    func planGateParksBeforeAnythingSpawns() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, controller) = makeWorkflowController(root: root)
        var events: [ConductorGateReadyEvent] = []
        controller.onGateReady = { events.append($0) }
        let launcher = WorkflowFakeLauncher()
        let runID = "plan-gate-zero-spawn"

        let workflow = workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)])
        var request = ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: [
                workflowRole(name: "worker", handoffArtifact: "result.md", autonomy: .worktreeWrite)
            ],
            taskPrompt: "Ship it.",
            runID: runID)
        request.planGateRequested = true

        await controller.start(request, launcher: launcher)

        #expect(controller.state == .awaitingPlanGate)
        #expect(controller.manifest?.gate == ConductorRunManifest.Gate(kind: .plan, stepIndex: 0))
        #expect(controller.manifest?.steps.allSatisfy { $0.status == .pending } == true)

        // The hard constraint: NOTHING spawned. No launcher call at all, and
        // the worktree `plan()` merely computed the intended path — it did
        // not create it (`materialize()` never ran).
        #expect(launcher.recorded.isEmpty)
        let worktreeURL = try #require(controller.plan?.worktreeURL)
        #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))

        let event = try #require(events.first)
        #expect(event.kind == .plan)
        #expect(event.stepIndex == 0)
        #expect(!event.safeToApproveRemotely)
    }

    @MainActor
    @Test("Approve re-parses the workflow file: a hand-edit between park and approve wins")
    func approvalRereadsHandEditedFiles() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userLibraryRoot = root.appending(
            path: "empty-user-library", directoryHint: .isDirectory)
        let (_, controller) = makePlanGateController(root: root, userLibraryRoot: userLibraryRoot)
        let launcher = WorkflowFakeLauncher()
        let runID = "plan-gate-reparse"

        try writePlanGateAgent(root: root, name: "worker", handoffArtifact: "report.md")
        try writePlanGateAgent(root: root, name: "reviewer", handoffArtifact: "notes.md")
        try writePlanGateWorkflow(root: root, steps: ["worker"])

        // Park with the ORIGINAL 1-step workflow.
        var request = ConductorWorkflowRunRequest(
            workflow: workflowDefinition(
                name: "pipeline",
                steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
            roles: [workflowRole(name: "worker", handoffArtifact: "report.md")],
            taskPrompt: "Ship it.",
            runID: runID)
        request.planGateRequested = true
        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)

        // Hand-edit at the gate: two steps, in a DIFFERENT order — proves
        // this is a real re-read, not the stale parked parse.
        try writePlanGateWorkflow(root: root, steps: ["reviewer", "worker"])

        await controller.approvePlanGate()

        #expect(controller.planGateIssue == nil)
        #expect(controller.manifest?.steps.count == 2)
        #expect(controller.manifest?.steps.map(\.agentName) == ["reviewer", "worker"])
        #expect(controller.state == .runningStep(index: 0))
        #expect(launcher.recorded.count == 1)
    }

    @MainActor
    @Test("A parse failure at approve time keeps the park and never falls back to the stale parse")
    func parseFailureKeepsThePark() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userLibraryRoot = root.appending(
            path: "empty-user-library", directoryHint: .isDirectory)
        let (_, controller) = makePlanGateController(root: root, userLibraryRoot: userLibraryRoot)
        let launcher = WorkflowFakeLauncher()
        let runID = "plan-gate-parse-failure"

        try writePlanGateAgent(root: root, name: "worker", handoffArtifact: "report.md")
        try writePlanGateWorkflow(root: root, steps: ["worker"])

        var request = ConductorWorkflowRunRequest(
            workflow: workflowDefinition(
                name: "pipeline",
                steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
            roles: [workflowRole(name: "worker", handoffArtifact: "report.md")],
            taskPrompt: "Ship it.",
            runID: runID)
        request.planGateRequested = true
        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)

        // Break the frontmatter entirely.
        let dot = RafuDotDirectory(workspaceRoot: root)
        try Data("this is not a frontmatter file at all".utf8)
            .write(to: dot.workflowsURL.appending(path: "pipeline.md"), options: .atomic)

        await controller.approvePlanGate()

        #expect(controller.state == .awaitingPlanGate)
        #expect(controller.planGateIssue != nil)
        #expect(controller.manifest?.gate?.kind == .plan)
        #expect(launcher.recorded.isEmpty)
    }

    @MainActor
    @Test("Decline aborts with a bounded note and never launches anything")
    func declineAbortsWithBoundedNote() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, controller) = makeWorkflowController(root: root)
        let launcher = WorkflowFakeLauncher()
        let runID = "plan-gate-decline"

        var request = threeStepRequest(runID: runID)
        request.planGateRequested = true
        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)

        let cursorBefore = ConductorEnsembleEventCenter.shared.cursor
        controller.declinePlanGate(note: String(repeating: "x", count: 1_500))

        #expect(controller.state == .aborted)
        #expect(controller.manifest?.recoveryNote?.count == 1_000)
        // Every step is marked `.aborted` — none of them ran, but the
        // manifest itself must carry a signal `ConductorEnsembleState
        // Projection.runState` can actually derive `.aborted` from (it has
        // no live-state parameter at publish time), otherwise the decline
        // would be invisible to `status`/events.
        #expect(controller.manifest?.steps.allSatisfy { $0.status == .aborted } == true)
        #expect(launcher.recorded.isEmpty)

        let events = ConductorEnsembleEventCenter.shared.eventsSince(cursorBefore)
        #expect(events.contains { $0.runID == runID && $0.state == .aborted })
    }

    @MainActor
    @Test("Abort at a parked plan gate is observable to an awaiting coordinator")
    func abortAtPlanGateIsObservable() async throws {
        // The human can click "Abort Run" instead of "Request Changes" on a
        // parked plan gate. That path goes through `markAborted()`, not
        // `declinePlanGate`, and `activeStepIndex` returns nil for
        // `.awaitingPlanGate` — so before this regression the manifest
        // published with every step still `.pending` and the abort projected
        // as `.pending` forever, blocking `await <run> --state aborted`.
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, controller) = makeWorkflowController(root: root)
        let launcher = WorkflowFakeLauncher()
        let runID = "plan-gate-abort"

        var request = threeStepRequest(runID: runID)
        request.planGateRequested = true
        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)

        let cursorBefore = ConductorEnsembleEventCenter.shared.cursor
        controller.abort()

        #expect(controller.state == .aborted)
        #expect(controller.manifest?.gate == nil)
        #expect(controller.manifest?.steps.allSatisfy { $0.status == .aborted } == true)
        #expect(launcher.recorded.isEmpty)

        let events = ConductorEnsembleEventCenter.shared.eventsSince(cursorBefore)
        #expect(events.contains { $0.runID == runID && $0.state == .aborted })
    }

    @MainActor
    @Test("A plan gate parked across a restart is abandoned truthfully, not left a zombie")
    func planGateAcrossRestartIsAbandoned() async throws {
        // A plan gate parks BEFORE materialization, so a worktreeWrite role
        // leaves a non-empty `worktreeBranch` with nothing on disk. Without
        // the plan-gate check that fell into `.historyOnly`, whose note
        // ("removed outside Rafu") is false, and the run then had no live
        // controller, no human verb, and no coordinator verb — a zombie.
        // The manifest comes from a REAL parked controller so the fixture
        // cannot drift from what parking actually persists.
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, controller) = makeWorkflowController(root: root)
        let launcher = WorkflowFakeLauncher()

        var request = threeStepRequest(runID: "plan-gate-restart")
        request.planGateRequested = true
        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)
        let manifest = try #require(controller.manifest)
        #expect(manifest.gate?.kind == .plan)

        let plan = ConductorRunRecoveryService.plan(for: manifest, worktreeExists: false)

        #expect(plan.disposition == .abandonedAtPlanGate)
        #expect(plan.verbs.isEmpty)
        let note = try #require(plan.note)
        #expect(note.contains("plan gate"))
        // The false claim the old `.historyOnly` path would have made.
        #expect(!note.contains("removed outside Rafu"))
    }

    @MainActor
    @Test("A plan gate is never remotely approvable, whatever any step declares")
    func planGateIsNeverRemotelyApprovable() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        // installGateAttentionRig (mirrors WorkflowPresentationTests') keeps
        // `raiseConductorGateAttention`'s FULL path — including the
        // notification leg — reachable and headless-safe: `.both` matches
        // the real app default, and the spies absorb what would otherwise
        // construct the real, bundle-requiring `UNUserNotificationCenter`
        // (`SystemTerminalAttentionNotifier`'s own doc comment: "a raw
        // SwiftPM binary or the `swift test` bundle has no bundle identity,
        // and `UNUserNotificationCenter.current()` against one is known to
        // fail or trap").
        let rig = installGateAttentionRig(on: session, surface: .both)
        defer {
            UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName)
        }
        session.conductorRunController.attach(workspaceRoot: root)
        let controller = session.conductorWorkflowController
        controller.attach(workspaceRoot: root)
        TerminalAttentionCenter.shared.register(session)
        defer { TerminalAttentionCenter.shared.unregister(session) }

        let workflow = ConductorWorkflowDefinition(
            name: "pipeline",
            steps: [
                ConductorWorkflowDefinition.Step(
                    agentName: "worker", inputArtifacts: [], gateAfter: false,
                    safeToApproveRemotely: true)
            ])
        let launcher = WorkflowFakeLauncher()
        var request = ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: [workflowRole(name: "worker", handoffArtifact: "result.md")],
            taskPrompt: "Ship it.",
            runID: "plan-gate-remote")
        request.planGateRequested = true

        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)
        #expect(session.conductorRuns.contains { $0.id == "plan-gate-remote" })

        // The notification layer's own re-check: `approveEnsembleGate` only
        // ever matches `case .awaitingGate` — structurally impossible for a
        // parked plan gate, with ZERO edits to `TerminalAttentionCenter`.
        TerminalAttentionCenter.shared.approveEnsembleGate(runID: "plan-gate-remote")
        #expect(controller.state == .awaitingPlanGate)

        // The gate DID raise attention through the real notification leg —
        // proving `propose-merge`-style re-raises are headless-safe, not
        // just that a crash was dodged by turning surfaces off. The
        // notifier's Task is fire-and-forget, so poll briefly rather than
        // assume it already ran (mirrors WorkflowPresentationTests').
        for _ in 0..<20_000 {
            if rig.notifier.posted.count >= 1 { break }
            await Task.yield()
        }
        #expect(rig.hud.shown.count == 1)
        #expect(rig.notifier.posted.count == 1)
        // Even though the workflow step itself opted in to remote approval,
        // the notification never offers Approve for a plan gate.
        #expect(
            rig.notifier.posted.first?.kind
                == .ensembleGate(runID: "plan-gate-remote", allowsApprove: false))
    }

    @MainActor
    @Test("approveGate() forwards to approvePlanGate() while parked at a plan gate")
    func approveGateForwardsToApprovePlanGate() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userLibraryRoot = root.appending(
            path: "empty-user-library", directoryHint: .isDirectory)
        let (_, controller) = makePlanGateController(root: root, userLibraryRoot: userLibraryRoot)
        let launcher = WorkflowFakeLauncher()
        let runID = "plan-gate-forward"

        try writePlanGateAgent(root: root, name: "worker", handoffArtifact: "report.md")
        try writePlanGateWorkflow(root: root, steps: ["worker"])

        var request = ConductorWorkflowRunRequest(
            workflow: workflowDefinition(
                name: "pipeline",
                steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
            roles: [workflowRole(name: "worker", handoffArtifact: "report.md")],
            taskPrompt: "Ship it.",
            runID: runID)
        request.planGateRequested = true
        await controller.start(request, launcher: launcher)
        #expect(controller.state == .awaitingPlanGate)

        await controller.approveGate()

        #expect(controller.state == .runningStep(index: 0))
        #expect(launcher.recorded.count == 1)
    }
}

@MainActor
private func makePlanGateController(
    root: URL,
    userLibraryRoot: URL
) -> (runsPublisher: ConductorRunController, controller: ConductorWorkflowController) {
    let runsPublisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    runsPublisher.attach(workspaceRoot: root)
    let library = ConductorDefinitionLibrary(
        adapters: [FakeConductorAdapter(id: .claudeCode)],
        enableStore: ConductorEnableStore(suiteName: "PlanGateTests-\(UUID().uuidString)")
    )
    let controller = ConductorWorkflowController(
        runsPublisher: runsPublisher,
        adapters: [FakeConductorAdapter(id: .claudeCode)],
        definitionLibrary: library,
        userLibraryRoot: { userLibraryRoot }
    )
    controller.attach(workspaceRoot: root)
    return (runsPublisher, controller)
}

private func writePlanGateWorkflow(
    root: URL,
    workflowName: String = "pipeline",
    steps: [String]
) throws {
    let dot = RafuDotDirectory(workspaceRoot: root)
    try FileManager.default.createDirectory(
        at: dot.workflowsURL, withIntermediateDirectories: true)
    let stepLines = steps.map { "  - \($0)" }.joined(separator: "\n")
    try Data(
        """
        ---
        name: \(workflowName)
        steps:
        \(stepLines)
        ---
        """.utf8
    ).write(
        to: dot.workflowsURL.appending(path: "\(workflowName).md"), options: .atomic)
}

private func writePlanGateAgent(
    root: URL,
    name: String,
    handoffArtifact: String
) throws {
    let dot = RafuDotDirectory(workspaceRoot: root)
    try FileManager.default.createDirectory(at: dot.agentsURL, withIntermediateDirectories: true)
    try Data(
        """
        ---
        name: \(name)
        provider: claudeCode
        model: fake-fast
        autonomy: readOnly
        handoffArtifact: \(handoffArtifact)
        ---
        Do the work.
        """.utf8
    ).write(to: dot.agentsURL.appending(path: "\(name).md"), options: .atomic)
}

// MARK: - Headless attention rig

// Mirrors `WorkflowPresentationTests.installGateAttentionRig` — duplicated
// rather than shared because that helper is file-private. `.both` matches
// the real app default and keeps `raiseConductorGateAttention`'s FULL path
// (HUD + notification) reachable and asserted against, while the spies
// prevent the concrete `SystemTerminalAttentionNotifier` from ever
// constructing `UNUserNotificationCenter` — which requires a real, signed
// app bundle `swift test` does not have and traps without one.

@MainActor
private final class PlanGateAttentionSpyNotifier: TerminalAttentionNotifying {
    private(set) var posted: [TerminalAttentionNotification] = []

    func requestAuthorizationIfNeeded() async -> Bool { true }

    func post(_ notification: TerminalAttentionNotification) {
        posted.append(notification)
    }
}

@MainActor
private final class PlanGateAttentionSpyHUD: NotchHUDPresenting {
    private(set) var shown: [NotchHUDEvent] = []

    func show(_ event: NotchHUDEvent, theme: RafuTheme) {
        shown.append(event)
    }

    func attentionCleared(for sessionID: UUID) {}
}

@MainActor
private func installGateAttentionRig(
    on session: WorkspaceSession,
    surface: TerminalAttentionSurface
) -> (notifier: PlanGateAttentionSpyNotifier, hud: PlanGateAttentionSpyHUD, suiteName: String) {
    let suiteName = "PlanGateTests.\(UUID().uuidString)"
    let store = TerminalAttentionSurfaceStore(suiteName: suiteName)
    store.setSurface(surface)
    session.terminalAttentionSurfaceStore = store
    let notifier = PlanGateAttentionSpyNotifier()
    session.attentionNotifier = notifier
    let hud = PlanGateAttentionSpyHUD()
    session.attentionHUD = hud
    session.hudThemeProvider = { RafuThemeCatalog.indigo }
    return (notifier, hud, suiteName)
}
