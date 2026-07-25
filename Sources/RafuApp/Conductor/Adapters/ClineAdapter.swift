import Foundation

/// Cline 3.0.46 adapter. The installed CLI verifies direct positional
/// headless prompts, a real plan mode, explicit auto-approval, cwd/model
/// selection, and JSON output.
///
/// Cline exposes no auth-status command Rafu can use headlessly (see
/// `authStatus()`), and no `models` subcommand — `cline config` accepts only
/// `workflows|rules|skills|agents|plugins|hooks|mcp|tools`. It DOES ship its
/// full model catalog on disk inside its own package
/// (`@cline/llms/dist/models.js`), so `discoverModels()` reads that instead:
/// local, offline, no credentials, and exactly matching the installed
/// version.
nonisolated struct ClineAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.cline
    let defaultEnabled = true
    // Discovery reads Cline's own bundled catalog rather than a CLI command
    // (it has none). Any failure falls back to `curatedModels()`.
    let supportsModelDiscovery = true

    /// The catalog is ~800 KB of minified JS; the JSON we ask Node to emit is
    /// far smaller, but cap it anyway so a future format change cannot stream
    /// unbounded output into Rafu.
    static let maximumModelOutputBytes = 512 * 1_024

    /// Prints `[{"id":…,"name":…}]` for the given provider from Cline's own
    /// bundled catalog. The catalog path arrives as `argv[2]`, never
    /// interpolated into this source, so a path containing quotes cannot
    /// alter the script.
    static let catalogScript = """
        import * as catalog from process.argv[1];
        const models = await catalog.getModelsForProvider(process.argv[2]);
        const list = Array.isArray(models) ? models : Object.values(models ?? {});
        process.stdout.write(JSON.stringify(
            list.filter((m) => m && typeof m.id === "string")
                .map((m) => ({ id: m.id, name: typeof m.name === "string" ? m.name : m.id }))));
        """

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
        // Verified against Cline 3.0.46: there is NO non-interactive
        // sign-in check. `cline auth` performs authentication rather than
        // reporting it; `cline config` and `cline mcp` both refuse without a
        // TTY ("interactive mode requires a TTY"), and the only headless
        // commands (`version`, `history --json`) say nothing about the
        // account. Reading `~/.cline/data/settings/providers.json` would mean
        // reading a 0600 credential store, which ADR 0018 forbids outright.
        // So this is honestly unknown — and says why.
        .unknown(
            reason:
                "Cline's CLI has no non-interactive sign-in check, so Rafu cannot read its status. This does not block runs — sign in with `cline auth`.")
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

    /// Reads the model catalog Cline ships inside its own package. Every
    /// failure path — CLI not found, no sibling `node`, catalog moved or
    /// renamed by a Cline update, unparseable output — falls back to the
    /// curated list rather than surfacing an empty or invented picker.
    func discoverModels() async -> [ConductorModelChoice]? {
        guard let executableURL = await resolveExecutable(),
            let node = Self.siblingNodeURL(of: executableURL),
            let catalog = Self.catalogURL(for: executableURL)
        else {
            return curatedModels()
        }
        let result = await runtime.run(
            node,
            ["--input-type=module", "-e", Self.catalogScript, catalog.path, Self.providerID],
            C3AdapterProcess.probeEnvironment(for: executableURL),
            C3AdapterProcess.modelTimeout,
            Self.maximumModelOutputBytes)
        guard result.succeeded,
            let parsed = Self.parseCatalogModels(result.standardOutput),
            !parsed.isEmpty
        else {
            return curatedModels()
        }
        return parsed
    }

    /// Cline's default provider (`-P, --provider <id>`, default `cline`).
    static let providerID = "cline"

    /// `node` beside the resolved `cline` — true for nvm, Homebrew, and npm
    /// global prefixes alike, and guaranteed to be the interpreter that
    /// actually runs this Cline (its shebang is `#!/usr/bin/env node`).
    static func siblingNodeURL(of executableURL: URL) -> URL? {
        let node = executableURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appending(path: "node", directoryHint: .notDirectory)
        // The resolved cline lives in `lib/node_modules/cline/bin/`, so also
        // try the launcher's own directory, where nvm keeps `node`.
        let launcherSibling = executableURL
            .deletingLastPathComponent()
            .appending(path: "node", directoryHint: .notDirectory)
        for candidate in [launcherSibling, node]
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// `<cline package>/node_modules/@cline/llms/dist/models.js`, derived from
    /// the RESOLVED executable (`.../cline/bin/cline`).
    static func catalogURL(for executableURL: URL) -> URL? {
        let packageRoot = executableURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = packageRoot
            .appending(path: "node_modules/@cline/llms/dist/models.js", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: catalog.path) else { return nil }
        return catalog
    }

    /// Parses the bounded JSON the catalog script prints. Entries without a
    /// usable id are dropped rather than rendered as blanks.
    static func parseCatalogModels(_ output: String) -> [ConductorModelChoice]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var seen: Set<String> = []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String,
                !id.isEmpty,
                seen.insert(id).inserted
            else { return nil }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ConductorModelChoice(id: id, displayName: name, source: .discovered)
        }
    }

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
