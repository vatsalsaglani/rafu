import Foundation
import Testing

@testable import RafuApp

private struct LaunchLibraryFixture {
    let container: URL
    let workspace: URL
    let userLibrary: URL
    let defaults: UserDefaults
    let suiteName: String

    static func make(gitRepository: Bool = false) throws -> LaunchLibraryFixture {
        let container = FileManager.default.temporaryDirectory
            .appending(
                path: "rafu-launch-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workspace = container.appending(path: "workspace", directoryHint: .isDirectory)
        let userLibrary = container.appending(path: "user-library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if gitRepository {
            try initializeWorkflowRepository(at: workspace)
        }
        let suiteName = "RafuLibraryLaunchTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw WorkflowTestRepositoryError.initializationFailed
        }
        defaults.removePersistentDomain(forName: suiteName)
        return LaunchLibraryFixture(
            container: container,
            workspace: workspace,
            userLibrary: userLibrary,
            defaults: defaults,
            suiteName: suiteName)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: container)
    }
}

private func writeLaunchDefinition(
    _ text: String,
    directory: URL,
    fileName: String
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(
        to: directory.appending(path: fileName, directoryHint: .notDirectory),
        options: .atomic)
}

private func launchAgentDefinition(
    name: String,
    model: String = "file-model",
    autonomy: ConductorAutonomy = .readOnly
) -> String {
    """
    ---
    name: \(name)
    provider: \(ConductorCLIID.claudeCode.rawValue)
    model: \(model)
    autonomy: \(autonomy.rawValue)
    handoffArtifact: \(name.lowercased()).md
    ---
    Perform the assigned role.
    """
}

private func launchWorkflowDefinition(name: String, steps: [String]) -> String {
    let renderedSteps = steps.map { "  - \($0)" }.joined(separator: "\n")
    return """
        ---
        name: \(name)
        steps:
        \(renderedSteps)
        ---
        """
}

@MainActor
private func makeLaunchModel(fixture: LaunchLibraryFixture) -> ConductorWorkflowLaunchModel {
    let adapter = FakeConductorAdapter(id: .claudeCode)
    return ConductorWorkflowLaunchModel(
        library: ConductorDefinitionLibrary(
            adapters: [adapter],
            enableStore: ConductorEnableStore(suiteName: fixture.suiteName)),
        lastWorkflowStore: ConductorLastWorkflowStore(defaults: fixture.defaults),
        adapters: [adapter])
}

@MainActor
@Test("Workflow selection defaults to the last used file independently per repository")
func workflowSelectionPersistsPerRepository() async throws {
    let fixture = try LaunchLibraryFixture.make()
    defer { fixture.cleanup() }
    let dot = RafuDotDirectory(workspaceRoot: fixture.workspace)
    try writeLaunchDefinition(
        launchAgentDefinition(name: "Reviewer"),
        directory: dot.agentsURL,
        fileName: "reviewer.md")
    try writeLaunchDefinition(
        launchWorkflowDefinition(name: "Alpha", steps: ["Reviewer"]),
        directory: dot.workflowsURL,
        fileName: "alpha.md")
    try writeLaunchDefinition(
        launchWorkflowDefinition(name: "Beta", steps: ["Reviewer"]),
        directory: dot.workflowsURL,
        fileName: "beta.md")

    let first = makeLaunchModel(fixture: fixture)
    await first.load(
        workspaceRoot: fixture.workspace,
        userLibraryRoot: fixture.userLibrary)
    #expect(first.selectedWorkflow?.displayName == "Alpha")
    let beta = try #require(first.workflows.first { $0.displayName == "Beta" })
    first.selectWorkflow(id: beta.id)

    let restored = makeLaunchModel(fixture: fixture)
    await restored.load(
        workspaceRoot: fixture.workspace,
        userLibraryRoot: fixture.userLibrary)
    #expect(restored.selectedWorkflow?.displayName == "Beta")

    let otherWorkspace = fixture.container.appending(
        path: "other-workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: otherWorkspace, withIntermediateDirectories: true)
    let otherDot = RafuDotDirectory(workspaceRoot: otherWorkspace)
    try writeLaunchDefinition(
        launchAgentDefinition(name: "Reviewer"),
        directory: otherDot.agentsURL,
        fileName: "reviewer.md")
    try writeLaunchDefinition(
        launchWorkflowDefinition(name: "Other", steps: ["Reviewer"]),
        directory: otherDot.workflowsURL,
        fileName: "other.md")

    let other = makeLaunchModel(fixture: fixture)
    await other.load(
        workspaceRoot: otherWorkspace,
        userLibraryRoot: fixture.userLibrary)
    #expect(other.selectedWorkflow?.displayName == "Other")
}

@MainActor
@Test("Repeated roles accept independent launch-only model overrides")
func repeatedRolesKeepStepSpecificOverrides() async throws {
    let fixture = try LaunchLibraryFixture.make()
    defer { fixture.cleanup() }
    let dot = RafuDotDirectory(workspaceRoot: fixture.workspace)
    try writeLaunchDefinition(
        launchAgentDefinition(name: "Reviewer"),
        directory: dot.agentsURL,
        fileName: "reviewer.md")
    try writeLaunchDefinition(
        launchWorkflowDefinition(name: "Double Review", steps: ["Reviewer", "Reviewer"]),
        directory: dot.workflowsURL,
        fileName: "double-review.md")

    let model = makeLaunchModel(fixture: fixture)
    await model.load(
        workspaceRoot: fixture.workspace,
        userLibraryRoot: fixture.userLibrary)
    model.taskPrompt = "Review twice."
    model.setModelValue("fake-fast", for: 0)
    model.setModelValue("fake-deep", for: 1)

    let request = try model.makeRequest(runID: "repeated-role-models")
    #expect(request.roles.map(\.model) == ["fake-fast", "fake-deep"])
    #expect(
        request.roles.map(\.promptBody) == [
            "Perform the assigned role.",
            "Perform the assigned role.",
        ])
}

