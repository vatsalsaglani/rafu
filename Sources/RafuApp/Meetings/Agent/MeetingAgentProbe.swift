import CryptoKit
import Darwin
import Foundation
import RafuCore

/// What the runner needs from the probe. Tests inject a fake.
nonisolated protocol MeetingAgentProbeService: Sendable {
    /// Probes the CLI, or gives the kept result for the same binary.
    func probe(_ cli: MeetingAgentCLI, refresh: Bool) async -> MeetingAgentProbeResult
    /// The kept result for the installed binary, with no process; nil when
    /// none is kept.
    func lastResult(of cli: MeetingAgentCLI) async -> MeetingAgentProbeResult?
    /// The version of the last ready probe, for diagnostics.
    func readyVersion(of cli: MeetingAgentCLI) async -> String?
    /// Forgets the kept result (a real run saw a refused init, a sign-out, a
    /// setting that no longer works, a tool event or a written file).
    func invalidate(_ cli: MeetingAgentCLI) async
}

/// The binary that a ready result belongs to.
nonisolated struct MeetingAgentProbeKey: Codable, Hashable, Sendable {
    var path: String
    var version: String
    /// The modification date of the binary, in seconds since 1970.
    var modified: Double?
    /// `MeetingAgentArguments.revision`.
    var revision: Int
}

/// One kept ready result.
nonisolated struct MeetingAgentProbeCacheEntry: Codable, Hashable, Sendable {
    var key: MeetingAgentProbeKey
    var date: Date
}

/// Keeps ready probe results across launches. Only a ready result is kept.
nonisolated protocol MeetingAgentProbeCacheStoring: Sendable {
    func entry(for cli: MeetingAgentCLI) -> MeetingAgentProbeCacheEntry?
    func setEntry(_ entry: MeetingAgentProbeCacheEntry?, for cli: MeetingAgentCLI)
}

