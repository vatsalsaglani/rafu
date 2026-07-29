import Darwin
import Foundation
import Synchronization

/// Best-effort Cursor Agent CLI adapter. Its installed `--mode plan` surface
/// is not an enforcement boundary: the R5 probe wrote a repository file while
/// in plan mode. Read-only runs therefore fail closed.
nonisolated struct CursorAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.cursor
    let defaultEnabled = true
    /// Cursor 2026.07.23 answers `cursor-agent models` headlessly, on stdin
    /// `/dev/null`, under Rafu's minimal probe environment, in a stable
    /// `<id> - <display name>` table. See `discoverModels()`.
    let supportsModelDiscovery = true

    static let supportedAutonomies: Set<ConductorAutonomy> = [.worktreeWrite]
    static let readOnlyUnsupportedReason =
        "Cursor CLI does not yet have a verified read-only mode that permits the required Ensemble handoff write."
    var readOnlyHandoffSupport: ConductorReadOnlyHandoffSupport {
        .unsupported(reason: Self.readOnlyUnsupportedReason)
    }

    /// Fallback only — `discoverModels()` returns the account's live catalog
    /// (190 rows on 2026-07-27). Every id here was read verbatim from that
    /// probed catalog, which matters because the previous curated list
    /// (`gpt-5`, `sonnet-4`, `sonnet-4-thinking`) came from old help-text
    /// examples and `--model gpt-5` FAILED before the agent even started.
    ///
    /// `auto` is first deliberately. Cursor's catalog is not an entitlement
    /// list: the same account that can list a named model may still be
    /// refused it and told to use Auto, and `--model auto` was the only value
    /// verified end to end. It is therefore the honest safe default to show
    /// first, not merely the alphabetically convenient one.
    static let curatedModelChoices = [
        ConductorModelChoice(id: "auto", displayName: "Auto", source: .curated),
        ConductorModelChoice(id: "composer-2.5", displayName: "Composer 2.5", source: .curated),
        ConductorModelChoice(
            id: "cursor-grok-4.5-high", displayName: "Cursor Grok 4.5", source: .curated),
        ConductorModelChoice(
            id: "claude-opus-5-thinking-high",
            displayName: "Opus 5 1M Thinking",
            source: .curated),
        ConductorModelChoice(
            id: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol 1M High", source: .curated),
        ConductorModelChoice(
            id: "claude-4.5-sonnet-thinking", displayName: "Sonnet 4.5 Thinking",
            source: .curated),
    ]

    static let notAuthenticatedHint = "run `cursor-agent login` in a terminal"

    /// Verified 2026-07-27: the full 190-row catalog is ~8.8 KB. The cap is
    /// deliberately far above that so a format change cannot stream unbounded
    /// output into the app, and far below anything that could matter for
    /// memory.
    static let maximumModelOutputBytes = 256 * 1_024
    static let maximumModelRows = 2_048
    static let maximumModelIDBytes = 512
    static let maximumModelDisplayNameBytes = 256

    private static let outputLimit = 32 * 1_024
    private static let credentialEnvironmentKeys = ["CURSOR_API_KEY"]

    private let cache: CursorExecutableCache
    private let currentPath: String?
    private let timeout: Duration
    private let modelTimeout: Duration

    init(
        currentPath: String? = Self.currentProcessPath(),
        timeout: Duration = .seconds(3),
        // Listing 190 models is slower than `--version`, and it is an
        // explicit user action rather than anything on the typing or launch
        // path, so it gets its own longer — but still bounded — budget.
        modelTimeout: Duration = .seconds(10),
        cachedExecutableURL: URL? = nil
    ) {
        self.currentPath = currentPath
        self.timeout = timeout
        self.modelTimeout = modelTimeout
        cache = CursorExecutableCache(initialURL: cachedExecutableURL)
    }

    func probe() async -> AdapterProbe {
        guard !Task.isCancelled else { return .notInstalled }
        guard let executableURL = Self.findExecutable(currentPath: currentPath) else {
            return .notInstalled
        }

        let environment = Self.probeEnvironment(for: executableURL)
        guard
            let versionResult = await CursorProbeProcess.run(
                executableURL: executableURL,
                arguments: ["--version"],
                environment: environment,
                timeout: timeout,
                outputLimit: Self.outputLimit,
                resourceName: "Cursor CLI version probe")
        else {
            return Task.isCancelled
                ? .notInstalled
                : AdapterProbe(installed: true, executableURL: executableURL, version: nil)
        }
        guard !Task.isCancelled else { return .notInstalled }

        let helpResult = await CursorProbeProcess.run(
            executableURL: executableURL,
            arguments: ["--help"],
            environment: environment,
            timeout: timeout,
            outputLimit: Self.outputLimit,
            resourceName: "Cursor CLI help probe")
        guard !Task.isCancelled else { return .notInstalled }

        let probe = Self.classifyProbe(
            executableURL: executableURL,
            versionResult: versionResult,
            helpResult: helpResult)
        if versionResult.succeeded,
            let helpResult,
            helpResult.succeeded,
            Self.helpSupportsInvocation(helpResult.output)
        {
            cache.store(executableURL)
        }
        return probe
    }

    func authStatus() async -> AdapterAuthStatus {
        guard !Task.isCancelled else { return .unknown() }
        guard let executableURL = cache.load() ?? Self.findExecutable(currentPath: currentPath)
        else {
            return .unknown()
        }
        guard
            let result = await CursorProbeProcess.run(
                executableURL: executableURL,
                arguments: ["status"],
                environment: Self.probeEnvironment(for: executableURL),
                timeout: timeout,
                outputLimit: Self.outputLimit,
                resourceName: "Cursor CLI auth-status probe")
        else {
            return .unknown()
        }
        return Self.classifyAuthStatus(
            exitCode: result.exitCode,
            output: result.output,
            timedOut: result.timedOut)
    }

    func curatedModels() -> [ConductorModelChoice] { Self.curatedModelChoices }

    /// Runs Cursor's own `models` listing.
    ///
    /// Mirrors `OpenCodeAdapter.discoverModels()`: bounded output, bounded
    /// timeout, stdin on `/dev/null`, and the curated list as the fallback for
    /// every failure — a discovery that could not run must never present as an
    /// empty catalog. Rafu forwards no credential; Cursor reads its own
    /// delegated login (ADR 0018), which is exactly how `status` already works.
    func discoverModels() async -> [ConductorModelChoice]? {
        guard let executableURL = cache.load() ?? Self.findExecutable(currentPath: currentPath)
        else {
            return curatedModels()
        }
        guard
            let result = await CursorProbeProcess.run(
                executableURL: executableURL,
                arguments: ["models"],
                environment: Self.probeEnvironment(for: executableURL),
                timeout: modelTimeout,
                outputLimit: Self.maximumModelOutputBytes,
                resourceName: "Cursor CLI model listing"),
            result.succeeded,
            let parsed = Self.parseDiscoveredModels(result.output)
        else {
            return curatedModels()
        }
        return parsed
    }

    /// Parses Cursor's `models` table.
    ///
    /// Verified shape (cursor-agent 2026.07.23-e383d2b, 194 lines):
    ///
    /// ```text
    /// Available models
    ///
    /// auto - Auto (current, default)
    /// gpt-5.3-codex-low - Codex 5.3 Low
    /// …
    ///
    /// Tip: use --model <id> (or /model <id> in interactive mode) to switch. …
    /// ```
    ///
    /// So: a header, a blank line, one `<id> - <display name>` row per model,
    /// and a trailing tip. Rather than hardcode "skip line 1 and the last
    /// line" — which a wording change would silently break — this keeps only
    /// lines that parse as a row with a plausible model id and drops
    /// everything else. The header and tip fall out for free, and so will any
    /// future prose Cursor adds.
    ///
    /// Returns `nil` when nothing parsed, which the caller reads as "this did
    /// not work" and answers with the curated list.
    static func parseDiscoveredModels(_ output: String) -> [ConductorModelChoice]? {
        guard !output.isEmpty, output.utf8.count <= maximumModelOutputBytes else { return nil }

        let lines = stripANSI(output).split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty, lines.count <= maximumModelRows else { return nil }

        let allowedPunctuation = CharacterSet(charactersIn: "-._/@:+")
        var seen = Set<String>()
        var choices: [ConductorModelChoice] = []
        choices.reserveCapacity(lines.count)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.range(of: " - ") else { continue }
            let id = String(line[line.startIndex..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = String(line[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                !displayName.isEmpty,
                id.utf8.count <= maximumModelIDBytes,
                displayName.utf8.count <= maximumModelDisplayNameBytes,
                id.unicodeScalars.allSatisfy({
                    $0.isASCII
                        && (CharacterSet.alphanumerics.contains($0)
                            || allowedPunctuation.contains($0))
                }),
                seen.insert(id).inserted
            else { continue }
            choices.append(
                ConductorModelChoice(id: id, displayName: displayName, source: .discovered))
        }

        return choices.isEmpty ? nil : choices
    }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        guard Self.supportedAutonomies.contains(autonomy), let executableURL = cache.load() else {
            return invocationForLaunch(
                ConductorStubInvocation.placeholder(
                    runDirectory: runDirectory, handoffDirectory: handoffDirectory),
                autonomy: autonomy)
        }

        // An unset model means "let the CLI decide" — pass no `--model` at
        // all — matching every other adapter and `ConductorModelResolution
        // .cliDecides`. This previously substituted `curatedModelChoices[0]`,
        // which is the exact guess that resolver's doc comment forbids: it
        // silently ran a model the account may not be entitled to, and the
        // then-first curated choice (`gpt-5`) was verified on 2026-07-27 to
        // fail before the agent even started.
        var arguments = ["-p", "--output-format", "json", "--force"]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        arguments.append(prompt)
        return invocationForLaunch(
            AdapterInvocation(
                executableURL: executableURL,
                arguments: arguments,
                environment: Self.invocationEnvironment(
                    executableURL: executableURL,
                    runDirectory: runDirectory,
                    handoffDirectory: handoffDirectory)),
            autonomy: autonomy)
    }

    static func classifyProbe(
        executableURL: URL,
        versionResult: CursorProbeProcessResult,
        helpResult: CursorProbeProcessResult?
    ) -> AdapterProbe {
        let version = versionResult.succeeded ? parsedVersion(versionResult.output) : nil
        return AdapterProbe(
            installed: true,
            executableURL: executableURL,
            version: version)
    }

    static func classifyAuthStatus(
        exitCode: Int32,
        output: String,
        timedOut: Bool = false
    ) -> AdapterAuthStatus {
        guard !timedOut else { return .unknown() }
        let normalized = stripANSI(output).lowercased()
        let negativeMarkers = [
            "not logged in",
            "not authenticated",
            "authentication required",
            "please log in",
            "please login",
        ]
        if negativeMarkers.contains(where: normalized.contains) {
            return .notAuthenticated(hint: notAuthenticatedHint)
        }
        if exitCode == 0
            && (normalized.contains("logged in") || normalized.contains("authenticated"))
        {
            return .authenticated
        }
        return .unknown()
    }

    static func helpSupportsInvocation(_ output: String) -> Bool {
        let plain = stripANSI(output)
        return ["--print", "--output-format", "--force", "--model", "status"].allSatisfy {
            plain.contains($0)
        }
    }

    static func findExecutable(
        currentPath: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        let combinedPath = [currentPath, RafuConductorEnvironment.discoverySearchPath()]
            .compactMap(\.self)
            .joined(separator: ":")
        var visited = Set<String>()
        for component in combinedPath.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = String(component)
            guard directory.hasPrefix("/"), visited.insert(directory).inserted else { continue }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("cursor-agent", isDirectory: false)
                .standardizedFileURL
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func invocationEnvironment(
        executableURL: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> [String: String] {
        var environment = RafuConductorEnvironment.childEnvironment(
            runDirectory: runDirectory, handoffDirectory: handoffDirectory)
        environment[RafuConductorEnvironment.path] = childPath(for: executableURL)
        return environment
    }

    static func containsCredentialEnvironmentKey(_ environment: [String: String]) -> Bool {
        !Set(environment.keys).isDisjoint(with: credentialEnvironmentKeys)
    }

    private static func probeEnvironment(for executableURL: URL) -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            RafuConductorEnvironment.path: childPath(for: executableURL),
        ]
    }

    private static func currentProcessPath() -> String? {
        guard let path = getenv("PATH") else { return nil }
        return String(cString: path)
    }

    private static func childPath(for executableURL: URL) -> String {
        let executableDirectory = executableURL.deletingLastPathComponent().standardizedFileURL.path
        let curatedDirectories = Set(
            RafuConductorEnvironment.curatedPath
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init))
        if curatedDirectories.contains(executableDirectory) {
            return RafuConductorEnvironment.curatedPath
        }
        return "\(executableDirectory):\(RafuConductorEnvironment.curatedPath)"
    }

    private static func parsedVersion(_ output: String) -> String? {
        stripANSI(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression)
    }
}

nonisolated struct CursorProbeProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

private nonisolated final class CursorExecutableCache: Sendable {
    private let storage: Mutex<URL?>

    init(initialURL: URL?) {
        storage = Mutex(initialURL)
    }

    func load() -> URL? {
        storage.withLock { $0 }
    }

    func store(_ url: URL) {
        storage.withLock { $0 = url }
    }
}

private nonisolated final class CursorProbeCancellation: Sendable {
    private let state = Mutex((pid: pid_t?.none, cancelled: false))

    func install(pid: pid_t) {
        let shouldTerminate = state.withLock { state in
            state.pid = pid
            return state.cancelled
        }
        if shouldTerminate {
            Darwin.kill(pid, SIGTERM)
        }
    }

    func clear() {
        state.withLock { $0.pid = nil }
    }

    func cancel() {
        let pid = state.withLock { state in
            state.cancelled = true
            return state.pid
        }
        if let pid {
            Darwin.kill(pid, SIGTERM)
        }
    }
}

private nonisolated final class CursorBoundedOutput: Sendable {
    private let limit: Int
    private let storage = Mutex(Data())

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        storage.withLock { stored in
            guard stored.count < limit else { return }
            stored.append(data.prefix(limit - stored.count))
        }
    }

    func string() -> String {
        storage.withLock { String(decoding: $0, as: UTF8.self) }
    }
}

