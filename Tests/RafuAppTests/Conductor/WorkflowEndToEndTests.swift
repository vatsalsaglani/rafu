import Foundation
import Testing

@testable import RafuApp

/// The C5 exit-criteria fixture pipeline (`docs/plans/phases/conductor/
/// C5-pipelines.md`): three fake roles, gates after steps 1 and 2, a shared
/// `worktreeWrite` worktree, artifacts written by the test between exits (one
/// of them revised while parked at its gate), ending at the terminal merge
/// gate — resolved with Apply. Runs entirely against `FakeConductorAdapter`
/// and `WorkflowFakeLauncher`: no real vendor CLI, no real PTY.
@MainActor
@Test(
    "The fixture pipeline runs headlessly end to end: two step gates, a revised artifact, the merge gate, and a no-auto-commit Apply"
)
func fixturePipelineRunsEndToEndToMergeGate() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (runsPublisher, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "e2e-run"

    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md", autonomy: .readOnly),
        workflowRole(name: "implementor", handoffArtifact: "patch.md", autonomy: .worktreeWrite),
        workflowRole(name: "documentor", handoffArtifact: "docs.md", autonomy: .worktreeWrite),
    ]
    let workflow = workflowDefinition(
        name: "Ship a change",
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: true),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: true),
            (agentName: "documentor", inputArtifacts: ["patch.md"], gateAfter: false),
        ])
    let request = ConductorWorkflowRunRequest(
        workflow: workflow, roles: roles, taskPrompt: "Ship the change end to end.", runID: runID)

    var observedStates: [ConductorWorkflowState] = []

    // Step 0 (advisor, readOnly): launches, exits clean with its artifact.
    await controller.start(request, launcher: launcher)
    observedStates.append(controller.state)
    #expect(controller.state == .runningStep(index: 0))
    #expect(launcher.recorded.count == 1)

    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    observedStates.append(controller.state)
    #expect(controller.state == .awaitingGate(index: 0))
    #expect(controller.manifest?.gate == ConductorRunManifest.Gate(kind: .step, stepIndex: 0))

    // Gate 1: approve without revising.
    await controller.approveGate()
    await controller.waitForPendingOperation()
    observedStates.append(controller.state)
    #expect(controller.state == .runningStep(index: 1))
    #expect(launcher.recorded.count == 2)
    #expect(controller.manifest?.gate == nil)

    // Step 1 (implementor, worktreeWrite): makes a real worktree edit,
    // writes its handoff artifact, exits clean.
    let plan = try #require(controller.plan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("implemented\n".utf8).write(to: worktreeURL.appending(path: "fixture.txt"))
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/02-implementor-a1/handoff/patch.md")
    launcher.finish(1, exitCode: 0)
    await controller.waitForPendingOperation()
    observedStates.append(controller.state)
    #expect(controller.state == .awaitingGate(index: 1))
    #expect(controller.manifest?.gate == ConductorRunManifest.Gate(kind: .step, stepIndex: 1))

    // Gate 2: revise the artifact BEFORE approving — the revised bytes must
    // flow forward to step 2 (documentor), by reference, at ITS launch time.
    let patchURL = root.appending(
        path: ".rafu/runs/\(runID)/steps/02-implementor-a1/handoff/patch.md")
    try Data("REVISED PATCH NOTES".utf8).write(to: patchURL)

    await controller.approveGate()
    await controller.waitForPendingOperation()
    observedStates.append(controller.state)
    #expect(controller.state == .runningStep(index: 2))
    #expect(launcher.recorded.count == 3)
    let documentorPrompt = try #require(launcher.recorded[2].specification.arguments.last)
    #expect(documentorPrompt.contains(patchURL.path))
    #expect(try String(contentsOf: patchURL, encoding: .utf8) == "REVISED PATCH NOTES")

    // Step 2 (documentor, worktreeWrite, no gate): amends docs in the same
    // worktree, exits clean — the pipeline has no more steps and a worktree
    // exists, so it must land at the terminal merge gate, never .completed.
    try Data("docs\n".utf8).write(to: worktreeURL.appending(path: "readme.txt"))
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/03-documentor-a1/handoff/docs.md")
    launcher.finish(2, exitCode: 0)
    await controller.waitForPendingOperation()
    observedStates.append(controller.state)
    #expect(controller.state == .awaitingMergeGate)
    #expect(controller.manifest?.gate == ConductorRunManifest.Gate(kind: .merge, stepIndex: 2))

    // The full state sequence, asserted together.
    #expect(
        observedStates == [
            .runningStep(index: 0),
            .awaitingGate(index: 0),
            .runningStep(index: 1),
            .awaitingGate(index: 1),
            .runningStep(index: 2),
            .awaitingMergeGate,
        ])

    // The persisted manifest matches the live one, statuses included.
    let persisted = try #require(
        try await ConductorRunStore(workspaceRoot: root).load(runID: runID))
    #expect(persisted.steps.map(\.status) == [.completed, .completed, .completed])
    #expect(persisted.steps.map { $0.attempt ?? 1 } == [1, 1, 1])
    #expect(
        persisted.steps.map(\.evidencePath) == [
            "steps/01-advisor-a1", "steps/02-implementor-a1", "steps/03-documentor-a1",
        ])
    #expect(persisted.gate == ConductorRunManifest.Gate(kind: .merge, stepIndex: 2))
    // Not a full `==` against `controller.manifest`: ISO-8601 encoding
    // truncates sub-second precision on round trip, so the live in-memory
    // manifest's timestamps are never bit-identical to what was just read
    // back — the step/gate/status assertions above already cover the
    // content that matters.
    #expect(controller.manifest?.id == persisted.id)

    // `.rafu/runs/<id>/steps/**` layout: every step's evidence directory,
    // handoff artifact, and prompt exist on disk.
    for (component, artifact) in [
        ("steps/01-advisor-a1", "brief.md"),
        ("steps/02-implementor-a1", "patch.md"),
        ("steps/03-documentor-a1", "docs.md"),
    ] {
        let stepDirectory = root.appending(path: ".rafu/runs/\(runID)/\(component)")
        #expect(FileManager.default.fileExists(atPath: stepDirectory.path))
        #expect(
            FileManager.default.fileExists(
                atPath: stepDirectory.appending(path: "prompt.md").path))
        #expect(
            FileManager.default.fileExists(
                atPath: stepDirectory.appending(path: "handoff/\(artifact)").path))
    }

    // Resolve with Apply: the worktree's changes land on the workspace HEAD
    // with no auto-commit, and the worktree is removed non-forcibly.
    let baseCommit = persisted.baseCommit
    await controller.applyToWorkspace()

    #expect(controller.state == .completed)
    #expect(controller.hasAppliedToWorkspace)
    #expect(controller.mergeGateError == nil)
    #expect(controller.manifest?.gate == nil)
    #expect(
        try String(contentsOf: root.appending(path: "fixture.txt"), encoding: .utf8)
            == "implemented\n")
    #expect(
        try String(contentsOf: root.appending(path: "readme.txt"), encoding: .utf8) == "docs\n")
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
    #expect(try workflowGitOutput(["rev-parse", "HEAD"], at: root) == baseCommit)
    let removedBranch = try? workflowGitOutput(
        ["rev-parse", "--verify", "rafu/run-\(runID)"], at: root)
    #expect(removedBranch == nil)

    // The runs publisher (the C1 controller peer) saw every publish through
    // the single `publish(_:)` seam — never a direct `store.save`.
    #expect(runsPublisher.runs.map(\.id).contains(runID))
}

/// `git rev-parse`-style helpers, mirroring the other Conductor test files'
/// own copies (`mergeGateGitOutput`, `gitOutput`).
func workflowGitOutput(_ arguments: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WorkflowTestRepositoryError.initializationFailed
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}
