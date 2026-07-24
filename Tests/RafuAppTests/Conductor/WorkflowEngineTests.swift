import Foundation
import Testing

@testable import RafuApp

// MARK: - Shared workflow-test fixtures (also used by WorkflowGateTests.swift)

/// Records every `launch(specification:onExit:)` call in order, and lets a
/// test finish any recorded launch by index — the multi-step analogue of
/// `RunLifecycleTests`'s `FakeRunProcessLauncher`.
@MainActor
final class WorkflowFakeLauncher: ConductorRunProcessLaunching {
    struct Recorded {
        let sessionID: UUID
        let specification: TerminalProcessSpec
    }

    private(set) var recorded: [Recorded] = []
    private(set) var terminatedSessionIDs: [UUID] = []
    private var onExitHandlers: [UUID: @MainActor @Sendable (UUID, Int32?) -> Void] = [:]

    func launch(
        specification: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        let sessionID = UUID()
        recorded.append(Recorded(sessionID: sessionID, specification: specification))
        onExitHandlers[sessionID] = onExit
        return sessionID
    }

    func terminate(sessionID: UUID) {
        terminatedSessionIDs.append(sessionID)
    }

    func finish(_ launchIndex: Int, exitCode: Int32?) {
        let entry = recorded[launchIndex]
        onExitHandlers[entry.sessionID]?(entry.sessionID, exitCode)
    }
}

enum WorkflowTestRepositoryError: Error {
    case initializationFailed
}

func makeWorkflowTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-workflow-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try initializeWorkflowRepository(at: root)
    return root
}

func initializeWorkflowRepository(at root: URL) throws {
    try workflowGit(["init", "-b", "main"], at: root)
    try Data("fixture\n".utf8).write(to: root.appending(path: "fixture.txt"))
    for arguments in [
        ["config", "user.email", "tests@rafu.invalid"],
        ["config", "user.name", "Rafu Tests"],
        ["add", "fixture.txt"],
        ["commit", "-m", "Fixture"],
    ] {
        try workflowGit(arguments, at: root)
    }
}

func workflowGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WorkflowTestRepositoryError.initializationFailed
    }
}

func workflowRole(
    name: String,
    handoffArtifact: String,
    autonomy: ConductorAutonomy = .readOnly
) -> ConductorAgentDefinition {
    ConductorAgentDefinition(
        name: name,
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: autonomy,
        handoffArtifact: handoffArtifact,
        promptBody: "\(name) role body.")
}

func workflowDefinition(
    name: String = "pipeline",
    steps: [(agentName: String, inputArtifacts: [String], gateAfter: Bool)]
) -> ConductorWorkflowDefinition {
    ConductorWorkflowDefinition(
        name: name,
        steps: steps.map {
            ConductorWorkflowDefinition.Step(
                agentName: $0.agentName, inputArtifacts: $0.inputArtifacts,
                gateAfter: $0.gateAfter)
        })
}

@MainActor
func makeWorkflowController(
    root: URL
) -> (runsPublisher: ConductorRunController, controller: ConductorWorkflowController) {
    let runsPublisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    runsPublisher.attach(workspaceRoot: root)
    let controller = ConductorWorkflowController(
        runsPublisher: runsPublisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    controller.attach(workspaceRoot: root)
    return (runsPublisher, controller)
}

func writeHandoff(root: URL, runID: String, relativePath: String) throws {
    let url = root.appending(path: ".rafu/runs/\(runID)/\(relativePath)")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("artifact body".utf8).write(to: url)
}

/// A standard three-step, all-readOnly pipeline: advisor -> implementor
/// (reads advisor's artifact) -> documentor (reads implementor's artifact).
/// No step declares a gate.
func threeStepRequest(runID: String) -> ConductorWorkflowRunRequest {
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md"),
        workflowRole(name: "implementor", handoffArtifact: "patch.md"),
        workflowRole(name: "documentor", handoffArtifact: "docs.md"),
    ]
    let workflow = workflowDefinition(
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: false),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
            (agentName: "documentor", inputArtifacts: ["patch.md"], gateAfter: false),
        ])
    return ConductorWorkflowRunRequest(
        workflow: workflow, roles: roles, taskPrompt: "Ship it.", runID: runID)
}