/// The kept results in `UserDefaults` (`meetings.agentProbeCache`, one JSON
/// value: CLI → path, version, modification date, argument revision, date).
/// It holds no private text.
nonisolated struct MeetingAgentDefaultsProbeCache: MeetingAgentProbeCacheStoring {
    static let key = "meetings.agentProbeCache"

    func entry(for cli: MeetingAgentCLI) -> MeetingAgentProbeCacheEntry? {
        all()[cli.rawValue]
    }

    func setEntry(_ entry: MeetingAgentProbeCacheEntry?, for cli: MeetingAgentCLI) {
        var entries = all()
        entries[cli.rawValue] = entry
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func all() -> [String: MeetingAgentProbeCacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
            let entries = try? JSONDecoder().decode(
                [String: MeetingAgentProbeCacheEntry].self, from: data)
        else { return [:] }
        return entries
    }
}

/// Checks a CLI before Rafu offers it, with fixed text only (the decision
/// record about a meeting agent with no visible terminal: the probe is a
/// hidden run with no per-run user action and no user text). Steps:
///
/// 1. `--version` by the resolved path (5 s, 4 KB). No version → failed.
/// 2. Codex only: the tool-list capture (`MeetingAgentToolListCapturing`).
/// 3. A small real run with the same array, the four-key environment and a
///    new 0700 folder. Claude Code reads a fixed meeting copy; Codex gets a
///    fixed packet in an empty folder. The run must answer, use no tool
///    outside the checked set and leave the folder as it was.
///
/// A ready result is kept for one path, version, modification date and
/// argument revision, in memory and in `UserDefaults`. Other results are
/// kept in memory only. One probe for each CLI at a time: a second caller
/// waits for the same probe.
actor MeetingAgentProber: MeetingAgentProbeService {
    private let processRunner: any MeetingAgentProcessRunning
    private let locator: any MeetingAgentLocating
    private let environment: [String: String]
    private let runsRoot: URL
    private let versionTimeLimit: Duration
    private let runTimeLimit: Duration
    private let cache: any MeetingAgentProbeCacheStoring
    private let toolListCapture: (any MeetingAgentToolListCapturing)?
    private let clock: @Sendable () -> Date

    private struct Known: Sendable {
        var path: String
        var modified: Date?
        var result: MeetingAgentProbeResult
        var version: String?
    }

    private var known: [MeetingAgentCLI: Known] = [:]
    private var inFlight: [MeetingAgentCLI: Task<Known, Never>] = [:]

    init(
        processRunner: any MeetingAgentProcessRunning,
        locator: any MeetingAgentLocating,
        environment: [String: String],
        runsRoot: URL,
        versionTimeLimit: Duration = MeetingAgentLimits.versionProbeTimeLimit,
        runTimeLimit: Duration = MeetingAgentLimits.probeTimeLimit,
        cache: any MeetingAgentProbeCacheStoring = MeetingAgentDefaultsProbeCache(),
        toolListCapture: (any MeetingAgentToolListCapturing)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processRunner = processRunner
        self.locator = locator
        self.environment = environment
        self.runsRoot = runsRoot
        self.versionTimeLimit = versionTimeLimit
        self.runTimeLimit = runTimeLimit
        self.cache = cache
        self.toolListCapture = toolListCapture
        self.clock = clock
    }

    // MARK: - Service

    func probe(_ cli: MeetingAgentCLI, refresh: Bool) async -> MeetingAgentProbeResult {
        if let running = inFlight[cli] { return await running.value.result }
        guard let executable = locator.locate(cli) else {
            known[cli] = nil
            return .notInstalled
        }
        if !refresh, let kept = known[cli], kept.path == executable.resolvedPath,
            kept.modified == executable.modified
        {
            return kept.result
        }
        // Set before the first await: a second caller joins this probe.
        let task = Task { await self.check(cli, executable: executable, refresh: refresh) }
        inFlight[cli] = task
        let outcome = await task.value
        inFlight[cli] = nil
        known[cli] = outcome
        if outcome.result == .ready, let version = outcome.version {
            cache.setEntry(
                MeetingAgentProbeCacheEntry(
                    key: Self.key(executable, version: version), date: clock()), for: cli)
        } else {
            cache.setEntry(nil, for: cli)
        }
        return outcome.result
    }

    func lastResult(of cli: MeetingAgentCLI) async -> MeetingAgentProbeResult? {
        guard let executable = locator.locate(cli) else { return .notInstalled }
        if let kept = known[cli], kept.path == executable.resolvedPath,
            kept.modified == executable.modified
        {
            return kept.result
        }
        guard let entry = cache.entry(for: cli), entry.key.path == executable.resolvedPath,
            entry.key.modified == executable.modified?.timeIntervalSince1970,
            entry.key.revision == MeetingAgentArguments.revision
        else { return nil }
        return .ready
    }

    func readyVersion(of cli: MeetingAgentCLI) async -> String? {
        guard let kept = known[cli], kept.result == .ready else { return nil }
        return kept.version
    }

    func invalidate(_ cli: MeetingAgentCLI) async {
        known[cli] = nil
        cache.setEntry(nil, for: cli)
    }

    // MARK: - Steps

    private func check(
        _ cli: MeetingAgentCLI, executable: MeetingAgentExecutable, refresh: Bool
    ) async -> Known {
        func known(_ result: MeetingAgentProbeResult, _ version: String?) -> Known {
            Known(
                path: executable.resolvedPath, modified: executable.modified, result: result,
                version: version)
        }
        guard let version = await readVersion(executable) else {
            return known(.failed(reason: .versionUnreadable), nil)
        }
        if !refresh, cache.entry(for: cli)?.key == Self.key(executable, version: version) {
            return known(.ready, version)
        }
        switch cli {
        case .claudeCode:
            return known(await probeClaude(executable, version: version), version)
        case .codex:
            if let toolListCapture,
                let failure = await toolListCapture.check(
                    executable, version: version, environment: environment, runsRoot: runsRoot,
                    processRunner: processRunner)
            {
                return known(failure, version)
            }
            return known(await probeCodex(executable), version)
        }
    }

    private static func key(_ executable: MeetingAgentExecutable, version: String)
        -> MeetingAgentProbeKey
    {
        MeetingAgentProbeKey(
            path: executable.resolvedPath, version: version,
            modified: executable.modified?.timeIntervalSince1970,
            revision: MeetingAgentArguments.revision)
    }

    /// `--version` (argument array, the same four-key environment, 5 s
    /// limit, 4 KB).
    private func readVersion(_ executable: MeetingAgentExecutable) async -> String? {
        let spec = MeetingAgentProcessSpec(
            executableURL: URL(fileURLWithPath: executable.resolvedPath),
            arguments: MeetingAgentArguments.versionProbe, environment: environment,
            currentDirectoryURL: FileManager.default.temporaryDirectory, standardInput: nil)
        guard
            let result = try? await MeetingAgentDrive.run(
                spec, parser: MeetingAgentVersionCollector(), processRunner: processRunner,
                timeLimit: versionTimeLimit,
                maximumOutputBytes: MeetingAgentLimits.maximumVersionOutputBytes),
            result.end == .finished, result.termination == .exited(0)
        else { return nil }
        return MeetingAgentVersionRule.version(fromVersionOutput: result.parser.firstLine ?? "")
    }

    /// Claude Code reads a fixed meeting copy. The init event must be the
    /// checked one and name the same version as `--version`; the result
    /// must be an answer; the folder must be unchanged.
    private func probeClaude(_ executable: MeetingAgentExecutable, version: String) async
        -> MeetingAgentProbeResult
    {
        let run: MeetingAgentRunFolders.Run
        do {
            run = try MeetingAgentRunFolders.make(in: runsRoot)
        } catch {
            return .failed(reason: .launchFailed)
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let folder = run.emptyFolder
        let files = [
            "meeting.md": MeetingAgentProbeTexts.meetingFile,
            "transcript.md": MeetingAgentProbeTexts.transcriptFile,
            "question.md": MeetingAgentProbeTexts.questionFile,
        ]
        for (name, text) in files {
            guard
                FileManager.default.createFile(
                    atPath: folder.appendingPathComponent(name, isDirectory: false).path,
                    contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
            else { return .failed(reason: .launchFailed) }
        }
        let before = Self.contentHashes(of: folder)

        let spec = MeetingAgentProcessSpec(
            executableURL: executable.url,
            arguments: MeetingAgentArguments.claude(
                prompt: MeetingAgentPrompts.claudePromptArgument),
            environment: environment, currentDirectoryURL: folder, standardInput: nil)
        let result: MeetingAgentDrive.Result<ClaudeStreamParser>
        do {
            result = try await MeetingAgentDrive.run(
                spec, parser: ClaudeStreamParser(), processRunner: processRunner,
                timeLimit: runTimeLimit)
        } catch {
            return .failed(reason: .launchFailed)
        }
        let parser = result.parser
        if parser.notLoggedIn { return .notSignedIn }
        if parser.initCheck == .refused { return .unsupportedVersion(found: version) }
        if parser.forbiddenTool { return .failed(reason: .toolEvent) }
        switch result.end {
        case .finished: break
        case .timedOut: return .failed(reason: .timedOut)
        case .stopped, .outputTooLarge, .cancelled: return .failed(reason: .noAnswer)
        }
        guard parser.initCheck == .accepted, parser.cliVersion == version else {
            return .unsupportedVersion(found: version)
        }
        guard result.termination == .exited(0), let answer = parser.answer,
            (try? MeetingAgentAnswerText.clean(answer)) != nil
        else { return .failed(reason: .noAnswer) }
        guard Self.contentHashes(of: folder) == before,
            MeetingAgentRunFolders.entries(of: run.root) == ["e"]
        else { return .failed(reason: .wroteFiles) }
        return .ready
    }

    /// Codex gets a fixed packet in an empty folder. The turn must complete
    /// with an answer, every item must be of an allowed type, and the run
    /// root must hold only the empty folder afterwards.
    private func probeCodex(_ executable: MeetingAgentExecutable) async -> MeetingAgentProbeResult {
        let run: MeetingAgentRunFolders.Run
        do {
            run = try MeetingAgentRunFolders.make(in: runsRoot)
        } catch {
            return .failed(reason: .launchFailed)
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        // The resolved file: see `MeetingAgentRunner.runCodex`.
        let spec = MeetingAgentProcessSpec(
            executableURL: URL(fileURLWithPath: executable.resolvedPath),
            arguments: MeetingAgentArguments.codex(emptyFolder: run.emptyFolder),
            environment: environment, currentDirectoryURL: run.emptyFolder,
            standardInput: Data(MeetingAgentProbeTexts.codexPacket.utf8))
        let result: MeetingAgentDrive.Result<CodexStreamParser>
        do {
            result = try await MeetingAgentDrive.run(
                spec, parser: CodexStreamParser(), processRunner: processRunner,
                timeLimit: runTimeLimit)
        } catch {
            return .failed(reason: .launchFailed)
        }
        let parser = result.parser
        if parser.unrecognizedSetting { return .failed(reason: .settingNotKnown) }
        if parser.notSignedIn { return .notSignedIn }
        if parser.toolEvent { return .failed(reason: .toolEvent) }
        guard MeetingAgentRunFolders.isUntouched(run) else { return .failed(reason: .wroteFiles) }
        switch result.end {
        case .finished: break
        case .timedOut: return .failed(reason: .timedOut)
        case .stopped, .outputTooLarge, .cancelled: return .failed(reason: .noAnswer)
        }
        guard result.termination == .exited(0), let answer = parser.answer,
            (try? MeetingAgentAnswerText.clean(answer)) != nil
        else { return .failed(reason: .noAnswer) }
        return .ready
    }

    /// The name and SHA-256 of each entry of `folder` (a non-regular entry
    /// gets a mark instead of a hash).
    static func contentHashes(of folder: URL) -> [String: String] {
        var result: [String: String] = [:]
        for name in MeetingAgentRunFolders.entries(of: folder) {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                let data = FileManager.default.contents(atPath: url.path)
            else {
                result[name] = "not a regular file"
                continue
            }
            result[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

/// The Codex tool-list check of a probe (step 2). Returns nil when the
/// tools are the checked ones, else the probe result.
nonisolated protocol MeetingAgentToolListCapturing: Sendable {
    func check(
        _ executable: MeetingAgentExecutable, version: String, environment: [String: String],
        runsRoot: URL, processRunner: any MeetingAgentProcessRunning
    ) async -> MeetingAgentProbeResult?
}
