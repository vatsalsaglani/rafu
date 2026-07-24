import Foundation
import Testing

@testable import RafuApp

@MainActor
private final class MergeGateRunLauncher: ConductorRunProcessLaunching {
    let sessionID = UUID()
    private var exitHandler: (@MainActor @Sendable (UUID, Int32?) -> Void)?

    func launch(
        specification _: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        exitHandler = onExit
        return sessionID
    }

    func terminate(sessionID _: UUID) {}

    func finish(_ code: Int32?) {
        exitHandler?(sessionID, code)
    }
}

private struct MergeGateRepository {
    let container: URL
    let root: URL
    let baseCommit: String
}

private func makeMergeGateRepository() throws -> MergeGateRepository {
    let container = FileManager.default.temporaryDirectory
        .appending(path: "rafu-merge-gate-tests-\(UUID().uuidString)")
    let root = container.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try mergeGateGit(["init", "-b", "main"], at: root)
    try mergeGateGit(["config", "user.email", "tests@rafu.invalid"], at: root)
    try mergeGateGit(["config", "user.name", "Rafu Tests"], at: root)
    try Data("base\n".utf8).write(to: root.appending(path: "tracked.txt"))
    try mergeGateGit(["add", "tracked.txt"], at: root)
    try mergeGateGit(["commit", "-m", "Base"], at: root)
    return MergeGateRepository(
        container: container,
        root: root,
        baseCommit: try mergeGateGitOutput(["rev-parse", "HEAD"], at: root))
}

@MainActor
@Test("Gate derives tracked and untracked diffs from the run worktree")
func mergeGateDerivesWorktreeDiffs() async throws {
    let repository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let worktrees = ConductorWorktreeService()
    let gate = ConductorMergeGateService()
    let plan = try await worktrees.plan(
        workspaceRoot: repository.root,
        runID: "diff-gate",
        autonomy: .worktreeWrite,
        baseReference: "HEAD")
    try await worktrees.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("changed\n".utf8).write(to: worktreeURL.appending(path: "tracked.txt"))
    try Data("new\n".utf8).write(to: worktreeURL.appending(path: "new.txt"))

    let files = try await gate.files(for: plan)

    #expect(
        files == [
            ConductorMergeGateFile(path: "new.txt", isUntracked: true),
            ConductorMergeGateFile(path: "tracked.txt", isUntracked: false),
        ])
    let tracked = try #require(files.first(where: { $0.path == "tracked.txt" }))
    let trackedDiff = try await gate.diff(for: tracked, plan: plan)
    #expect(!trackedDiff.hunks.isEmpty)
    let newFile = try #require(files.first(where: { $0.path == "new.txt" }))
    let newDiff = try await gate.diff(for: newFile, plan: plan)
    #expect(!newDiff.hunks.isEmpty)

    let session = WorkspaceSession()
    session.presentConductorDiff(trackedDiff, file: tracked, plan: plan)
    #expect(session.gitOpenDiff?.diff.path == "tracked.txt")
    #expect(
        session.gitOpenDiff?.scope
            == .between(base: repository.baseCommit, head: "rafu/run-diff-gate"))
}

@Test("Apply transfers committed and untracked changes without committing, then cleans up")
func mergeGateAppliesAndCleansUp() async throws {
    let repository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let worktrees = ConductorWorktreeService()
    let gate = ConductorMergeGateService()
    let plan = try await worktrees.plan(
        workspaceRoot: repository.root,
        runID: "apply-gate",
        autonomy: .worktreeWrite,
        baseReference: "HEAD")
    try await worktrees.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("committed change\n".utf8).write(
        to: worktreeURL.appending(path: "tracked.txt"))
    try mergeGateGit(["add", "tracked.txt"], at: worktreeURL)
    try mergeGateGit(["commit", "-m", "Agent change"], at: worktreeURL)
    try Data("untracked change\n".utf8).write(
        to: worktreeURL.appending(path: "new.txt"))

    let result = try await gate.apply(plan)

    #expect(result == .applied)
    #expect(
        try String(contentsOf: repository.root.appending(path: "tracked.txt"), encoding: .utf8)
            == "committed change\n")
    #expect(
        try String(contentsOf: repository.root.appending(path: "new.txt"), encoding: .utf8)
            == "untracked change\n")
    #expect(
        try mergeGateGitOutput(["rev-parse", "HEAD"], at: repository.root)
            == repository.baseCommit)
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
    let removedBranch = try? mergeGateGitOutput(
        ["rev-parse", "--verify", "rafu/run-apply-gate"], at: repository.root)
    #expect(removedBranch == nil)
}