// MARK: - Engine tests

@MainActor
@Test("Three fake steps launch strictly sequentially")
func stepsLaunchSequentially() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "sequential-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    #expect(launcher.recorded.count == 1)
    #expect(controller.state == .runningStep(index: 0))

    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(launcher.recorded.count == 2)
    #expect(controller.state == .runningStep(index: 1))

    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/02-implementor-a1/handoff/patch.md")
    launcher.finish(1, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(launcher.recorded.count == 3)
    #expect(controller.state == .runningStep(index: 2))

    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/03-documentor-a1/handoff/docs.md")
    launcher.finish(2, exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == .completed)
    #expect(launcher.recorded.count == 3)
}

@MainActor
@Test("Manifest records per-step bindings, attempt 1, and evidence paths")
func manifestRecordsPerStepBindingsAndEvidence() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "manifest-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/02-implementor-a1/handoff/patch.md")
    launcher.finish(1, exitCode: 0)
    await controller.waitForPendingOperation()
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/03-documentor-a1/handoff/docs.md")
    launcher.finish(2, exitCode: 0)
    await controller.waitForPendingOperation()

    let manifest = try #require(controller.manifest)
    #expect(manifest.steps.count == 3)
    let expectedSlugs = ["advisor", "implementor", "documentor"]
    for (index, step) in manifest.steps.enumerated() {
        #expect(step.binding.adapterVersion == "fake-1.0")
        #expect(step.attempt == 1)
        #expect(step.status == .completed)
        #expect(
            step.evidencePath
                == "steps/0\(index + 1)-\(expectedSlugs[index])-a1")
    }
}

@MainActor
@Test("Each step's environment carries the run root and its own handoff directory")
func perStepEnvironmentIsolation() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "env-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    let firstEnvironment = launcher.recorded[0].specification.environment
    #expect(Set(firstEnvironment.keys) == ["PATH", "RAFU_HANDOFF", "RAFU_RUN_DIR"])
    let runRoot = root.appending(path: ".rafu/runs/\(runID)").path
    #expect(firstEnvironment["RAFU_RUN_DIR"] == runRoot)
    #expect(
        firstEnvironment["RAFU_HANDOFF"]
            == root.appending(path: ".rafu/runs/\(runID)/steps/01-advisor-a1/handoff").path)

    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    let secondEnvironment = launcher.recorded[1].specification.environment
    #expect(Set(secondEnvironment.keys) == ["PATH", "RAFU_HANDOFF", "RAFU_RUN_DIR"])
    #expect(secondEnvironment["RAFU_RUN_DIR"] == runRoot)
    #expect(
        secondEnvironment["RAFU_HANDOFF"]
            == root.appending(path: ".rafu/runs/\(runID)/steps/02-implementor-a1/handoff").path)
    #expect(secondEnvironment["RAFU_HANDOFF"] != firstEnvironment["RAFU_HANDOFF"])
}

@MainActor
@Test("A downstream step's prompt carries the producing step's artifact path, never its content")
func artifactPassedByReferenceNotContent() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "reference-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    let briefURL = root.appending(
        path: ".rafu/runs/\(runID)/steps/01-advisor-a1/handoff/brief.md")
    try FileManager.default.createDirectory(
        at: briefURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("SECRET-ARTIFACT-CONTENT".utf8).write(to: briefURL)
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    let secondArguments = launcher.recorded[1].specification.arguments
    let promptArgument = try #require(secondArguments.last)
    #expect(promptArgument.contains(briefURL.path))
    #expect(promptArgument.contains("Input artifacts"))
    #expect(!promptArgument.contains("SECRET-ARTIFACT-CONTENT"))
}

