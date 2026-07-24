import Foundation
import Testing

@testable import RafuApp

@MainActor
private final class WorktreeRunLauncher: ConductorRunProcessLaunching {
    private(set) var specification: TerminalProcessSpec?

    func launch(
        specification: TerminalProcessSpec,
        onExit _: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        self.specification = specification
        return UUID()
    }

    func terminate(sessionID _: UUID) {}
}

private func writableRole() -> ConductorAgentDefinition {
    ConductorAgentDefinition(
        name: "implementor",
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: .worktreeWrite,
        handoffArtifact: "result.md",
        promptBody: "Implement the requested change.")
}

private struct RunRepository {
    let container: URL
    let root: URL
    let firstCommit: String
    let secondCommit: String
}

private func makeRunRepository() throws -> RunRepository {
    let container = FileManager.default.temporaryDirectory
        .appending(path: "rafu-worktree-tests-\(UUID().uuidString)")
    let root = container.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runGit(["init", "-b", "main"], at: root)
    try runGit(["config", "user.email", "tests@rafu.invalid"], at: root)
    try runGit(["config", "user.name", "Rafu Tests"], at: root)
    try Data("first\n".utf8).write(to: root.appending(path: "first.txt"))
    try runGit(["add", "first.txt"], at: root)
    try runGit(["commit", "-m", "First"], at: root)
    let firstCommit = try gitOutput(["rev-parse", "HEAD"], at: root)

    try Data("second\n".utf8).write(to: root.appending(path: "second.txt"))
    try runGit(["add", "second.txt"], at: root)
    try runGit(["commit", "-m", "Second"], at: root)
    let secondCommit = try gitOutput(["rev-parse", "HEAD"], at: root)
    return RunRepository(
        container: container,
        root: root,
        firstCommit: firstCommit,
        secondCommit: secondCommit)
}

@MainActor
@Test("Writable run uses an attributed worktree at the selected base")
func writableRunUsesSelectedBase() async throws {
    let repository = try makeRunRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    let launcher = WorktreeRunLauncher()
    controller.attach(workspaceRoot: repository.root)

    await controller.start(
        ConductorRunRequest(
            role: writableRole(),
            taskPrompt: "Add the planned file.",
            baseReference: repository.firstCommit,
            runID: "selected-base"),
        launcher: launcher)

    #expect(controller.state == .running)
    let plan = try #require(controller.activeWorkspacePlan)
    let worktreeURL = try #require(plan.worktreeURL)
    #expect(plan.branchName == "rafu/run-selected-base")
    #expect(plan.baseCommit == repository.firstCommit)
    #expect(launcher.specification?.currentDirectoryPath == worktreeURL.path)
    #expect(try gitOutput(["rev-parse", "HEAD"], at: worktreeURL) == repository.firstCommit)
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.appending(path: "second.txt").path))
    #expect(try gitOutput(["rev-parse", "HEAD"], at: repository.root) == repository.secondCommit)
    #expect(controller.manifest?.baseCommit == repository.firstCommit)
    #expect(controller.manifest?.worktreeBranch == "rafu/run-selected-base")
}

@MainActor
@Test("Read-only run rejects a base other than the checked-out commit")
func readOnlyRunRejectsDifferentBase() async throws {
    let repository = try makeRunRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    let launcher = WorktreeRunLauncher()
    controller.attach(workspaceRoot: repository.root)
    let role = ConductorAgentDefinition(
        name: "advisor",
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: .readOnly,
        handoffArtifact: "brief.md",
        promptBody: "Review.")

    await controller.start(
        ConductorRunRequest(
            role: role,
            taskPrompt: "Review the older commit.",
            baseReference: repository.firstCommit,
            runID: "read-old-base"),
        launcher: launcher)

    #expect(
        controller.state
            == .failed(
                "A read-only run must use the commit currently checked out in the workspace."))
    #expect(launcher.specification == nil)
}

@Test("Dirty discard requires confirmation and then removes only the run worktree")
func dirtyDiscardRequiresConfirmation() async throws {
    let repository = try makeRunRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let service = ConductorWorktreeService()
    let plan = try await service.plan(
        workspaceRoot: repository.root,
        runID: "discard-dirty",
        autonomy: .worktreeWrite,
        baseReference: repository.firstCommit)
    try await service.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)
    try Data("changed\n".utf8).write(to: worktreeURL.appending(path: "first.txt"))
    try Data("untracked\n".utf8).write(to: worktreeURL.appending(path: "untracked.txt"))

    let unconfirmed = try await service.discard(plan, confirmedDirty: false)

    #expect(unconfirmed == .confirmationRequired)
    #expect(FileManager.default.fileExists(atPath: worktreeURL.path))
    #expect(
        try gitOutput(["rev-parse", "--verify", "rafu/run-discard-dirty"], at: repository.root)
            == repository.firstCommit)

    let confirmed = try await service.discard(plan, confirmedDirty: true)
    let discardedBranch = try? gitOutput(
        ["rev-parse", "--verify", "rafu/run-discard-dirty"], at: repository.root)

    #expect(confirmed == .removed)
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
    #expect(discardedBranch == nil)
    #expect(FileManager.default.fileExists(atPath: repository.root.path))
    #expect(try gitOutput(["rev-parse", "HEAD"], at: repository.root) == repository.secondCommit)
}

@Test("Clean discard removes the run worktree without a confirmation round trip")
func cleanDiscardNeedsNoConfirmation() async throws {
    let repository = try makeRunRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    let service = ConductorWorktreeService()
    let plan = try await service.plan(
        workspaceRoot: repository.root,
        runID: "discard-clean",
        autonomy: .worktreeWrite,
        baseReference: "HEAD")
    try await service.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)

    let result = try await service.discard(plan, confirmedDirty: false)

    #expect(result == .removed)
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
}

@Test("Ignored worktree files require explicit discard confirmation")
func ignoredFilesRequireDiscardConfirmation() async throws {
    let repository = try makeRunRepository()
    defer { try? FileManager.default.removeItem(at: repository.container) }
    try Data("private.txt\n".utf8).write(
        to: repository.root.appending(path: ".gitignore"))
    try runGit(["add", ".gitignore"], at: repository.root)
    try runGit(["commit", "-m", "Ignore private file"], at: repository.root)
    let service = ConductorWorktreeService()
    let plan = try await service.plan(
        workspaceRoot: repository.root,
        runID: "ignored-discard",
        autonomy: .worktreeWrite,
        baseReference: "HEAD")
    try await service.materialize(plan)
    let worktreeURL = try #require(plan.worktreeURL)
    let ignoredURL = worktreeURL.appending(path: "private.txt")
    try Data("user work\n".utf8).write(to: ignoredURL)

    let unconfirmed = try await service.discard(plan, confirmedDirty: false)

    #expect(unconfirmed == .confirmationRequired)
    #expect(FileManager.default.fileExists(atPath: ignoredURL.path))

    let confirmed = try await service.discard(plan, confirmedDirty: true)

    #expect(confirmed == .removed)
    #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
}

private func runGit(_ arguments: [String], at root: URL) throws {
    _ = try gitOutput(arguments, at: root)
}

private func gitOutput(_ arguments: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TestGitError.commandFailed
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum TestGitError: Error {
    case commandFailed
}
