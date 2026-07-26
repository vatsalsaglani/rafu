import Foundation

/// Kimi CLI adapter implemented against Moonshot's documented print-mode
/// surface. No `kimi` executable was available for local verification. The
/// documented non-interactive prompt mode auto-approves tools and cannot be
/// combined with plan mode, so only worktreeWrite is offered; readOnly fails
/// closed without ever attempting interactive TUI automation.
nonisolated struct KimiAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.kimi
    let defaultEnabled = true
    let supportsModelDiscovery = false

    private let runtime: C3AdapterRuntime
    private let state: C3AdapterProbeState

    init(
        runtime: C3AdapterRuntime = .live,
        executableURL: URL? = nil,
        supportedAutonomies: Set<ConductorAutonomy> = [.worktreeWrite]
    ) {
        self.runtime = runtime
        state = C3AdapterProbeState(
            executableURL: executableURL,
            supportedAutonomies: executableURL == nil ? [] : supportedAutonomies)
    }

    func probe() async -> AdapterProbe {
        guard let executableURL = await resolveExecutable() else {
            state.clear()
            return .notInstalled
        }
        let environment = C3AdapterProcess.probeEnvironment(for: executableURL)
        async let versionResult = runtime.run(
            executableURL,
            ["--version"],
            environment,
            C3AdapterProcess.defaultTimeout,
            C3AdapterProcess.versionOutputLimit)
        async let helpResult = runtime.run(
            executableURL,
            ["--help"],
            environment,
            C3AdapterProcess.defaultTimeout,
            C3AdapterProcess.helpOutputLimit)
        let classification = Self.classifyProbe(
            executableURL: executableURL,
            versionResult: await versionResult,
            helpResult: await helpResult)
        state.record(classification)
        return classification.probe
    }

    func authStatus() async -> AdapterAuthStatus {
        // Current docs expose interactive `kimi login`, but no metadata-only
        // status command that is safe to classify without reading config.
        .unknown()
    }

    func curatedModels() -> [ConductorModelChoice] {
        [
            ConductorModelChoice(
                id: "kimi-for-coding",
                displayName: "Kimi for Coding",
                source: .curated),
            ConductorModelChoice(
                id: "kimi-k2.6",
                displayName: "Kimi K2.6",
                source: .curated),
            ConductorModelChoice(
                id: "kimi-k2-thinking",
                displayName: "Kimi K2 Thinking",
                source: .curated),
        ]
    }

    /// Left off, and the curated list above left untouched, because neither
    /// can be verified: the Kimi CLI is not installed on any machine this has
    /// been probed from, so whether it has a listing verb is genuinely
    /// unknown rather than known-absent. The repository's ground rule is to
    /// record that as unverified with the command to run, never to guess.
    /// (Run `kimi --help | grep -i model` once it is installed.)
    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        guard let executableURL = state.executableURL(for: autonomy) else {
            return C3AdapterProcess.unsupportedInvocation(
                runDirectory: runDirectory,
                handoffDirectory: handoffDirectory)
        }

        var arguments = [
            "--print",
            "-p",
            prompt,
            "--output-format=stream-json",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }

        return AdapterInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: C3AdapterProcess.invocationEnvironment(
                for: executableURL,
                runDirectory: runDirectory,
                handoffDirectory: handoffDirectory))
    }

    static func classifyProbe(
        executableURL: URL,
        versionResult: C3AdapterCommandResult,
        helpResult: C3AdapterCommandResult
    ) -> C3AdapterProbeClassification {
        let version = C3AdapterText.version(from: versionResult)
        let help = C3AdapterText.stripANSI(helpResult.combinedText)
        let hasPromptMode =
            helpResult.succeeded
            && (help.contains("--print") || help.contains("--prompt"))
            && help.contains("--model")
            && help.contains("--output-format")
        let displayedVersion =
            hasPromptMode
            ? version
            : "\(version ?? "unknown version") (installed, but no supported headless mode)"
        return C3AdapterProbeClassification(
            probe: AdapterProbe(
                installed: true,
                executableURL: executableURL,
                version: displayedVersion),
            // Moonshot documents prompt/print mode as implicit auto approval
            // and rejects combining it with plan mode.
            supportedAutonomies: hasPromptMode ? [.worktreeWrite] : [])
    }

    private func resolveExecutable() async -> URL? {
        if let cached = state.locatedExecutableURL() { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/kimi"),
            home.appending(path: ".kimi/bin/kimi"),
            URL(fileURLWithPath: "/usr/local/bin/kimi"),
            URL(fileURLWithPath: "/opt/homebrew/bin/kimi"),
        ]
        guard let resolved = await runtime.resolveExecutable("kimi", candidates) else {
            return nil
        }
        state.recordLocatedExecutable(resolved)
        return resolved
    }
}
