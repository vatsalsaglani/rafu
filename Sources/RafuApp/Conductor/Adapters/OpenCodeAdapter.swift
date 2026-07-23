import Darwin
import Foundation
import Synchronization

/// C3's internal representation of the capability detail the C0 protocol
/// cannot carry. Adapters retain it after a probe so a synchronous
/// `invocation(...)` can fail closed for unsupported autonomy levels without
/// probing, touching the filesystem, or guessing.
nonisolated struct C3AdapterProbeClassification: Equatable, Sendable {
    let probe: AdapterProbe
    let supportedAutonomies: Set<ConductorAutonomy>

    var hasHeadlessMode: Bool { !supportedAutonomies.isEmpty }
}

/// The result of one bounded metadata subprocess. Probe output is never
/// logged or persisted; callers inspect this value in memory and discard it.
nonisolated struct C3AdapterCommandResult: Equatable, Sendable {
    nonisolated enum Completion: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case cancelled
        case outputTooLarge
        case launchFailed
    }

    let completion: Completion
    let standardOutput: Data
    let standardError: Data

    var succeeded: Bool { completion == .exited(0) }

    var combinedText: String {
        let stdout = String(decoding: standardOutput, as: UTF8.self)
        let stderr = String(decoding: standardError, as: UTF8.self)
        return stdout.isEmpty ? stderr : stdout + (stderr.isEmpty ? "" : "\n" + stderr)
    }
}

/// Injectable runtime keeps live process discovery out of fixture tests.
/// Production closures are value-typed and `Sendable`; no shared mutable
/// process state crosses tasks.
nonisolated struct C3AdapterRuntime: Sendable {
    let resolveExecutable: @Sendable (_ name: String, _ candidates: [URL]) async -> URL?
    let run:
        @Sendable (
            _ executableURL: URL,
            _ arguments: [String],
            _ environment: [String: String],
            _ timeout: Duration,
            _ maximumOutputBytes: Int
        ) async -> C3AdapterCommandResult

    static let live = C3AdapterRuntime(
        resolveExecutable: { name, candidates in
            await C3AdapterProcess.resolveExecutable(name: name, candidates: candidates)
        },
        run: { executableURL, arguments, environment, timeout, maximumOutputBytes in
            await C3AdapterProcess.run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes)
        })
}

/// One adapter instance owns one cache. The registry keeps adapter instances,
/// and copies of the value-typed adapter share this lock-protected reference,
/// so the async probe can hand its absolute path/capabilities to the later
/// pure invocation builder without a global cache.
nonisolated final class C3AdapterProbeState: Sendable {
    private struct Storage: Sendable {
        var executableURL: URL?
        var supportedAutonomies: Set<ConductorAutonomy> = []
    }

    private let storage: Mutex<Storage>

    init(
        executableURL: URL? = nil,
        supportedAutonomies: Set<ConductorAutonomy> = []
    ) {
        storage = Mutex(
            Storage(
                executableURL: executableURL,
                supportedAutonomies: supportedAutonomies))
    }

    func recordLocatedExecutable(_ executableURL: URL) {
        storage.withLock { state in
            if state.executableURL == nil {
                state.executableURL = executableURL
            }
        }
    }

    func record(_ classification: C3AdapterProbeClassification) {
        storage.withLock { state in
            state.executableURL = classification.probe.executableURL
            state.supportedAutonomies = classification.supportedAutonomies
        }
    }

    func clear() {
        storage.withLock { state in
            state.executableURL = nil
            state.supportedAutonomies = []
        }
    }

    func locatedExecutableURL() -> URL? {
        storage.withLock { $0.executableURL }
    }

    func executableURL(for autonomy: ConductorAutonomy) -> URL? {
        storage.withLock { state in
            guard state.supportedAutonomies.contains(autonomy) else { return nil }
            return state.executableURL
        }
    }
}

