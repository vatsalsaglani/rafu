import Foundation
import Testing

@testable import RafuApp

nonisolated private struct AgentTerminalFixtureAdapter: ConductorCLIAdapter {
    let id: ConductorCLIID
    let probeResult: AdapterProbe
    let authResult: AdapterAuthStatus
    var models: [ConductorModelChoice] = []

    let defaultEnabled = true
    let supportsModelDiscovery = false

    func probe() async -> AdapterProbe { probeResult }
    func authStatus() async -> AdapterAuthStatus { authResult }
    func curatedModels() -> [ConductorModelChoice] { models }
    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        AdapterInvocation(
            executableURL: probeResult.executableURL
                ?? URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            environment: [:])
    }
}

private func readyAgentTerminalOption(
    id: ConductorCLIID,
    executablePath: String = "/usr/local/bin/agent"
) -> AgentTerminalOption {
    let shape = AgentTerminalLaunchShape.forCLI(id)
    return AgentTerminalOption(
        id: id,
        displayName: id.displayName,
        icon: ConductorCLIIcons.icon(for: id),
        availability: .ready(URL(fileURLWithPath: executablePath)),
        curatedModels: [],
        defaultModel: nil,
        launchVerificationNote: shape.verification.note)
}

@MainActor
@Test("Agent Terminal spec carries PATH only and zero Ensemble capability")
func agentTerminalSpecHasNoEnsembleCapability() throws {
    let root = URL(fileURLWithPath: "/tmp/rafu-agent-terminal", isDirectory: true)
    let option = readyAgentTerminalOption(
        id: .claudeCode,
        executablePath: "/Users/test/.local/bin/claude")

    let spec = try AgentTerminalLaunchService(workspaceRoot: root).specification(
        option: option,
        model: "sonnet",
        startingDirectory: root)

    #expect(
        Set(spec.environment.keys)
            == Set([RafuConductorEnvironment.path]))
    #expect(
        spec.environment[RafuConductorEnvironment.path]?.hasPrefix(
            "/Users/test/.local/bin:") == true)
    #expect(spec.environment[RafuConductorEnvironment.handoff] == nil)
    #expect(spec.environment[RafuConductorEnvironment.runDirectory] == nil)
    #expect(spec.environment["RAFU_ENSEMBLE_TOKEN"] == nil)
    #expect(spec.arguments == ["--model", "sonnet"])
    #expect(spec.outputLogURL == nil)
    #expect(spec.agentProvider == .claudeCode)
    #expect(spec.resourceAttribution == "Claude Code (agent terminal)")
}

@MainActor
@Test("Executable directory is prepended only when it is outside the curated PATH")
func agentTerminalPrependsOffPathExecutableDirectory() throws {
    let root = URL(fileURLWithPath: "/tmp/rafu-agent-terminal", isDirectory: true)
    let service = AgentTerminalLaunchService(workspaceRoot: root)

    let offPath = try service.specification(
        option: readyAgentTerminalOption(
            id: .codex, executablePath: "/opt/vendor/codex"),
        model: nil,
        startingDirectory: root)
    #expect(
        offPath.environment["PATH"]
            == "/opt/vendor:\(RafuConductorEnvironment.curatedPath)")

    let curated = try service.specification(
        option: readyAgentTerminalOption(
            id: .codex, executablePath: "/usr/local/bin/codex"),
        model: nil,
        startingDirectory: root)
    #expect(curated.environment["PATH"] == RafuConductorEnvironment.curatedPath)
}

