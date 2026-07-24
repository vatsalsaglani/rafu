import Foundation
import Testing

@testable import RafuApp

@MainActor
private final class FakeRunProcessLauncher: ConductorRunProcessLaunching {
    let sessionID = UUID()
    private(set) var specification: TerminalProcessSpec?
    private(set) var terminatedSessionIDs: [UUID] = []
    private var onExit: (@MainActor @Sendable (UUID, Int32?) -> Void)?

    func launch(
        specification: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        self.specification = specification
        self.onExit = onExit
        return sessionID
    }

    func terminate(sessionID: UUID) {
        terminatedSessionIDs.append(sessionID)
    }

    func finish(exitCode: Int32?) {
        onExit?(sessionID, exitCode)
    }
}

private func runRole(
    autonomy: ConductorAutonomy = .readOnly,
    handoffArtifact: String = "brief.md"
) -> ConductorAgentDefinition {
    ConductorAgentDefinition(
        name: "advisor",
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: autonomy,
        handoffArtifact: handoffArtifact,
        promptBody: "Assess the requested change.")
}

private func makeRunController(
    root: URL
) async -> (ConductorRunController, FakeRunProcessLauncher) {
    await MainActor.run {
        let controller = ConductorRunController(
            adapters: [FakeConductorAdapter(id: .claudeCode)])
        controller.attach(workspaceRoot: root)
        return (controller, FakeRunProcessLauncher())
    }
}

private func makeTemporaryRunRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-run-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try initializeRunRepository(at: root)
    return root
}

private func initializeRunRepository(at root: URL) throws {
    try runLifecycleGit(["init", "-b", "main"], at: root)
    try Data("fixture\n".utf8).write(to: root.appending(path: "fixture.txt"))
    for arguments in [
        ["config", "user.email", "tests@rafu.invalid"],
        ["config", "user.name", "Rafu Tests"],
        ["add", "fixture.txt"],
        ["commit", "-m", "Fixture"],
    ] {
        try runLifecycleGit(arguments, at: root)
    }
}

private func runLifecycleGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RunRepositoryError.initializationFailed
    }
}

private enum RunRepositoryError: Error {
    case initializationFailed
}

private actor BlockingManifestSaver: ConductorRunManifestSaving {
    struct Snapshot: Sendable {
        let statuses: [RunStepStatus]
        let activeWrites: Int
        let maximumConcurrentWrites: Int
    }

    private var statuses: [RunStepStatus] = []
    private var activeWrites = 0
    private var maximumConcurrentWrites = 0
    private var awaitingGateSaveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func save(_ manifest: ConductorRunManifest, to store: ConductorRunStore) async {
        let status = manifest.steps[0].status
        activeWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)

        if status == .awaitingGate {
            awaitingGateSaveStarted = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        statuses.append(status)
        try? await store.save(manifest)
        activeWrites -= 1
    }

    func waitUntilAwaitingGateSaveStarts() async {
        guard !awaitingGateSaveStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseAwaitingGateSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            statuses: statuses,
            activeWrites: activeWrites,
            maximumConcurrentWrites: maximumConcurrentWrites)
    }
}

@MainActor
@Test("Manifest writes stay serialized in lifecycle order")
func manifestWritesStaySerialized() async throws {
    let root = try makeTemporaryRunRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConductorRunStore(workspaceRoot: root)
    let saver = BlockingManifestSaver()
    let writes = ConductorRunManifestWriteQueue(saver: saver)
    let awaitingGate = runManifest(status: .awaitingGate)
    var completed = awaitingGate
    completed.steps[0].status = .completed
    completed.updatedAt = Date()

    let first = writes.enqueue(awaitingGate, to: store)
    await saver.waitUntilAwaitingGateSaveStarts()
    let second = writes.enqueue(completed, to: store)
    await Task.yield()

    let blocked = await saver.snapshot()
    #expect(blocked.statuses.isEmpty)
    #expect(blocked.activeWrites == 1)
    #expect(blocked.maximumConcurrentWrites == 1)

    await saver.releaseAwaitingGateSave()
    await first.value
    await second.value

    let finished = await saver.snapshot()
    #expect(finished.statuses == [.awaitingGate, .completed])
    #expect(finished.activeWrites == 0)
    #expect(finished.maximumConcurrentWrites == 1)
    let persisted = try await store.load(runID: awaitingGate.id)
    #expect(persisted?.steps[0].status == .completed)
}

