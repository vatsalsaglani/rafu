import Foundation

/// Verified against codex-cli 0.145.0, which is the resolved local binary.
/// Authentication stays delegated to `codex login`; this adapter never opens
/// `auth.json`.
nonisolated final class CodexAdapter: ConductorCLIAdapter, Sendable {
    let id = ConductorCLIID.codex
    let defaultEnabled = true
    let supportsModelDiscovery = false
    let readOnlyHandoffSupport = ConductorReadOnlyHandoffSupport.supported

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

    /// The seven models Codex itself offers, in Codex's own picker order —
    /// `gpt-5.6-sol` is the CLI's default and comes first.
    ///
    /// Verified 2026-07-27 against the installed CLI's own model metadata
    /// (`~/.codex/models_cache.json`, the account-scoped list Codex fetches
    /// and caches; ids and display names read from it verbatim). The embedded
    /// fallback table inside both codex binaries — `~/.local/bin/codex`
    /// 0.145.0 and the ChatGPT.app 0.146.0-alpha build — agrees on the first
    /// six and ships `gpt-5.2` where the live list has `gpt-5.3-codex-spark`.
    /// The live list wins because it is what the user's picker shows.
    ///
    /// The previous list carried the `gpt-5.6` alias (which routes to Sol) and
    /// omitted `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, and
    /// `gpt-5.3-codex-spark`, so a Rafu user saw four choices where Codex
    /// offers seven. Aliases are deliberately gone: an explicit slug is what
    /// appears in dashboards and billing metadata.
    func curatedModels() -> [ConductorModelChoice] {
        [
            ConductorModelChoice(
                id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", source: .curated),
            ConductorModelChoice(id: "gpt-5.5", displayName: "GPT-5.5", source: .curated),
            ConductorModelChoice(id: "gpt-5.4", displayName: "GPT-5.4", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini", source: .curated),
            ConductorModelChoice(
                id: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark",
                source: .curated),
        ]
    }

    /// Codex 0.145.0 has no model-listing verb: neither `codex --help` nor
    /// `codex exec --help` exposes one, and its model set is chosen in the
    /// interactive picker. Curated stays the only list. (Re-check with
    /// `codex --help` and `codex exec --help | grep -i model`.)
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
            return invocationForLaunch(
                ConductorStubInvocation.placeholder(
                    runDirectory: runDirectory, handoffDirectory: handoffDirectory),
                autonomy: autonomy)
        }

        // `codex exec` reports approval as `never` by default. Do not pass
        // `--ask-for-approval`: the resolved 0.145.0 CLI rejects that newer
        // option before it can start a role.
        var arguments = ["exec"]
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        let executionDirectory =
            autonomy == .readOnly ? handoffDirectory : workingDirectory
        arguments.append(contentsOf: [
            "--sandbox",
            "workspace-write",
            "--cd",
            executionDirectory.path,
            "--json",
            "--ephemeral",
            prompt,
        ])

        return invocationForLaunch(
            AdapterInvocation(
                executableURL: executableURL,
                arguments: arguments,
                environment: probeSupport.invocationEnvironment(
                    runDirectory: runDirectory, handoffDirectory: handoffDirectory)),
            autonomy: autonomy)
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
