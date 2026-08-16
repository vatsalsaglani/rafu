import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
private func makeCloseWorkspace() throws -> (WorkspaceSession, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RafuTerminalCloseTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: "Close", location: .local(LocalWorkspaceReference(path: root.path)))
    return (session, root)
}

@MainActor
@Test("A close token becomes stale after a group mutation")
func terminalGroupCloseRequiresFreshToken() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let group = try manager.createLiveGroup(
        instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile))
    let effect = try manager.perform(.prepareClose(.group(group.id)))
    let token: TerminalGroupCloseToken
    guard case .requestCloseConfirmation(let value) = effect else {
        Issue.record("Expected a close token")
        return
    }
    token = value
    _ = try manager.splitFocusedPane(
        in: group.id, placement: .right,
        instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile))
    #expect(throws: TerminalGroupValidationError.self) {
        try manager.perform(.finalizeClose(token))
    }
}

@MainActor
@Test("Last pane close requests group confirmation for a running controller")
func workspaceSessionLastPaneCloseRequestsGroupConfirmation() throws {
    let (session, root) = try makeCloseWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let paneID = try #require(session.focusedTerminalPaneID)
    session.terminal.terminalController(for: paneID)?.markRunningForTesting()

    session.closeTerminalPane(paneID)

    #expect(session.pendingTerminalGroupClose?.target == .group(groupID))
    #expect(session.pendingTerminalGroupClose?.liveProcessCount == 1)
    session.cancelTerminalGroupClose()
}

@MainActor
@Test("A stale group confirmation re-presents and performs no cleanup")
func workspaceSessionStaleCloseRequiresSecondConfirmation() async throws {
    let (session, root) = try makeCloseWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var cleanupCount = 0
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
        currentDirectoryPath: root.path, environment: [:], roleBadge: "Agent", agentProvider: .codex
    )
    let sessionID = try session.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) { cleanupCount += 1 }
    var coordinatorCleanupCount = 0
    session.registerCoordinatorSession(
        ConductorCoordinatorSession(
            id: "stale-close", provider: .codex, model: nil, goal: "Test",
            terminalSessionID: sessionID, startedAt: Date(), endedAt: nil)
    ) { coordinatorCleanupCount += 1 }
    let groupID = try #require(session.terminal.terminalGroupAndPane(containing: sessionID)?.0)
    let paneID = try #require(session.terminal.terminalGroupAndPane(containing: sessionID)?.1)
    session.terminal.terminalController(for: paneID)?.markRunningForTesting()
    session.requestTerminalGroupClose(groupID)
    let stale = try #require(session.pendingTerminalGroupClose)
    session.splitFocusedTerminalPane(.right)

    let represented = TerminalGroupIntegrationSignal()
    session.terminalGroupCloseRepreparedForTesting = {
        Task { await represented.signal() }
    }
    session.confirmTerminalGroupClose()
    await represented.wait()
    let refreshed = try #require(session.pendingTerminalGroupClose)
    #expect(refreshed != stale)
    #expect(session.terminal.terminalGroup(groupID)?.panes.count == 2)
    #expect(cleanupCount == 0)
    #expect(coordinatorCleanupCount == 0)

    session.confirmTerminalGroupClose()
    #expect(session.terminal.terminalGroup(groupID) == nil)
    #expect(session.pendingTerminalGroupClose == nil)
    #expect(cleanupCount == 1)
    #expect(coordinatorCleanupCount == 1)
}

@MainActor
@Test("Classified lifecycle cleanup is exact once for natural exit and owner close")
func workspaceSessionConsumesClassifiedLifecycleExactlyOnce() throws {
    let (session, root) = try makeCloseWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var events: [String] = []
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
        currentDirectoryPath: root.path, environment: [:], roleBadge: "Agent", agentProvider: .codex
    )
    let first = try session.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) { events.append("natural") }
    let firstController = try #require(session.terminal.sessions.first(where: { $0.id == first }))
    firstController.processDidTerminate(exitCode: 0)
    firstController.processDidTerminate(exitCode: 0)
    #expect(events == ["natural"])

    let second = try session.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) { events.append("owner") }
    session.ownerHandledTerminalLifecycleClose(second)
    session.teardownTerminalGroups()
    #expect(events == ["natural"])
}

@MainActor
@Test("Teardown drains classified callbacks in stable session order and is idempotent")
func workspaceSessionTeardownDrainsCallbacksInSessionOrder() throws {
    let (session, root) = try makeCloseWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var events: [String] = []
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
        currentDirectoryPath: root.path, environment: [:], roleBadge: "Agent", agentProvider: .codex
    )
    _ = try session.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) { events.append("first") }
    _ = try session.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) { events.append("second") }

    session.teardownTerminalGroups()
    session.teardownTerminalGroups()
    #expect(events == ["first", "second"])
    #expect(session.terminal.sessions.isEmpty)
}