@MainActor
@Test("A fake read-only role reaches the merge gate and persists its evidence")
func fakeRoleHappyPathReachesMergeGate() async throws {
    let root = try makeTemporaryRunRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (controller, launcher) = await makeRunController(root: root)
    let request = ConductorRunRequest(
        role: runRole(),
        taskPrompt: "Review `$(touch /tmp/nope)` without executing it.",
        runID: "happy-run")

    await controller.start(request, launcher: launcher)

    #expect(controller.state == .running)
    let specification = try #require(launcher.specification)
    #expect(specification.executableURL == FakeConductorAdapter.executableURL)
    #expect(specification.arguments.last?.contains("$(touch /tmp/nope)") == true)
    #expect(specification.arguments.last?.contains("Task:") == true)
    #expect(specification.environment.keys.sorted() == ["PATH", "RAFU_HANDOFF", "RAFU_RUN_DIR"])

    let manifestBeforeExit = try #require(controller.manifest)
    #expect(manifestBeforeExit.steps[0].status == .running)
    #expect(
        FileManager.default.fileExists(
            atPath: root.appending(path: ".rafu/runs/happy-run/prompt.md").path))

    let handoff = root.appending(path: ".rafu/runs/happy-run/handoff/brief.md")
    try Data("artifact body".utf8).write(to: handoff)
    launcher.finish(exitCode: 0)
    #expect(controller.state == .awaitingArtifact)
    await controller.waitForPendingOperation()

    #expect(controller.state == .awaitingMergeGate)
    #expect(controller.manifest?.steps[0].status == .awaitingGate)
    await controller.keepWorktree()
    #expect(controller.state == .completed)
    #expect(controller.manifest?.steps[0].status == .completed)

    let persisted = try await ConductorRunStore(workspaceRoot: root).load(runID: "happy-run")
    #expect(persisted?.steps[0].status == .completed)
}

@MainActor
@Test("A nonzero fake process exit fails without trusting output")
func fakeRoleNonzeroExitFails() async throws {
    let root = try makeTemporaryRunRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (controller, launcher) = await makeRunController(root: root)

    await controller.start(
        ConductorRunRequest(
            role: runRole(), taskPrompt: "Review.", runID: "nonzero-run"),
        launcher: launcher)
    launcher.finish(exitCode: 17)
    await controller.waitForPendingOperation()

    #expect(controller.state == .failed("The agent process exited with status 17."))
    #expect(
        controller.manifest?.steps[0].status
            == .failed("The agent process exited with status 17."))
}

@MainActor
@Test("Exit zero without a regular handoff artifact fails")
func fakeRoleMissingArtifactFails() async throws {
    let root = try makeTemporaryRunRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (controller, launcher) = await makeRunController(root: root)

    await controller.start(
        ConductorRunRequest(
            role: runRole(), taskPrompt: "Review.", runID: "missing-run"),
        launcher: launcher)
    launcher.finish(exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(
        controller.state
            == .failed("The agent exited successfully without creating its handoff artifact."))
    #expect(controller.manifest?.steps[0].finishedAt != nil)
}

@MainActor
@Test("Abort terminates the fake child and never deletes run evidence")
func abortTerminatesChildAndPreservesEvidence() async throws {
    let root = try makeTemporaryRunRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (controller, launcher) = await makeRunController(root: root)

    await controller.start(
        ConductorRunRequest(
            role: runRole(), taskPrompt: "Review.", runID: "aborted-run"),
        launcher: launcher)
    controller.abort()
    await controller.waitForPendingOperation()

    #expect(controller.state == .aborted)
    #expect(launcher.terminatedSessionIDs == [launcher.sessionID])
    #expect(
        FileManager.default.fileExists(
            atPath: root.appending(path: ".rafu/runs/aborted-run").path))
    #expect(controller.manifest?.steps[0].status == .aborted)
}

@MainActor
@Test("Unsafe handoff paths never reach a launcher")
func unsafeRequestsNeverLaunch() async throws {
    let root = try makeTemporaryRunRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (controller, launcher) = await makeRunController(root: root)

    await controller.start(
        ConductorRunRequest(
            role: runRole(handoffArtifact: "../escape.md"),
            taskPrompt: "Review.",
            runID: "unsafe-run"),
        launcher: launcher)
    #expect(
        controller.state
            == .failed("The role's handoff artifact must be a safe relative path."))
    #expect(launcher.specification == nil)
}

private func runManifest(status: RunStepStatus) -> ConductorRunManifest {
    let now = Date()
    return ConductorRunManifest(
        id: "serialized-manifest",
        workflowName: "advisor",
        baseCommit: "0123456789012345678901234567890123456789",
        worktreeBranch: "",
        createdAt: now,
        updatedAt: now,
        steps: [
            ConductorRunManifest.Step(
                agentName: "advisor",
                binding: ConductorRunManifest.AgentBinding(
                    provider: .claudeCode,
                    model: "fake-fast",
                    autonomy: .readOnly,
                    adapterVersion: "fake"),
                inputArtifacts: [],
                handoffArtifact: "brief.md",
                gateAfter: true,
                status: status,
                startedAt: now,
                finishedAt: nil)
        ])
}
