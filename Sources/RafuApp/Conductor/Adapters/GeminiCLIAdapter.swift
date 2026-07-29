import Darwin
import Foundation
import Synchronization

/// Best-effort Gemini CLI adapter. The executable is not trusted for a run
/// until bounded version and help probes confirm the documented headless
/// surface; invocation itself remains pure and fails closed until that probe
/// has populated the adapter-local cache.
nonisolated struct GeminiCLIAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.geminiCLI
    let defaultEnabled = true
    let supportsModelDiscovery = false

    /// Verified 2026-07-27 against the installed Gemini CLI 0.52.0 bundle's
    /// own model-config registry, which the source comments there mark as the
    /// **user-facing** set — "they could be passed via `--model`" — as opposed
    /// to the internal `*-base` entries that follow it in the same table.
    ///
    /// The previous two-entry list was not wrong so much as a year stale: it
    /// offered only the 2.5 family while the installed CLI accepts the whole
    /// 3.x line. `-base` variants and `gemini-3.1-pro-preview-customtools` are
    /// deliberately excluded as internal, and the Gemma routes belong to
    /// `gemini gemma`, not `--model`.
    ///
    /// `gemini-2.5-pro` is kept because it is still this CLI's own
    /// `DEFAULT_GEMINI_MODEL`; it is last because it is the oldest, and
    /// nothing here is treated as Rafu's default — an unset model passes no
    /// `-m` flag at all.
    static let curatedModelChoices = [
        ConductorModelChoice(
            id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", source: .curated),
        ConductorModelChoice(
            id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro (preview)",
            source: .curated),
        ConductorModelChoice(
            id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite",
            source: .curated),
        ConductorModelChoice(
            id: "gemini-3-pro-preview", displayName: "Gemini 3 Pro (preview)", source: .curated),
        ConductorModelChoice(
            id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash (preview)",
            source: .curated),
        ConductorModelChoice(
            id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", source: .curated),
        ConductorModelChoice(
            id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", source: .curated),
    ]

    private static let outputLimit = 32 * 1_024
    private static let credentialEnvironmentKeys = [
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_APPLICATION_CREDENTIALS",
    ]

    private let cache: GeminiExecutableCache
    private let currentPath: String?
    private let timeout: Duration

    init(
        currentPath: String? = Self.currentProcessPath(),
        timeout: Duration = .seconds(3),
        cachedExecutableURL: URL? = nil
    ) {
        self.currentPath = currentPath
        self.timeout = timeout
        cache = GeminiExecutableCache(initialURL: cachedExecutableURL)
    }

    func probe() async -> AdapterProbe {
        guard !Task.isCancelled else { return .notInstalled }
        guard let executableURL = Self.findExecutable(currentPath: currentPath) else {
            return .notInstalled
        }

        let environment = Self.probeEnvironment(for: executableURL)
        guard
            let versionResult = await GeminiProbeProcess.run(
                executableURL: executableURL,
                arguments: ["--version"],
                environment: environment,
                timeout: timeout,
                outputLimit: Self.outputLimit,
                resourceName: "Gemini CLI version probe")
        else {
            return Task.isCancelled
                ? .notInstalled
                : AdapterProbe(installed: true, executableURL: executableURL, version: nil)
        }
        guard !Task.isCancelled else { return .notInstalled }

        let helpResult = await GeminiProbeProcess.run(
            executableURL: executableURL,
            arguments: ["--help"],
            environment: environment,
            timeout: timeout,
            outputLimit: Self.outputLimit,
            resourceName: "Gemini CLI help probe")
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

    /// Gemini CLI has no verified, non-interactive auth-status command.
    /// Rafu deliberately does not infer authentication by opening
    /// `~/.gemini` files or reading API-key environment values.
    func authStatus() async -> AdapterAuthStatus { .unknown() }

    func curatedModels() -> [ConductorModelChoice] { Self.curatedModelChoices }

    /// Gemini CLI 0.52.0 has no model-listing verb. Its help exposes
    /// `--list-extensions` and `--list-sessions` but no `--list-models`, and
    /// no subcommand lists models either. Curated stays the only list.
    /// (Re-check with `gemini --help | grep -i 'list\|model'`.)
    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        guard let executableURL = cache.load() else {
            return invocationForLaunch(
                ConductorStubInvocation.placeholder(
                    runDirectory: runDirectory, handoffDirectory: handoffDirectory),
                autonomy: autonomy)
        }

        let approvalMode =
            switch autonomy {
            // Default mode stops for tool approval. It is the conservative
            // documented headless mapping when plan mode cannot be locally
            // verified; it does not silently auto-approve writes.
            case .readOnly: "default"
            // Auto-edit approves file edits but still stops for other tools. It
            // is less permissive than YOLO and the least-dangerous documented
            // unattended write mode for a Rafu-owned worktree.
            case .worktreeWrite: "auto_edit"
            }
        // An unset model means "let the CLI decide" — pass no `-m` at all —
        // matching every other adapter and `ConductorModelResolution
        // .cliDecides`. This previously substituted `curatedModelChoices[0]`,
        // which happened to coincide with the CLI's own default only for as
        // long as that list began with `gemini-2.5-pro`; reordering the
        // curated list would silently have changed which model ran.
        var arguments = ["-p", prompt]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["-m", trimmedModel]
        }
        arguments += [
            "--output-format", "json",
            "--approval-mode", approvalMode,
        ]
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
        versionResult: GeminiProbeProcessResult,
        helpResult: GeminiProbeProcessResult?
    ) -> AdapterProbe {
        let version = versionResult.succeeded ? parsedVersion(versionResult.output) : nil
        return AdapterProbe(
            installed: true,
            executableURL: executableURL,
            version: version)
    }

    static func helpSupportsInvocation(_ output: String) -> Bool {
        let plain = stripANSI(output)
        return ["-p", "--model", "--output-format", "--approval-mode"].allSatisfy {
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
                .appendingPathComponent("gemini", isDirectory: false)
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

nonisolated struct GeminiProbeProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

private nonisolated final class GeminiExecutableCache: Sendable {
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

private nonisolated final class GeminiProbeCancellation: Sendable {
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

private nonisolated final class GeminiBoundedOutput: Sendable {
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

private nonisolated enum GeminiProbeProcess {
    @concurrent
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        outputLimit: Int,
        resourceName: String
    ) async -> GeminiProbeProcessResult? {
        let cancellation = GeminiProbeCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let output = GeminiBoundedOutput(limit: outputLimit)
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
            return GeminiProbeProcessResult(
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
