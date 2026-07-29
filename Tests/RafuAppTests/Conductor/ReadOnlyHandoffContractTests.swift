import Foundation
import Testing

@testable import RafuApp

@Test("Claude read-only invocation permits only the absolute handoff path")
func claudeReadOnlyInvocationUsesScopedHandoffPermission() throws {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/claude")
    let testRoot = URL(
        fileURLWithPath: "/tmp/rafu readonly contract \(UUID().uuidString)",
        isDirectory: true)
    let handoffDirectory = testRoot.appending(path: "run/handoff", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: handoffDirectory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testRoot) }
    let adapter = ClaudeCodeAdapter(executableURL: executableURL)

    let invocation = adapter.invocation(
        prompt: "Review the repository and write brief.md.",
        model: "claude-haiku-4-5",
        autonomy: .readOnly,
        workingDirectory: testRoot,
        runDirectory: testRoot.appending(path: "run", directoryHint: .isDirectory),
        handoffDirectory: handoffDirectory)

    #expect(adapter.readOnlyHandoffSupport == .supported)
    #expect(!invocation.arguments.contains("plan"))
    let permissionModeIndex = try #require(
        invocation.arguments.firstIndex(of: "--permission-mode"))
    #expect(invocation.arguments[permissionModeIndex + 1] == "default")
    let allowedToolsIndex = try #require(invocation.arguments.firstIndex(of: "--allowedTools"))
    let permissionRules = invocation.arguments[allowedToolsIndex + 1]
    #expect(permissionRules.contains("Edit(/\(handoffDirectory.path)/**)"))
    #expect(
        permissionRules.contains("Edit(//private\(handoffDirectory.path)/**)"))
    #expect(permissionRules.split(separator: ",").count == 2)
    #expect(invocation.environment["RAFU_HANDOFF"] == handoffDirectory.path)
    #expect(
        invocation.environment[RafuConductorEnvironment.readOnlyHandoffUnsupportedReason] == nil)
}

@Test("Adapters without a verified read-only handoff mapping stay unsupported")
func unsupportedAdaptersDeclareReadOnlyHandoffUnsupported() {
    let adapters: [any ConductorCLIAdapter] = [
        ClineAdapter(executableURL: URL(fileURLWithPath: "/fixture/bin/cline")),
        CursorAdapter(cachedExecutableURL: URL(fileURLWithPath: "/fixture/bin/cursor-agent")),
        GeminiCLIAdapter(cachedExecutableURL: URL(fileURLWithPath: "/fixture/bin/gemini")),
        KimiAdapter(executableURL: URL(fileURLWithPath: "/fixture/bin/kimi")),
    ]

    for adapter in adapters {
        guard case .unsupported(let reason) = adapter.readOnlyHandoffSupport else {
            Issue.record("\(adapter.id.displayName) unexpectedly claims read-only handoff support.")
            continue
        }
        #expect(reason.contains(adapter.id.displayName))
    }
}

@MainActor
@Test("Workspace launcher rejects an unsupported read-only adapter before spawn")
func workspaceLauncherRejectsUnsupportedReadOnlyBeforeSpawn() {
    let reason =
        "Cline does not yet have a verified read-only mode that permits the required Ensemble handoff write."
    let adapter = FakeConductorAdapter(
        id: .cline,
        readOnlyHandoffSupport: .unsupported(reason: reason))
    let runDirectory = URL(fileURLWithPath: "/tmp/rafu-readonly-launch/run")
    let handoffDirectory = runDirectory.appending(path: "handoff")
    let invocation = adapter.invocation(
        prompt: "Review.",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/rafu-readonly-launch"),
        runDirectory: runDirectory,
        handoffDirectory: handoffDirectory)
    let specification = TerminalProcessSpec(
        executableURL: invocation.executableURL,
        arguments: invocation.arguments,
        currentDirectoryPath: "/tmp/rafu-readonly-launch",
        environment: invocation.environment,
        roleBadge: "advisor")
    let session = WorkspaceSession()
    let launcher = WorkspaceConductorRunLauncher(
        workspaceSession: session,
        runID: "unsupported-readonly")
    var didExit = false

    #expect(
        throws: WorkspaceConductorRunLauncherError.readOnlyHandoffUnsupported(reason: reason)
    ) {
        try launcher.launch(specification: specification) { _, _ in
            didExit = true
        }
    }
    #expect(!didExit)
    #expect(session.terminal.sessions.isEmpty)
    #expect(session.selectedConductorRunID == nil)
    #expect(
        WorkspaceConductorRunLauncherError.readOnlyHandoffUnsupported(reason: reason)
            .errorDescription == reason)
}
