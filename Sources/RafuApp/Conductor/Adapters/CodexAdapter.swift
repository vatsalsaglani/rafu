import Foundation

/// Verified against codex-cli 0.146.0-alpha.3. Authentication stays
/// delegated to `codex login`; this adapter never opens `auth.json`.
nonisolated final class CodexAdapter: ConductorCLIAdapter, Sendable {
    let id = ConductorCLIID.codex
    let defaultEnabled = true
    let supportsModelDiscovery = false

    private let probeSupport: ConductorAdapterProbeSupport

    init(
        executableURL: URL? = nil,
        runner: any ConductorProbeCommandRunning = ConductorProbeProcessRunner(),
        executableChecker: any ConductorExecutableChecking = ConductorSystemExecutableChecker(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userName: String = NSUserName(),
        hostSearchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        probeSupport = ConductorAdapterProbeSupport(
            binaryName: "codex",
            standardExecutableURLs: Self.standardExecutableURLs(homeDirectory: homeDirectory),
            initialExecutableURL: executableURL,
            runner: runner,
            executableChecker: executableChecker,
            homeDirectory: homeDirectory,
            userName: userName,
            hostSearchPath: hostSearchPath)
    }

    @concurrent
    func probe() async -> AdapterProbe {
        await probeSupport.probe(versionArguments: ["--version"])
    }

    @concurrent
    func authStatus() async -> AdapterAuthStatus {
        guard let outcome = await probeSupport.authOutcome(arguments: ["login", "status"]) else {
            return .unknown()
        }
        return Self.authStatus(from: outcome)
    }

    func curatedModels() -> [ConductorModelChoice] {
        [
            ConductorModelChoice(id: "gpt-5.6", displayName: "GPT-5.6", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", source: .curated),
        ]
    }

    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        guard let executableURL = probeSupport.executableCache.current() else {
            return ConductorStubInvocation.placeholder(
                runDirectory: runDirectory, handoffDirectory: handoffDirectory)
        }

        var arguments = ["--ask-for-approval", "never", "exec"]
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: [
            "--sandbox",
            autonomy == .readOnly ? "read-only" : "workspace-write",
            "--cd",
            workingDirectory.path,
            "--json",
            "--ephemeral",
            prompt,
        ])

        return AdapterInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: probeSupport.invocationEnvironment(
                runDirectory: runDirectory, handoffDirectory: handoffDirectory))
    }

    static func authStatus(from outcome: ConductorProbeCommandOutcome) -> AdapterAuthStatus {
        guard case .completed(let completion) = outcome else { return .unknown() }
        switch completion.terminationStatus {
        case 0:
            return .authenticated
        case 1:
            return .notAuthenticated(hint: "run `codex login` in a terminal")
        default:
            return .unknown()
        }
    }

    /// Test seam for the capability-matrix drift guard: Codex ships bundled
    /// inside ChatGPT.app rather than on `PATH`, so that candidate must never
    /// be dropped.
    static func standardExecutableURLsForTesting(homeDirectory: URL) -> [URL] {
        standardExecutableURLs(homeDirectory: homeDirectory)
    }

    private static func standardExecutableURLs(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            homeDirectory.appending(path: ".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex"),
        ]
    }
}
