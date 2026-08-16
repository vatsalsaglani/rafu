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
    var observedExits: [(UUID, Int32?)] = []

    let sessionID = try launcher.launch(specification: terminalRunSpec()) { id, code in
        observedExits.append((id, code))
    }

    let terminalController = try #require(
        session.terminal.sessions.first(where: { $0.id == sessionID }))
    #expect(terminalController.processSpec == terminalRunSpec())
    #expect(terminalController.displayName == "advisor")
    #expect(session.terminal.selectedID == sessionID)
    #expect(session.selectedConductorRunID == "terminal-run")
    #expect(session.navigatorMode == .runs)
    #expect(session.presentedTerminalSessionIDs == [sessionID])
    let groupID = try #require(session.terminal.terminalGroupAndPane(containing: sessionID)?.0)
    let group = try #require(session.terminal.terminalGroup(groupID))
    #expect(group.panes.count == 1)
    #expect(group.panes[0].runtimeKind == .ensembleRole)
    #expect(session.terminal.sessionDidExit != nil)
    #expect(session.terminal.sessionDidBell != nil)

    terminalController.processDidTerminate(exitCode: 23)

    #expect(observedExits.map(\.0) == [sessionID])
    #expect(observedExits.map(\.1) == [23])
    #expect(terminalController.status == .exited(code: 23))
}

@MainActor
@Test("Workspace role user close consumes its lifecycle callback once")
func workspaceRoleUserCloseConsumesLifecycleOnce() throws {
    let session = WorkspaceSession()
    let launcher = WorkspaceConductorRunLauncher(workspaceSession: session, runID: "user-close")
    var observed: [(UUID, Int32?)] = []
    let sessionID = try launcher.launch(specification: terminalRunSpec()) { id, code in
        observed.append((id, code))
    }

    session.closeTerminalSession(sessionID)
    session.closeTerminalSession(sessionID)

    #expect(observed.map(\.0) == [sessionID])
    #expect(observed.map(\.1) == [nil])
    #expect(session.terminal.terminalGroups.isEmpty)
}

@MainActor
@Test("Workspace launcher termination closes only its attributed terminal")
func workspaceLauncherTerminationClosesItsTerminal() throws {
    let session = WorkspaceSession()
    let launcher = WorkspaceConductorRunLauncher(
        workspaceSession: session, runID: "abort-terminal")
    var callbacks = 0
    let sessionID = try launcher.launch(specification: terminalRunSpec()) { _, _ in
        callbacks += 1
    }

    launcher.terminate(sessionID: sessionID)

    #expect(!session.terminal.sessions.contains(where: { $0.id == sessionID }))
    #expect(!session.presentedTerminalSessionIDs.contains(sessionID))
    #expect(session.terminal.terminalGroups.isEmpty)
    #expect(callbacks == 0)
}

@MainActor
@Test("Role seventh launch fails before controller construction or run selection")
func workspaceRoleSeventhLaunchPreflightsCapacity() throws {
    let session = WorkspaceSession()
    let spec = terminalRunSpec()
    for _ in 0..<6 {
        _ = try session.insertClassifiedTerminalSession(
            spec: spec, kind: .ensembleRole, lifecycle: {})
    }
    var constructions = 0
    session.terminal.terminalGroupControllerFactory = { _, _ in
        constructions += 1
        fatalError("must not construct")
    }
    let launcher = WorkspaceConductorRunLauncher(workspaceSession: session, runID: "rejected")

    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 6, requested: 1)) {
        try launcher.launch(specification: spec, onExit: { _, _ in })
    }
    #expect(constructions == 0)
    #expect(session.terminal.sessions.count == 6)
    #expect(session.terminal.terminalGroups.count == 6)
    #expect(session.selectedConductorRunID == nil)
}

@Test("Ensemble launchers use only the classified aggregate insertion boundary")
func ensembleLaunchersAvoidDirectTerminalManagerMutation() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    for relative in [
        "Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift",
        "Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift",
    ] {
        let source = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
        #expect(source.contains("insertClassifiedTerminalSession"))
        #expect(!source.contains("terminal.newSession"))
    }
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