@MainActor
@Test("A launch-time model override is snapshotted into the run manifest")
func launchOverrideLandsInManifest() async throws {
    let fixture = try LaunchLibraryFixture.make(gitRepository: true)
    defer { fixture.cleanup() }
    let dot = RafuDotDirectory(workspaceRoot: fixture.workspace)
    try writeLaunchDefinition(
        launchAgentDefinition(name: "Reviewer"),
        directory: dot.agentsURL,
        fileName: "reviewer.md")
    try writeLaunchDefinition(
        launchWorkflowDefinition(name: "Review", steps: ["Reviewer"]),
        directory: dot.workflowsURL,
        fileName: "review.md")

    let model = makeLaunchModel(fixture: fixture)
    await model.load(
        workspaceRoot: fixture.workspace,
        userLibraryRoot: fixture.userLibrary)
    model.taskPrompt = "Review this repository."
    model.setModelValue("per-run-model", for: 0)

    let runsPublisher = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    runsPublisher.attach(workspaceRoot: fixture.workspace)
    let controller = ConductorWorkflowController(
        runsPublisher: runsPublisher,
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    controller.attach(workspaceRoot: fixture.workspace)

    await controller.start(
        try model.makeRequest(runID: "manifest-model-override"),
        launcher: WorkflowFakeLauncher())

    let manifest = try #require(controller.manifest)
    #expect(manifest.steps.map(\.binding.model) == ["per-run-model"])
    #expect(controller.state == .runningStep(index: 0))
    controller.abort()
}

@MainActor
@Test("The coordinator caps active runs per window with an explicit typed reason")
func concurrentRunCoordinatorCapsPerWindow() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    publisher.attach(workspaceRoot: root)
    let coordinator = ConductorConcurrentRunCoordinator(
        runsPublisher: publisher,
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    coordinator.attach(workspaceRoot: root)

    for index in 1...3 {
        _ = try await coordinator.start(
            oneStepRequest(runID: "window-one-\(index)"),
            launcher: WorkflowFakeLauncher())
    }
    #expect(coordinator.activeCount == 3)
    await #expect(
        throws: ConductorConcurrentRunError.activeLimitReached(limit: 3)
    ) {
        _ = try await coordinator.start(
            oneStepRequest(runID: "window-one-4"),
            launcher: WorkflowFakeLauncher())
    }

    let secondPublisher = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    secondPublisher.attach(workspaceRoot: root)
    let secondWindow = ConductorConcurrentRunCoordinator(
        runsPublisher: secondPublisher,
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    secondWindow.attach(workspaceRoot: root)
    _ = try await secondWindow.start(
        oneStepRequest(runID: "window-two-1"),
        launcher: WorkflowFakeLauncher())
    #expect(secondWindow.activeCount == 1)

    for controller in coordinator.controllers {
        controller.abort()
    }
    for controller in secondWindow.controllers {
        controller.abort()
    }
}

@MainActor
@Test("Mutating runs reserve unique IDs and materialize distinct worktrees")
func mutatingRunsNeverShareAWorktree() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    publisher.attach(workspaceRoot: root)
    let coordinator = ConductorConcurrentRunCoordinator(
        runsPublisher: publisher,
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    coordinator.attach(workspaceRoot: root)
    let firstLauncher = WorkflowFakeLauncher()
    let secondLauncher = WorkflowFakeLauncher()

    let first = try await coordinator.start(
        oneStepRequest(runID: "mutating-one", autonomy: .worktreeWrite),
        launcher: firstLauncher)
    let second = try await coordinator.start(
        oneStepRequest(runID: "mutating-two", autonomy: .worktreeWrite),
        launcher: secondLauncher)

    let firstWorktree = try #require(first.plan?.worktreeURL)
    let secondWorktree = try #require(second.plan?.worktreeURL)
    #expect(firstWorktree != secondWorktree)
    await #expect(
        throws: ConductorConcurrentRunError.runAlreadyExists("mutating-one")
    ) {
        _ = try await coordinator.start(
            oneStepRequest(runID: "mutating-one", autonomy: .worktreeWrite),
            launcher: WorkflowFakeLauncher())
    }

    try await finishAndDiscard(
        controller: first,
        launcher: firstLauncher,
        root: root,
        runID: "mutating-one")
    try await finishAndDiscard(
        controller: second,
        launcher: secondLauncher,
        root: root,
        runID: "mutating-two")
}

private func oneStepRequest(
    runID: String,
    autonomy: ConductorAutonomy = .readOnly
) -> ConductorWorkflowRunRequest {
    let role = workflowRole(
        name: "worker",
        handoffArtifact: "result.md",
        autonomy: autonomy)
    return ConductorWorkflowRunRequest(
        workflow: workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
        roles: [role],
        taskPrompt: "Perform the task.",
        runID: runID)
}

@MainActor
private func finishAndDiscard(
    controller: ConductorWorkflowController,
    launcher: WorkflowFakeLauncher,
    root: URL,
    runID: String
) async throws {
    try writeHandoff(
        root: root,
        runID: runID,
        relativePath: "steps/01-worker-a1/handoff/result.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()
    #expect(controller.state == .awaitingMergeGate)
    let result = await controller.discardWorktree(confirmedDirty: true)
    #expect(result == .removed)
}