@MainActor
@Test("A nonzero exit parks the run at that step and never launches the next one")
func nonzeroExitParksFailureWithoutLaunchingNextStep() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "nonzero-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    launcher.finish(1, exitCode: 3)
    await controller.waitForPendingOperation()

    #expect(
        controller.state
            == .failed(step: 1, reason: "Step 2's agent process exited with status 3."))
    #expect(
        controller.manifest?.steps[1].status
            == .failed("Step 2's agent process exited with status 3."))
    #expect(controller.manifest?.steps[2].status == .pending)
    #expect(launcher.recorded.count == 2)
}

@MainActor
@Test(
    "Retrying a failed step creates a fresh attempt directory, leaves the prior one intact, and relaunches only that step"
)
func retryCreatesFreshAttemptDirectory() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "retry-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    launcher.finish(1, exitCode: 9)
    await controller.waitForPendingOperation()
    #expect(
        controller.state == .failed(step: 1, reason: "Step 2's agent process exited with status 9.")
    )

    let attemptOnePrompt = root.appending(
        path: ".rafu/runs/\(runID)/steps/02-implementor-a1/prompt.md")
    let attemptOneSnapshot = try Data(contentsOf: attemptOnePrompt)

    await controller.retryFailedStep()
    await controller.waitForPendingOperation()

    #expect(controller.state == .runningStep(index: 1))
    #expect(controller.manifest?.steps[1].attempt == 2)
    #expect(controller.manifest?.steps[1].evidencePath == "steps/02-implementor-a2")
    #expect(launcher.recorded.count == 3)

    let attemptTwoDirectory = root.appending(
        path: ".rafu/runs/\(runID)/steps/02-implementor-a2")
    #expect(FileManager.default.fileExists(atPath: attemptTwoDirectory.path))
    let attemptOneAgain = try Data(contentsOf: attemptOnePrompt)
    #expect(attemptOneAgain == attemptOneSnapshot)
}

@MainActor
@Test(
    "A materialize failure leaves `request` unset; retrying surfaces a failure instead of silently publishing .pending (D2 regression)"
)
func retryAfterMaterializeFailureSurfacesInsteadOfCorrupting() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Pre-create the branch `materialize` will try to create: `plan()` only
    // checks the worktree DIRECTORY, so it succeeds; `git branch <name>
    // <startpoint>` then fails because the branch already exists — forcing
    // a materialize failure AFTER `plan` is assigned but BEFORE `request`
    // is (only set once `materialize` succeeds), the exact D2 window.
    try workflowGit(["branch", "rafu/run-materialize-fail-run"], at: root)

    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "materialize-fail-run"
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md", autonomy: .worktreeWrite)
    ]
    let workflow = workflowDefinition(
        steps: [(agentName: "advisor", inputArtifacts: [], gateAfter: false)])

    await controller.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Ship it.", runID: runID),
        launcher: launcher)

    guard case .failed = controller.state else {
        Issue.record("expected a forced materialize failure to park the run .failed")
        return
    }
    #expect(launcher.recorded.isEmpty)

    await controller.retryFailedStep()
    await controller.waitForPendingOperation()

    guard case .failed(let index, let reason) = controller.state else {
        Issue.record("expected retry to surface a failure, not silently no-op")
        return
    }
    #expect(index == 0)
    #expect(!reason.isEmpty)
    #expect(controller.manifest?.steps[0].status != .pending)
    #expect(controller.manifest?.steps[0].attempt == 1)
    #expect(launcher.recorded.isEmpty)
}