@MainActor
@Test("Options distinguish absent, unauthenticated, unknown-auth, and ready CLIs with reasons")
func agentTerminalOptionsGatingMatrix() async throws {
    let suite = "AgentTerminalTests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = ConductorDefaultModelStore(suiteName: suite)
    defaults.setDefaultModel("gpt-test", for: .cline)

    let installed = { (path: String) in
        AdapterProbe(
            installed: true,
            executableURL: URL(fileURLWithPath: path),
            version: "test")
    }
    let adapters: [any ConductorCLIAdapter] = [
        AgentTerminalFixtureAdapter(
            id: .claudeCode,
            probeResult: .notInstalled,
            authResult: .authenticated),
        AgentTerminalFixtureAdapter(
            id: .codex,
            probeResult: installed("/usr/local/bin/codex"),
            authResult: .notAuthenticated(
                hint: "not logged in — run `codex login` in a terminal")),
        AgentTerminalFixtureAdapter(
            id: .openCode,
            probeResult: installed("/usr/local/bin/opencode"),
            authResult: .unknown(reason: "No non-interactive auth probe")),
        AgentTerminalFixtureAdapter(
            id: .cline,
            probeResult: installed("/usr/local/bin/cline"),
            authResult: .authenticated,
            models: [
                ConductorModelChoice(
                    id: "cline-model", displayName: "Cline model", source: .curated)
            ]),
    ]

    let options = await AgentTerminalLaunchService(
        workspaceRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
        adapters: adapters,
        defaultModelStore: defaults
    ).options()

    #expect(options.map(\.id) == [.claudeCode, .codex, .openCode, .cline])
    #expect(options[0].availability == .notInstalled)
    #expect(options[0].availability.reason?.contains("Not installed") == true)
    #expect(
        options[1].availability
            == .notAuthenticated("not logged in — run `codex login` in a terminal"))
    #expect(options[1].availability.reason?.contains("codex login") == true)
    #expect(options[2].isReady)
    #expect(options[3].isReady)
    #expect(options[3].curatedModels == ["cline-model"])
    #expect(options[3].defaultModel == "gpt-test")
}

@MainActor
@Test("Model arguments are emitted only for verified CLI shapes")
func agentTerminalModelFlagsAreVerifiedOnly() throws {
    let root = URL(fileURLWithPath: "/tmp/rafu-agent-terminal", isDirectory: true)
    let service = AgentTerminalLaunchService(workspaceRoot: root)

    let cline = try service.specification(
        option: readyAgentTerminalOption(id: .cline),
        model: "verified-model",
        startingDirectory: root)
    #expect(cline.arguments == ["--tui", "--model", "verified-model"])

    let kimiOption = readyAgentTerminalOption(id: .kimi)
    let kimi = try service.specification(
        option: kimiOption,
        model: "unverified-model",
        startingDirectory: root)
    #expect(kimi.arguments.isEmpty)
    #expect(kimiOption.launchVerificationNote?.contains("launch it bare") == true)
}

@MainActor
@Test("Starting directory must stay inside the workspace")
func agentTerminalRejectsEscapingStartingDirectory() throws {
    let root = URL(fileURLWithPath: "/tmp/rafu-agent-terminal", isDirectory: true)
    let service = AgentTerminalLaunchService(workspaceRoot: root)
    let option = readyAgentTerminalOption(id: .codex)

    #expect(
        throws: AgentTerminalLaunchError.startingDirectoryOutsideWorkspace
    ) {
        try service.specification(
            option: option,
            model: nil,
            startingDirectory: URL(
                fileURLWithPath: "/tmp/rafu-agent-terminal-escape",
                isDirectory: true))
    }

    let nested = root.appending(path: "Sources", directoryHint: .isDirectory)
    #expect(AgentTerminalLaunchService.isStartingDirectory(nested, inside: root))
}

@MainActor
@Test("Opening an Agent Terminal creates and reveals a provider-carrying session")
func openAgentTerminalCreatesAndRevealsSession() throws {
    let workspace = WorkspaceSession()
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let spec = try AgentTerminalLaunchService(workspaceRoot: root).specification(
        option: readyAgentTerminalOption(id: .codex),
        model: nil,
        startingDirectory: root)

    workspace.openAgentTerminal(spec: spec)

    let controller = try #require(workspace.terminal.sessions.first)
    #expect(controller.processSpec == spec)
    #expect(controller.agentProvider == .codex)
    #expect(controller.displayName == "Codex")
    #expect(workspace.terminal.selectedID == controller.id)
    #expect(
        workspace.editorLayout.tab(matching: .terminal(sessionID: controller.id))
            != nil)
    #expect(!EditorTabResource.terminal(sessionID: controller.id).isRestorable)
}