@Test("Apply refuses a workspace that changed after the run started")
func mergeGateRefusesChangedTarget() async throws {
    let repository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let worktrees = ConductorWorktreeService()
    let gate = ConductorMergeGateService()
    let plan = try await worktrees.plan(
        workspaceRoot: repository.root,
        runID: "changed-target",
        autonomy: .worktreeWrite,
        baseReference: "HEAD")
    try await worktrees.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("agent\n".utf8).write(to: worktreeURL.appending(path: "tracked.txt"))
    try Data("user\n".utf8).write(to: repository.root.appending(path: "tracked.txt"))

    await #expect(throws: ConductorMergeGateError.targetWorkspaceChanged) {
        try await gate.apply(plan)
    }

    #expect(FileManager.default.fileExists(atPath: worktreeURL.path))
    #expect(
        try String(contentsOf: repository.root.appending(path: "tracked.txt"), encoding: .utf8)
            == "user\n")
}

@Test("Apply preserves ignored worktree content until explicit discard")
func mergeGateApplyPreservesIgnoredContent() async throws {
    let repository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    try Data("private.txt\n".utf8).write(
        to: repository.root.appending(path: ".gitignore"))
    try mergeGateGit(["add", ".gitignore"], at: repository.root)
    try mergeGateGit(["commit", "-m", "Ignore private file"], at: repository.root)
    let worktrees = ConductorWorktreeService()
    let gate = ConductorMergeGateService()
    let plan = try await worktrees.plan(
        workspaceRoot: repository.root,
        runID: "ignored-apply",
        autonomy: .worktreeWrite,
        baseReference: "HEAD")
    try await worktrees.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("agent\n".utf8).write(to: worktreeURL.appending(path: "tracked.txt"))
    let ignoredURL = worktreeURL.appending(path: "private.txt")
    try Data("private work\n".utf8).write(to: ignoredURL)

    await #expect(throws: ConductorMergeGateError.appliedButCleanupFailed) {
        try await gate.apply(plan)
    }

    #expect(
        try String(contentsOf: repository.root.appending(path: "tracked.txt"), encoding: .utf8)
            == "agent\n")
    #expect(FileManager.default.fileExists(atPath: ignoredURL.path))
    let unconfirmed = try await worktrees.discard(plan, confirmedDirty: false)
    #expect(unconfirmed == .confirmationRequired)
}

@MainActor
@Test("Controller apply accepts only its seed change and completes without committing")
func controllerApplyCompletesWithoutCommit() async throws {
    let repository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    let launcher = MergeGateRunLauncher()
    controller.attach(workspaceRoot: repository.root)
    await controller.start(
        ConductorRunRequest(
            role: mergeGateRole(),
            taskPrompt: "Implement.",
            runID: "controller-apply"),
        launcher: launcher)
    let plan = try #require(controller.activeWorkspacePlan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("applied\n".utf8).write(to: worktreeURL.appending(path: "tracked.txt"))
    try writeMergeGateHandoff(root: repository.root, runID: "controller-apply")
    launcher.finish(0)
    await controller.waitForPendingOperation()

    await controller.applyToWorkspace()

    #expect(controller.state == .completed)
    #expect(controller.hasAppliedToWorkspace)
    #expect(controller.mergeGateError == nil)
    #expect(
        try String(contentsOf: repository.root.appending(path: "tracked.txt"), encoding: .utf8)
            == "applied\n")
    #expect(
        try mergeGateGitOutput(["rev-parse", "HEAD"], at: repository.root)
            == repository.baseCommit)
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
}