@MainActor
@Test("Aborting mid-step terminates the child and preserves evidence and the worktree")
func abortMidStepPreservesEvidenceAndWorktree() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "abort-run"
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md"),
        workflowRole(
            name: "implementor", handoffArtifact: "patch.md", autonomy: .worktreeWrite),
    ]
    let workflow = workflowDefinition(
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: false),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
        ])
    await controller.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Ship it.", runID: runID),
        launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(controller.state == .runningStep(index: 1))
    let worktreeURL = try #require(controller.plan?.worktreeURL)
    #expect(FileManager.default.fileExists(atPath: worktreeURL.path))

    controller.abort()
    await controller.waitForPendingOperation()

    #expect(controller.state == .aborted)
    #expect(launcher.terminatedSessionIDs.count == 1)
    #expect(controller.manifest?.steps[1].status == .aborted)
    #expect(
        FileManager.default.fileExists(
            atPath: root.appending(path: ".rafu/runs/\(runID)/steps/01-advisor-a1").path))
    #expect(FileManager.default.fileExists(atPath: worktreeURL.path))
}

@Test("The step slug sanitizer collapses unsafe characters and enforces bounds")
func slugSanitizerHandlesUnsafeInput() {
    #expect(ConductorRunEvidenceLayout.slug("../../etc/passwd") == "etc-passwd")
    #expect(ConductorRunEvidenceLayout.slug("/leading-slash") == "leading-slash")
    #expect(ConductorRunEvidenceLayout.slug(".hidden") == "hidden")
    #expect(ConductorRunEvidenceLayout.slug("") == "step")
    #expect(ConductorRunEvidenceLayout.slug("héllo wörld") == "h-llo-w-rld")
    let long = String(repeating: "a", count: 40)
    #expect(ConductorRunEvidenceLayout.slug(long) == String(repeating: "a", count: 32))
    #expect(!ConductorRunEvidenceLayout.slug("../../etc/passwd").contains(".."))
    #expect(!ConductorRunEvidenceLayout.slug("../../etc/passwd").contains("/"))
}

private actor TrackingManifestSaver: ConductorRunManifestSaving {
    private(set) var maximumConcurrentWrites = 0
    private var activeWrites = 0

    func save(_ manifest: ConductorRunManifest, to store: ConductorRunStore) async {
        activeWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        try? await store.save(manifest)
        activeWrites -= 1
    }
}

@MainActor
@Test("Rapid step transitions publish manifests through one serialized write queue")
func rapidTransitionsStaySerialized() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let saver = TrackingManifestSaver()
    let runsPublisher = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)], manifestSaver: saver)
    runsPublisher.attach(workspaceRoot: root)
    let controller = ConductorWorkflowController(
        runsPublisher: runsPublisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    controller.attach(workspaceRoot: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "serialized-run"
    let roles = [
        workflowRole(name: "advisor", handoffArtifact: "brief.md"),
        workflowRole(name: "implementor", handoffArtifact: "patch.md"),
    ]
    let workflow = workflowDefinition(
        steps: [
            (agentName: "advisor", inputArtifacts: [], gateAfter: false),
            (agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
        ])

    await controller.start(
        ConductorWorkflowRunRequest(
            workflow: workflow, roles: roles, taskPrompt: "Ship it.", runID: runID),
        launcher: launcher)
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/02-implementor-a1/handoff/patch.md")
    launcher.finish(1, exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == .completed)
    let maximumConcurrent = await saver.maximumConcurrentWrites
    #expect(maximumConcurrent == 1)
}

@MainActor
@Test("A stale exit from a previous step's session id is rejected")
func staleSessionExitIsRejected() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = makeWorkflowController(root: root)
    let launcher = WorkflowFakeLauncher()
    let runID = "stale-run"

    await controller.start(threeStepRequest(runID: runID), launcher: launcher)
    let staleSessionID = launcher.recorded[0].sessionID
    try writeHandoff(
        root: root, runID: runID, relativePath: "steps/01-advisor-a1/handoff/brief.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(controller.state == .runningStep(index: 1))

    controller.processDidExit(sessionID: staleSessionID, exitCode: 0)

    #expect(controller.state == .runningStep(index: 1))
    #expect(launcher.recorded.count == 2)
}
