import Foundation

/// Cline 3.0.46 adapter. The installed CLI verifies direct positional
/// headless prompts, a real plan mode, explicit auto-approval, cwd/model
/// selection, and JSON output. Cline exposes neither a safe auth-status
/// command nor a CLI model-listing command, so those answers remain honest
/// `unknown`/`nil`.
nonisolated struct ClineAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.cline
    let defaultEnabled = true
    let supportsModelDiscovery = false

    private let runtime: C3AdapterRuntime
    private let state: C3AdapterProbeState

    init(
        runtime: C3AdapterRuntime = .live,
        executableURL: URL? = nil,
        supportedAutonomies: Set<ConductorAutonomy> = [.readOnly, .worktreeWrite]
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
        // `cline auth` configures credentials, while `cline config` may
        // expose credential material. Neither is a safe status probe.
        .unknown
    }

    func curatedModels() -> [ConductorModelChoice] {
        [
            ConductorModelChoice(
                id: "anthropic/claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6 (Cline route)",
                source: .curated),
            ConductorModelChoice(
                id: "google/gemini-2.5-pro",
                displayName: "Gemini 2.5 Pro (Cline route)",
                source: .curated),
            ConductorModelChoice(
                id: "deepseek/deepseek-chat",
                displayName: "DeepSeek Chat (Cline route)",
                source: .curated),
            ConductorModelChoice(
                id: "minimax/minimax-m2.5",
                displayName: "MiniMax M2.5 (Cline route)",
                source: .curated),
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
        guard let executableURL = state.executableURL(for: autonomy) else {
            return C3AdapterProcess.unsupportedInvocation(
                runDirectory: runDirectory,
                handoffDirectory: handoffDirectory)
        }

        var arguments = [
            "--json",
            "--cwd",
            workingDirectory.path,
        ]
        switch autonomy {
        case .readOnly:
            arguments += ["--plan", "--auto-approve", "false"]
        case .worktreeWrite:
            // C1 owns the worktree. Never pass Cline's `--worktree`, which
            // would create an untracked second worktree outside Rafu's gate.
            arguments += ["--auto-approve", "true"]
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        // Commander honors `--` as the end-of-options marker, keeping a
        // prompt beginning with `-` from becoming a Cline flag.
        arguments += ["--", prompt]

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
        let hasWriteMode =
            helpResult.succeeded
            && help.contains("Arguments:")
            && help.contains("prompt")
            && help.contains("--auto-approve <boolean>")
            && help.contains("--cwd <path>")
            && help.contains("--model <model-id>")
            && help.contains("--json")
        let hasReadOnlyMode =
            hasWriteMode
            && help.contains("--plan")

        var supported: Set<ConductorAutonomy> = []
        if hasWriteMode { supported.insert(.worktreeWrite) }
        if hasReadOnlyMode { supported.insert(.readOnly) }
        let displayedVersion =
            supported.isEmpty
            ? "\(version ?? "unknown version") (adapter needs update: headless flags not found)"
            : version
        return C3AdapterProbeClassification(
            probe: AdapterProbe(
                installed: true,
                executableURL: executableURL,
                version: displayedVersion),
            supportedAutonomies: supported)
    }

    private func resolveExecutable() async -> URL? {
        if let cached = state.locatedExecutableURL() { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/cline"),
            URL(fileURLWithPath: "/usr/local/bin/cline"),
            URL(fileURLWithPath: "/opt/homebrew/bin/cline"),
        ]
        guard let resolved = await runtime.resolveExecutable("cline", candidates) else {
            return nil
        }
        state.recordLocatedExecutable(resolved)
        return resolved
    }
}
