import Foundation
import Testing

@testable import RafuApp

private func terminalRunSpec() -> TerminalProcessSpec {
    TerminalProcessSpec(
        executableURL: FakeConductorAdapter.executableURL,
        arguments: ["terminal-run"],
        currentDirectoryPath: NSTemporaryDirectory(),
        environment: [
            "PATH": RafuConductorEnvironment.curatedPath,
            "RAFU_HANDOFF": "/tmp/rafu-terminal-run/handoff",
            "RAFU_RUN_DIR": "/tmp/rafu-terminal-run",
        ],
        roleBadge: "advisor",
        outputLogURL: URL(filePath: "/tmp/rafu-terminal-run/output.log"))
}

@MainActor
@Test("Workspace launcher creates a role-badged terminal tab and forwards natural exit")
func workspaceLauncherCreatesTerminalAndForwardsExit() throws {
    let session = WorkspaceSession()
    let launcher = WorkspaceConductorRunLauncher(
        workspaceSession: session, runID: "terminal-run")
    var observedExit: (UUID, Int32?)?

    let sessionID = try launcher.launch(specification: terminalRunSpec()) { id, code in
        observedExit = (id, code)
    }

    let terminalController = try #require(
        session.terminal.sessions.first(where: { $0.id == sessionID }))
    #expect(terminalController.processSpec == terminalRunSpec())
    #expect(terminalController.displayName == "advisor")
    #expect(session.terminal.selectedID == sessionID)
    #expect(session.selectedConductorRunID == "terminal-run")
    #expect(session.navigatorMode == .runs)
    #expect(session.presentedTerminalSessionIDs == [sessionID])
    #expect(session.terminal.sessionDidExit != nil)
    #expect(session.terminal.sessionDidBell != nil)

    terminalController.processDidTerminate(exitCode: 23)

    #expect(observedExit?.0 == sessionID)
    #expect(observedExit?.1 == 23)
    #expect(terminalController.status == .exited(code: 23))
}

@MainActor
@Test("Workspace launcher termination closes only its attributed terminal")
func workspaceLauncherTerminationClosesItsTerminal() throws {
    let session = WorkspaceSession()
    let launcher = WorkspaceConductorRunLauncher(
        workspaceSession: session, runID: "abort-terminal")
    let sessionID = try launcher.launch(
        specification: terminalRunSpec(), onExit: { _, _ in })

    launcher.terminate(sessionID: sessionID)

    #expect(!session.terminal.sessions.contains(where: { $0.id == sessionID }))
    #expect(!session.presentedTerminalSessionIDs.contains(sessionID))
}

@MainActor
@Test("Fake adapter exit propagates from the workspace terminal to the run FSM")
func fakeAdapterTerminalExitReachesRunFSM() async throws {
    let root = try makeTerminalRunRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession()
    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    controller.attach(workspaceRoot: root)
    let launcher = WorkspaceConductorRunLauncher(
        workspaceSession: session, runID: "terminal-fsm")
    let role = ConductorAgentDefinition(
        name: "advisor",
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: .readOnly,
        handoffArtifact: "brief.md",
        promptBody: "Review the request.")

    await controller.start(
        ConductorRunRequest(
            role: role,
            taskPrompt: "Review.",
            runID: "terminal-fsm"),
        launcher: launcher)

    #expect(controller.state == .running)
    let terminalController = try #require(session.terminal.sessions.first)
    let handoff = root.appending(path: ".rafu/runs/terminal-fsm/handoff/brief.md")
    try Data("fake artifact".utf8).write(to: handoff)
    terminalController.processDidTerminate(exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == .awaitingMergeGate)
    #expect(controller.manifest?.steps[0].status == .awaitingGate)
    #expect(terminalController.status == .exited(code: 0))
}

private func makeTerminalRunRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-terminal-run-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try terminalRunGit(["init", "-b", "main"], at: root)
    try terminalRunGit(["config", "user.email", "tests@rafu.invalid"], at: root)
    try terminalRunGit(["config", "user.name", "Rafu Tests"], at: root)
    try Data("fixture\n".utf8).write(to: root.appending(path: "fixture.txt"))
    try terminalRunGit(["add", "fixture.txt"], at: root)
    try terminalRunGit(["commit", "-m", "Fixture"], at: root)
    return root
}

private func terminalRunGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TerminalRunRepositoryError.gitFailed
    }
}

private enum TerminalRunRepositoryError: Error {
    case gitFailed
}