/// Bounded process execution for C3 metadata probes only. Real role launches
/// flow through C1's terminal process seam; this runner never receives a
/// prompt or repository content.
nonisolated enum C3AdapterProcess {
    static let versionOutputLimit = 32 * 1_024
    static let helpOutputLimit = 64 * 1_024
    static let modelOutputLimit = 256 * 1_024
    static let defaultTimeout = Duration.seconds(5)
    static let modelTimeout = Duration.seconds(10)

    @concurrent
    static func resolveExecutable(name: String, candidates: [URL]) async -> URL? {
        let fileManager = FileManager.default
        let inheritedSearchPath =
            ProcessInfo.processInfo.environment[RafuConductorEnvironment.path]
            ?? RafuConductorEnvironment.curatedPath
        let result = await run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [name],
            environment: [RafuConductorEnvironment.path: inheritedSearchPath],
            timeout: .seconds(2),
            maximumOutputBytes: 8 * 1_024)
        if result.succeeded {
            for rawLine in result.combinedText.split(whereSeparator: \.isNewline) {
                let path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else {
                    continue
                }
                return URL(fileURLWithPath: path)
            }
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            guard candidate.path.hasPrefix("/"),
                fileManager.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        return nil
    }

    @concurrent
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async -> C3AdapterCommandResult {
        guard executableURL.path.hasPrefix("/"), maximumOutputBytes > 0 else {
            return failed(.launchFailed)
        }

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory.appending(
            path: "rafu-conductor-probe-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(
                at: captureDirectory, withIntermediateDirectories: true)
        } catch {
            return failed(.launchFailed)
        }
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appending(path: "stdout")
        let stderrURL = captureDirectory.appending(path: "stderr")
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
        else {
            return failed(.launchFailed)
        }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return failed(.launchFailed)
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            return failed(.launchFailed)
        }

        let registryID = UUID()
        await ProcessResourceRegistry.shared.register(
            id: registryID,
            name: "\(executableURL.lastPathComponent) probe",
            kind: .other,
            pid: process.processIdentifier)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var completion: C3AdapterCommandResult.Completion?

        while process.isRunning {
            if Task.isCancelled {
                completion = .cancelled
                await stop(process)
                break
            }
            let capturedBytes =
                fileByteCount(at: stdoutURL, fileManager: fileManager)
                + fileByteCount(at: stderrURL, fileManager: fileManager)
            if capturedBytes > maximumOutputBytes {
                completion = .outputTooLarge
                await stop(process)
                break
            }
            if clock.now >= deadline {
                completion = .timedOut
                await stop(process)
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                completion = .cancelled
                await stop(process)
                break
            }
        }

        if process.isRunning {
            await stop(process)
        }
        await ProcessResourceRegistry.shared.unregister(id: registryID)

        try? stdoutHandle.close()
        try? stderrHandle.close()

        let finalByteCount =
            fileByteCount(at: stdoutURL, fileManager: fileManager)
            + fileByteCount(at: stderrURL, fileManager: fileManager)
        if finalByteCount > maximumOutputBytes {
            completion = .outputTooLarge
        }

        guard completion != .outputTooLarge else {
            return failed(.outputTooLarge)
        }

        let stdout = (try? Data(contentsOf: stdoutURL, options: .mappedIfSafe)) ?? Data()
        let stderr = (try? Data(contentsOf: stderrURL, options: .mappedIfSafe)) ?? Data()
        return C3AdapterCommandResult(
            completion: completion ?? .exited(process.terminationStatus),
            standardOutput: stdout,
            standardError: stderr)
    }

    static func probeEnvironment(for executableURL: URL) -> [String: String] {
        [
            RafuConductorEnvironment.path: adjustedPath(for: executableURL),
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LC_ALL": "C",
            "NO_COLOR": "1",
        ]
    }

    static func invocationEnvironment(
        for executableURL: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> [String: String] {
        var environment = RafuConductorEnvironment.childEnvironment(
            runDirectory: runDirectory,
            handoffDirectory: handoffDirectory)
        environment[RafuConductorEnvironment.path] = adjustedPath(for: executableURL)
        return environment
    }

    static func unsupportedInvocation(
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        let executableURL = URL(fileURLWithPath: "/usr/bin/false")
        return AdapterInvocation(
            executableURL: executableURL,
            arguments: [],
            environment: invocationEnvironment(
                for: executableURL,
                runDirectory: runDirectory,
                handoffDirectory: handoffDirectory))
    }

    static func adjustedPath(for executableURL: URL) -> String {
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let curated = RafuConductorEnvironment.curatedPath
        let components = curated.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.contains(executableDirectory) else { return curated }
        return executableDirectory + ":" + curated
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func fileByteCount(
        at url: URL,
        fileManager: FileManager
    ) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func failed(
        _ completion: C3AdapterCommandResult.Completion
    ) -> C3AdapterCommandResult {
        C3AdapterCommandResult(
            completion: completion,
            standardOutput: Data(),
            standardError: Data())
    }
}

nonisolated enum C3AdapterText {
    static func version(from result: C3AdapterCommandResult) -> String? {
        guard result.succeeded else { return nil }
        let cleaned = stripANSI(result.combinedText)
        guard let line = cleaned.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { return nil }
        return trimmed
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression)
    }
}

