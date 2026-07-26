import Darwin
import Foundation
import Synchronization

/// Whether a bounded adapter probe may retain child output. Authentication
/// probes always discard it: Conductor needs only the status command's exit
/// code and never reads provider identity or credential-shaped output.
nonisolated enum ConductorProbeOutputPolicy: Equatable, Sendable {
    case capture
    case discard
}

nonisolated struct ConductorProbeCompletion: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

/// A deliberately small, nonthrowing result. Adapters degrade honestly on
/// every failure and never surface or log probe output.
nonisolated enum ConductorProbeCommandOutcome: Sendable {
    case completed(ConductorProbeCompletion)
    case couldNotLaunch
    case timedOut
    case outputLimitExceeded
    case cancelled
}

nonisolated protocol ConductorProbeCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputPolicy: ConductorProbeOutputPolicy
    ) async -> ConductorProbeCommandOutcome
}

/// The one bounded `Process` implementation used by the two C2 adapters.
/// It lives in this phase-owned file so C2 does not need a shared-file edit.
nonisolated struct ConductorProbeProcessRunner: ConductorProbeCommandRunning {
    static let defaultTimeout = Duration.seconds(5)
    static let defaultMaximumOutputBytes = 256 * 1_024

    let timeout: Duration
    let maximumOutputBytes: Int
    let registry: ProcessResourceRegistry
    let onRegistered: @Sendable (pid_t) async -> Void

    init(
        timeout: Duration = Self.defaultTimeout,
        maximumOutputBytes: Int = Self.defaultMaximumOutputBytes,
        registry: ProcessResourceRegistry = .shared,
        onRegistered: @escaping @Sendable (pid_t) async -> Void = { _ in }
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.registry = registry
        self.onRegistered = onRegistered
    }

    /// Swift 6.2 plain `nonisolated async` stays on the caller's executor.
    /// `@concurrent` is therefore required to keep Settings probes off-main.
    @concurrent
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputPolicy: ConductorProbeOutputPolicy
    ) async -> ConductorProbeCommandOutcome {
        guard !Task.isCancelled else { return .cancelled }

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory.appending(
            path: "rafu-conductor-probe-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        var outputURL: URL?
        var errorURL: URL?
        var outputHandle: FileHandle?
        var errorHandle: FileHandle?

        if outputPolicy == .capture {
            do {
                try fileManager.createDirectory(
                    at: captureDirectory, withIntermediateDirectories: true)
                let stdoutURL = captureDirectory.appending(path: "stdout")
                let stderrURL = captureDirectory.appending(path: "stderr")
                guard
                    fileManager.createFile(atPath: stdoutURL.path, contents: nil),
                    fileManager.createFile(atPath: stderrURL.path, contents: nil)
                else {
                    try? fileManager.removeItem(at: captureDirectory)
                    return .couldNotLaunch
                }
                outputURL = stdoutURL
                errorURL = stderrURL
                outputHandle = try FileHandle(forWritingTo: stdoutURL)
                errorHandle = try FileHandle(forWritingTo: stderrURL)
            } catch {
                try? fileManager.removeItem(at: captureDirectory)
                return .couldNotLaunch
            }
        }

        defer {
            try? outputHandle?.close()
            try? errorHandle?.close()
            if outputPolicy == .capture {
                try? fileManager.removeItem(at: captureDirectory)
            }
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = errorHandle ?? FileHandle.nullDevice

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            try process.run()
        } catch {
            return .couldNotLaunch
        }

        let resourceID = UUID()
        await registry.register(
            id: resourceID,
            name: "\(executableURL.lastPathComponent) probe",
            kind: .other,
            pid: process.processIdentifier)
        await onRegistered(process.processIdentifier)

        var forcedOutcome: ConductorProbeCommandOutcome?

        while process.isRunning {
            if Task.isCancelled {
                forcedOutcome = .cancelled
                break
            }
            if let outputURL, let errorURL,
                Self.fileSize(at: outputURL) > maximumOutputBytes
                    || Self.fileSize(at: errorURL) > maximumOutputBytes
            {
                forcedOutcome = .outputLimitExceeded
                break
            }
            if clock.now >= deadline {
                forcedOutcome = .timedOut
                break
            }

            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch is CancellationError {
                forcedOutcome = .cancelled
                break
            } catch {
                forcedOutcome = .couldNotLaunch
                break
            }
        }

        if forcedOutcome != nil {
            Self.stopAndReap(process)
        } else {
            // NEVER `process.waitUntilExit()` here. It takes no deadline, and
            // it has been observed blocking forever in exactly this frame —
            // one probe stalling the entire `swift test --no-parallel` run
            // with no output (see
            // `conductor-pty-spawn-and-child-environment.md`, finding 3).
            //
            // The poll loop above already observed the child stop, so a
            // bounded settle is enough; if it is somehow still alive, fall
            // through to the same bounded TERM/KILL path the forced branch
            // uses and report the timeout honestly rather than blocking.
            let settleDeadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning, clock.now < settleDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                Self.stopAndReap(process)
                forcedOutcome = .timedOut
            }
        }
        await registry.unregister(id: resourceID)

        try? outputHandle?.close()
        try? errorHandle?.close()

        let wasCancelled = if case .cancelled? = forcedOutcome { true } else { false }
        if !wasCancelled, let outputURL, let errorURL,
            Self.fileSize(at: outputURL) > maximumOutputBytes
                || Self.fileSize(at: errorURL) > maximumOutputBytes
        {
            forcedOutcome = .outputLimitExceeded
        }
        if let forcedOutcome { return forcedOutcome }

        guard let outputURL, let errorURL else {
            return .completed(
                ConductorProbeCompletion(
                    terminationStatus: process.terminationStatus,
                    standardOutput: Data(),
                    standardError: Data()))
        }
        guard
            Self.fileSize(at: outputURL) <= maximumOutputBytes,
            Self.fileSize(at: errorURL) <= maximumOutputBytes,
            let standardOutput = try? Data(contentsOf: outputURL, options: .mappedIfSafe),
            let standardError = try? Data(contentsOf: errorURL, options: .mappedIfSafe)
        else {
            return .outputLimitExceeded
        }
        return .completed(
            ConductorProbeCompletion(
                terminationStatus: process.terminationStatus,
                standardOutput: standardOutput,
                standardError: standardError))
    }

    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Probe children are short-lived metadata commands. Reap through
    /// `waitpid` because `Process.waitUntilExit()` can itself block after a
    /// forced termination. Both the TERM and KILL phases stay bounded.
    private static func stopAndReap(_ process: Process) {
        let processIdentifier = process.processIdentifier
        let termDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        _ = kill(processIdentifier, SIGTERM)
        guard !reap(processIdentifier, before: termDeadline) else { return }

        _ = kill(processIdentifier, SIGKILL)
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        _ = reap(processIdentifier, before: killDeadline)
    }

    /// Bounded `waitpid(WNOHANG)` reap. Shared with the other adapters that
    /// terminate probe children, so there is exactly one implementation of
    /// "collect this child without ever blocking indefinitely".
    static func reap(_ processIdentifier: pid_t, before deadline: ContinuousClock.Instant)
        -> Bool
    {
        while ContinuousClock.now < deadline {
            var status: Int32 = 0
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier || (result == -1 && errno == ECHILD) {
                return true
            }
            if result == -1, errno != EINTR {
                return false
            }
            usleep(10_000)
        }
        return false
    }
}