private nonisolated enum CursorProbeProcess {
    @concurrent
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        outputLimit: Int,
        resourceName: String
    ) async -> CursorProbeProcessResult? {
        let cancellation = CursorProbeCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let output = CursorBoundedOutput(limit: outputLimit)
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                return nil
            }

            let registryID = UUID()
            let pid = process.processIdentifier
            cancellation.install(pid: pid)
            await ProcessResourceRegistry.shared.register(
                id: registryID, name: resourceName, kind: .other, pid: pid)

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var timedOut = false
            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    if clock.now >= deadline {
                        timedOut = true
                        terminate(process, pid: pid)
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                terminate(process, pid: pid)
            }
            if process.isRunning {
                terminate(process, pid: pid)
            }

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            output.append(stdout.fileHandleForReading.readDataToEndOfFile())
            output.append(stderr.fileHandleForReading.readDataToEndOfFile())
            cancellation.clear()
            await ProcessResourceRegistry.shared.unregister(id: registryID)

            guard !Task.isCancelled else { return nil }
            return CursorProbeProcessResult(
                exitCode: process.terminationStatus,
                output: output.string(),
                timedOut: timedOut)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func terminate(_ process: Process, pid: pid_t) {
        if process.isRunning {
            Darwin.kill(pid, SIGTERM)
        }
        for _ in 0..<20 where process.isRunning {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(pid, SIGKILL)
        }
    }
}
