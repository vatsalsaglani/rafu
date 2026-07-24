import Darwin
import Foundation
import Synchronization

/// Best-effort Cursor Agent CLI adapter. Cursor's installed help confirms an
/// unattended mutating surface but no read-only/plan flag, so read-only runs
/// fail closed instead of receiving a weaker approximation.
nonisolated struct CursorAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.cursor
    let defaultEnabled = true
    let supportsModelDiscovery = false

    static let supportedAutonomies: Set<ConductorAutonomy> = [.worktreeWrite]
    static let readOnlyUnsupportedReason =
        "Cursor CLI has no verified read-only or plan mode; read-only runs fail closed."

    static let curatedModelChoices = [
        ConductorModelChoice(id: "gpt-5", displayName: "GPT-5", source: .curated),
        ConductorModelChoice(id: "sonnet-4", displayName: "Sonnet 4", source: .curated),
        ConductorModelChoice(
            id: "sonnet-4-thinking", displayName: "Sonnet 4 Thinking", source: .curated),
    ]

    static let notAuthenticatedHint = "run `cursor-agent login` in a terminal"

    private static let outputLimit = 32 * 1_024
    private static let credentialEnvironmentKeys = ["CURSOR_API_KEY"]

    private let cache: CursorExecutableCache
    private let currentPath: String?
    private let timeout: Duration

    init(
        currentPath: String? = Self.currentProcessPath(),
        timeout: Duration = .seconds(3),
        cachedExecutableURL: URL? = nil
    ) {
        self.currentPath = currentPath
        self.timeout = timeout
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
        guard !Task.isCancelled else { return .unknown }
        guard let executableURL = cache.load() ?? Self.findExecutable(currentPath: currentPath)
        else {
            return .unknown
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
            return .unknown
        }
        return Self.classifyAuthStatus(
            exitCode: result.exitCode,
            output: result.output,
            timedOut: result.timedOut)
    }

    func curatedModels() -> [ConductorModelChoice] { Self.curatedModelChoices }

    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        guard Self.supportedAutonomies.contains(autonomy), let executableURL = cache.load() else {
            return ConductorStubInvocation.placeholder(
                runDirectory: runDirectory, handoffDirectory: handoffDirectory)
        }

        let resolvedModel = model.isEmpty ? Self.curatedModelChoices[0].id : model
        return AdapterInvocation(
            executableURL: executableURL,
            arguments: [
                "-p",
                "--output-format", "json",
                "--force",
                "--model", resolvedModel,
                prompt,
            ],
            environment: Self.invocationEnvironment(
                executableURL: executableURL,
                runDirectory: runDirectory,
                handoffDirectory: handoffDirectory))
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
        guard !timedOut else { return .unknown }
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
        return .unknown
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
        let combinedPath = [currentPath, RafuConductorEnvironment.curatedPath]
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