nonisolated protocol ConductorExecutableChecking: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

nonisolated struct ConductorSystemExecutableChecker: ConductorExecutableChecking {
    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Reference storage is intentional: registry and run-controller copies of
/// one adapter must observe the same latest successful probe.
nonisolated final class ConductorExecutableCache: Sendable {
    private struct State: Sendable {
        var executableURL: URL?
        var nextGeneration: UInt64 = 0
        var committedGeneration: UInt64 = 0
    }

    private let storage: Mutex<State>

    init(_ executableURL: URL? = nil) {
        storage = Mutex(State(executableURL: executableURL))
    }

    func current() -> URL? {
        storage.withLock { $0.executableURL }
    }

    func beginMutation() -> UInt64 {
        storage.withLock {
            $0.nextGeneration &+= 1
            return $0.nextGeneration
        }
    }

    func commit(_ executableURL: URL?, generation: UInt64) {
        storage.withLock {
            guard generation >= $0.committedGeneration else { return }
            $0.executableURL = executableURL
            $0.committedGeneration = generation
        }
    }
}

nonisolated enum ConductorExecutableDiscovery: Sendable {
    case found(URL)
    case notFound
    case cancelled
}

/// Binary discovery and probe environment rules shared by the two C2
/// adapters. No inference credential variable is read or forwarded.
nonisolated struct ConductorAdapterProbeSupport: Sendable {
    static let whichExecutableURL = URL(fileURLWithPath: "/usr/bin/which")

    let binaryName: String
    let standardExecutableURLs: [URL]
    let runner: any ConductorProbeCommandRunning
    let executableChecker: any ConductorExecutableChecking
    let executableCache: ConductorExecutableCache
    let homeDirectory: URL
    let userName: String
    let hostSearchPath: String

    init(
        binaryName: String,
        standardExecutableURLs: [URL],
        initialExecutableURL: URL? = nil,
        runner: any ConductorProbeCommandRunning = ConductorProbeProcessRunner(),
        executableChecker: any ConductorExecutableChecking = ConductorSystemExecutableChecker(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userName: String = NSUserName(),
        hostSearchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.binaryName = binaryName
        self.standardExecutableURLs = standardExecutableURLs
        self.runner = runner
        self.executableChecker = executableChecker
        self.executableCache = ConductorExecutableCache(initialExecutableURL)
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.hostSearchPath = hostSearchPath
    }

    @concurrent
    func probe(versionArguments: [String]) async -> AdapterProbe {
        let generation = executableCache.beginMutation()
        let discovery = await discoverExecutable()
        guard !Task.isCancelled else { return cachedProbe() }

        let executableURL: URL
        switch discovery {
        case .found(let discovered):
            executableURL = discovered
        case .notFound:
            executableCache.commit(nil, generation: generation)
            return .notInstalled
        case .cancelled:
            return cachedProbe()
        }

        let outcome = await runner.run(
            executableURL: executableURL,
            arguments: versionArguments,
            environment: commandEnvironment(for: executableURL),
            outputPolicy: .capture)
        guard !Task.isCancelled else { return cachedProbe() }
        if case .cancelled = outcome { return cachedProbe() }

        let version: String? =
            if case .completed(let completion) = outcome,
                completion.terminationStatus == 0
            {
                Self.firstNonemptyLine(in: completion.standardOutput)
            } else {
                nil
            }
        executableCache.commit(executableURL, generation: generation)
        return AdapterProbe(installed: true, executableURL: executableURL, version: version)
    }

    @concurrent
    func authOutcome(arguments: [String]) async -> ConductorProbeCommandOutcome? {
        guard !Task.isCancelled else { return .cancelled }

        let executableURL: URL
        if let cached = executableCache.current() {
            executableURL = cached
        } else {
            let generation = executableCache.beginMutation()
            let discovery = await discoverExecutable()
            guard !Task.isCancelled else { return .cancelled }
            switch discovery {
            case .found(let discovered):
                executableCache.commit(discovered, generation: generation)
                executableURL = discovered
            case .notFound:
                executableCache.commit(nil, generation: generation)
                return nil
            case .cancelled:
                return .cancelled
            }
        }

        return await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: commandEnvironment(for: executableURL),
            outputPolicy: .discard)
    }

    func invocationEnvironment(runDirectory: URL, handoffDirectory: URL) -> [String: String] {
        var environment = RafuConductorEnvironment.childEnvironment(
            runDirectory: runDirectory, handoffDirectory: handoffDirectory)
        guard let executableURL = executableCache.current() else { return environment }
        environment[RafuConductorEnvironment.path] = Self.path(
            prependingParentOf: executableURL, to: RafuConductorEnvironment.curatedPath)
        return environment
    }

    @concurrent
    private func discoverExecutable() async -> ConductorExecutableDiscovery {
        guard !Task.isCancelled else { return .cancelled }

        let whichOutcome = await runner.run(
            executableURL: Self.whichExecutableURL,
            arguments: [binaryName],
            environment: [RafuConductorEnvironment.path: discoverySearchPath],
            outputPolicy: .capture)
        guard !Task.isCancelled else { return .cancelled }
        if case .cancelled = whichOutcome { return .cancelled }

        if case .completed(let completion) = whichOutcome,
            completion.terminationStatus == 0,
            let path = Self.singleAbsolutePath(in: completion.standardOutput)
        {
            guard !Task.isCancelled else { return .cancelled }
            if executableChecker.isExecutableFile(atPath: path) {
                return .found(URL(fileURLWithPath: path))
            }
        }

        for candidate in standardExecutableURLs {
            guard !Task.isCancelled else { return .cancelled }
            if executableChecker.isExecutableFile(atPath: candidate.path) {
                return .found(candidate)
            }
        }
        return .notFound
    }

    private func cachedProbe() -> AdapterProbe {
        guard let executableURL = executableCache.current() else { return .notInstalled }
        return AdapterProbe(installed: true, executableURL: executableURL, version: nil)
    }

    private var discoverySearchPath: String {
        Self.deduplicatedAbsolutePath(
            hostSearchPath,
            RafuConductorEnvironment.discoverySearchPath(hostSearchPath: hostSearchPath))
    }

    private func commandEnvironment(for executableURL: URL) -> [String: String] {
        [
            RafuConductorEnvironment.path: Self.path(
                prependingParentOf: executableURL, to: RafuConductorEnvironment.curatedPath),
            "HOME": homeDirectory.path,
            "USER": userName,
            "LOGNAME": userName,
        ]
    }

    static func firstNonemptyLine(in data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static func singleAbsolutePath(in data: Data) -> String? {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, lines[0].hasPrefix("/") else { return nil }
        return lines[0]
    }

    static func path(prependingParentOf executableURL: URL, to basePath: String) -> String {
        let parent = executableURL.deletingLastPathComponent().path
        let components = basePath.split(separator: ":", omittingEmptySubsequences: true).map(
            String.init)
        guard !components.contains(parent) else { return basePath }
        return "\(parent):\(basePath)"
    }

    static func deduplicatedAbsolutePath(_ paths: String...) -> String {
        var seen: Set<String> = []
        var result: [String] = []
        for component in paths.flatMap({
            $0.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        }) where component.hasPrefix("/") && seen.insert(component).inserted {
            result.append(component)
        }
        return result.joined(separator: ":")
    }
}

/// Verified against Claude Code 2.1.218. Authentication stays delegated to
/// the official CLI; this adapter never reads a Claude credential store.
nonisolated final class ClaudeCodeAdapter: ConductorCLIAdapter, Sendable {
    let id = ConductorCLIID.claudeCode
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
            binaryName: "claude",
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
        guard let outcome = await probeSupport.authOutcome(arguments: ["auth", "status", "--json"])
        else {
            return .unknown()
        }
        return Self.authStatus(from: outcome)
    }

    /// Re-verified 2026-07-27 against Claude Code 2.1.220 and left unchanged.
    /// These four are exactly the CLI's own generally-available family
    /// aliases, and they match its internal alias→label map
    /// (`{fable: "Fable", sonnet: "Sonnet", opus: "Opus", haiku: "Haiku"}`).
    ///
    /// The CLI's alias array additionally contains `mythos`, which is
    /// deliberately NOT listed: the installed build documents it as restricted
    /// to Project Glasswing participants, so offering it to every user would
    /// be a picker entry that fails for almost all of them.
    ///
    /// Aliases rather than dated ids is the right shape here. `--model`
    /// documents both, and an alias tracks the latest model per release, which
    /// is what a user who picked "Opus" means. A specific dated id is still
    /// reachable — the picker keeps hand-typed values as `.custom`.
    func curatedModels() -> [ConductorModelChoice] {
        [
            ConductorModelChoice(id: "fable", displayName: "Fable", source: .curated),
            ConductorModelChoice(id: "opus", displayName: "Opus", source: .curated),
            ConductorModelChoice(id: "sonnet", displayName: "Sonnet", source: .curated),
            ConductorModelChoice(id: "haiku", displayName: "Haiku", source: .curated),
        ]
    }

    /// Claude Code 2.1.220 has no model-listing verb: no `--list-models` flag
    /// and no listing subcommand (`agents`, `auth`, `doctor`, `mcp`, `plugin`,
    /// `project`, …). Curated stays the only list. (Re-check with
    /// `claude --help | grep -i model`.)
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

        var arguments = ["-p", prompt]
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: [
            "--output-format",
            "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--permission-mode",
            autonomy == .readOnly ? "plan" : "bypassPermissions",
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
            return .notAuthenticated(hint: "run `claude` in a terminal and log in")
        default:
            return .unknown()
        }
    }

    private static func standardExecutableURLs(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appending(path: ".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude"),
        ]
    }
}