/// OpenCode 1.18.4 adapter. The installed CLI verifies worktree-write
/// headless execution and dynamic model discovery. Its named `plan` agent is
/// not a filesystem sandbox, so read-only roles fail closed rather than
/// claiming an autonomy guarantee the CLI does not provide.
nonisolated struct OpenCodeAdapter: ConductorCLIAdapter {
    let id = ConductorCLIID.openCode
    let defaultEnabled = true
    let supportsModelDiscovery = true

    static let maximumModelOutputBytes = C3AdapterProcess.modelOutputLimit
    static let maximumModelRows = 2_048
    static let maximumModelIDBytes = 512

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
            ["run", "--help", "--pure"],
            environment,
            C3AdapterProcess.defaultTimeout,
            C3AdapterProcess.helpOutputLimit)
        let classification = Self.classifyProbe(
            executableURL: executableURL,
            versionResult: await versionResult,
            runHelpResult: await helpResult)
        state.record(classification)
        return classification.probe
    }

    func authStatus() async -> AdapterAuthStatus {
        guard let executableURL = await resolveExecutable() else { return .unknown }
        let result = await runtime.run(
            executableURL,
            ["auth", "list", "--pure"],
            C3AdapterProcess.probeEnvironment(for: executableURL),
            C3AdapterProcess.defaultTimeout,
            C3AdapterProcess.helpOutputLimit)
        return Self.classifyAuthStatus(result)
    }

    func curatedModels() -> [ConductorModelChoice] {
        [
            ConductorModelChoice(
                id: "opencode/big-pickle",
                displayName: "Big Pickle (OpenCode)",
                source: .curated),
            ConductorModelChoice(
                id: "opencode-go/kimi-k2.7-code",
                displayName: "Kimi K2.7 Code (OpenCode Go)",
                source: .curated),
            ConductorModelChoice(
                id: "google-vertex/claude-sonnet-4-6@default",
                displayName: "Claude Sonnet 4.6 (Vertex)",
                source: .curated),
        ]
    }

    func discoverModels() async -> [ConductorModelChoice]? {
        guard let executableURL = await resolveExecutable() else {
            return curatedModels()
        }
        let result = await runtime.run(
            executableURL,
            ["models", "--pure"],
            C3AdapterProcess.probeEnvironment(for: executableURL),
            C3AdapterProcess.modelTimeout,
            Self.maximumModelOutputBytes)
        guard result.succeeded,
            let parsed = Self.parseDiscoveredModels(result.standardOutput)
        else {
            return curatedModels()
        }
        return parsed
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
            "run",
            "--format",
            "json",
            "--dir",
            workingDirectory.path,
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        // Only worktreeWrite reaches this branch. OpenCode 1.18.4 documents
        // `--auto` as dangerous; C1 confines this launch to Rafu's worktree.
        arguments.append("--auto")
        // Prevent a prompt beginning with `-` from being parsed as another
        // OpenCode option. The prompt remains one inert argv element.
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
        runHelpResult: C3AdapterCommandResult
    ) -> C3AdapterProbeClassification {
        let version = C3AdapterText.version(from: versionResult)
        let help = C3AdapterText.stripANSI(runHelpResult.combinedText)
        let hasHeadlessWriteMode =
            runHelpResult.succeeded
            && help.contains("opencode run")
            && help.contains("--model")
            && help.contains("--auto")
            && help.contains("--dir")
            && help.contains("--format")
        let displayedVersion =
            hasHeadlessWriteMode
            ? version
            : "\(version ?? "unknown version") (adapter needs update: headless flags not found)"
        return C3AdapterProbeClassification(
            probe: AdapterProbe(
                installed: true,
                executableURL: executableURL,
                version: displayedVersion),
            supportedAutonomies: hasHeadlessWriteMode ? [.worktreeWrite] : [])
    }

    static func classifyAuthStatus(
        _ result: C3AdapterCommandResult
    ) -> AdapterAuthStatus {
        guard result.succeeded else { return .unknown }
        let output = C3AdapterText.stripANSI(result.combinedText).lowercased()

        for line in output.split(whereSeparator: \.isNewline)
        where line.contains("credential") {
            let numbers = line.split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            if numbers.contains(where: { $0 > 0 }) {
                return .authenticated
            }
            if numbers.contains(0) {
                return .notAuthenticated(
                    hint:
                        "No OpenCode credentials reported; run `opencode auth login` in a terminal."
                )
            }
        }
        if output.contains("no credentials") {
            return .notAuthenticated(
                hint: "No OpenCode credentials reported; run `opencode auth login` in a terminal.")
        }
        return .unknown
    }

    static func parseDiscoveredModels(
        _ data: Data
    ) -> [ConductorModelChoice]? {
        guard !data.isEmpty,
            data.count <= maximumModelOutputBytes,
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        var lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty, lines.count <= maximumModelRows else { return nil }

        let allowedPunctuation = CharacterSet(charactersIn: "-._/@:+")
        var seen = Set<String>()
        var choices: [ConductorModelChoice] = []
        choices.reserveCapacity(lines.count)

        for rawLine in lines {
            let id = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                id.utf8.count <= maximumModelIDBytes,
                let slash = id.firstIndex(of: "/"),
                slash != id.startIndex,
                id.index(after: slash) != id.endIndex,
                id.unicodeScalars.allSatisfy({
                    $0.isASCII
                        && (CharacterSet.alphanumerics.contains($0)
                            || allowedPunctuation.contains($0))
                })
            else { return nil }

            guard seen.insert(id).inserted else { continue }
            choices.append(
                ConductorModelChoice(
                    id: id,
                    displayName: id,
                    source: .discovered))
        }
        return choices.isEmpty ? nil : choices
    }

    private func resolveExecutable() async -> URL? {
        if let cached = state.locatedExecutableURL() { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".opencode/bin/opencode"),
            home.appending(path: ".local/bin/opencode"),
            URL(fileURLWithPath: "/usr/local/bin/opencode"),
            URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
        ]
        guard let resolved = await runtime.resolveExecutable("opencode", candidates) else {
            return nil
        }
        state.recordLocatedExecutable(resolved)
        return resolved
    }
}