@MainActor
@Test("Controller discard requires confirmation while keep preserves the worktree")
func controllerGateDiscardAndKeepSemantics() async throws {
    let discardRepository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: discardRepository.container) }
    let discardController = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    let discardLauncher = MergeGateRunLauncher()
    discardController.attach(workspaceRoot: discardRepository.root)

    await discardController.start(
        ConductorRunRequest(
            role: mergeGateRole(),
            taskPrompt: "Implement.",
            runID: "controller-discard"),
        launcher: discardLauncher)
    let discardPlan = try #require(discardController.activeWorkspacePlan)
    let discardWorktree = try #require(discardPlan.worktreeURL)
    try Data("agent\n".utf8).write(
        to: discardWorktree.appending(path: "tracked.txt"))
    try writeMergeGateHandoff(
        root: discardRepository.root, runID: "controller-discard")
    discardLauncher.finish(0)
    await discardController.waitForPendingOperation()

    #expect(discardController.state == .awaitingMergeGate)
    #expect(discardController.mergeGateFiles.map(\.path) == ["tracked.txt"])
    let unconfirmed = await discardController.discardWorktree(confirmedDirty: false)
    #expect(unconfirmed == .confirmationRequired)
    #expect(discardController.state == .awaitingMergeGate)
    #expect(FileManager.default.fileExists(atPath: discardWorktree.path))
    let confirmed = await discardController.discardWorktree(confirmedDirty: true)
    #expect(confirmed == .removed)
    #expect(discardController.state == .completed)
    #expect(!FileManager.default.fileExists(atPath: discardWorktree.path))

    let keepRepository = try makeMergeGateRepository()
    defer { try? FileManager.default.removeItem(at: keepRepository.container) }
    let keepController = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    let keepLauncher = MergeGateRunLauncher()
    keepController.attach(workspaceRoot: keepRepository.root)
    await keepController.start(
        ConductorRunRequest(
            role: mergeGateRole(),
            taskPrompt: "Implement.",
            runID: "controller-keep"),
        launcher: keepLauncher)
    let keepPlan = try #require(keepController.activeWorkspacePlan)
    let keptWorktree = try #require(keepPlan.worktreeURL)
    try writeMergeGateHandoff(root: keepRepository.root, runID: "controller-keep")
    keepLauncher.finish(0)
    await keepController.waitForPendingOperation()
    await keepController.keepWorktree()

    #expect(keepController.state == .completed)
    #expect(FileManager.default.fileExists(atPath: keptWorktree.path))
    #expect(
        try mergeGateGitOutput(
            ["rev-parse", "--verify", "rafu/run-controller-keep"],
            at: keepRepository.root) == keepRepository.baseCommit)
}

private func mergeGateRole() -> ConductorAgentDefinition {
    ConductorAgentDefinition(
        name: "implementor",
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: .worktreeWrite,
        handoffArtifact: "result.md",
        promptBody: "Implement the requested change.")
}

private func writeMergeGateHandoff(root: URL, runID: String) throws {
    try Data("fake artifact".utf8).write(
        to: root.appending(path: ".rafu/runs/\(runID)/handoff/result.md"))
}

private func mergeGateGit(_ arguments: [String], at root: URL) throws {
    _ = try mergeGateGitOutput(arguments, at: root)
}

private func mergeGateGitOutput(_ arguments: [String], at root: URL) throws -> String {
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
        throw MergeGateTestError.gitFailed
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum MergeGateTestError: Error {
    case gitFailed
}
