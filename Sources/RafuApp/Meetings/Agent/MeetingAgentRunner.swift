import Foundation
import RafuCore

/// The hidden meeting agent (the decision record about a meeting agent with
/// no visible terminal, ADR 0046). On one explicit user action it starts the
/// user's Claude Code or Codex with no visible terminal, limited to one
/// stopped meeting, and returns an answer with checked citations, or
/// speaker-name suggestions.
///
/// - Claude Code reads a frozen copy of the meeting (`meeting.md`,
///   `transcript.md`, and `question.md` that holds the rules and the
///   question). Its working directory is that copy. Its init event is
///   checked before an answer counts.
/// - Codex gets the packet (rules, question, meeting text) on standard
///   input. Its working directory is a new empty 0700 folder.
///
/// Private text is never in a process argument, an environment value or a
/// diagnostics event. The reply is untrusted data: bounded, cleaned, never
/// run and never used as a path. One run for each meeting at a time.
actor MeetingAgentRunner: MeetingAgentRunning, MeetingAgentAvailabilityChecking {
    typealias StoreProvider = @Sendable () async -> (any MeetingStoring)?

    private let storeProvider: StoreProvider
    private let diagnostics: any MeetingDiagnosticsRecording
    private let processRunner: any MeetingAgentProcessRunning
    private let locator: any MeetingAgentLocating
    private let runsRoot: URL
    private let timeLimit: Duration
    private let versionTimeLimit: Duration
    private let environment: [String: String]
    private let clock: @Sendable () -> Date

    private var running: Set<MeetingID> = []
    private var codexVersions: [String: CachedVersion] = [:]

    private struct CachedVersion {
        var modified: Date?
        var version: String?
    }

    init(
        store: @escaping StoreProvider,
        diagnostics: any MeetingDiagnosticsRecording,
        processRunner: any MeetingAgentProcessRunning = MeetingAgentSystemProcessRunner(),
        locator: any MeetingAgentLocating = MeetingAgentExecutableLocator(),
        runsRoot: URL = MeetingAgentRunFolders.defaultRunsRoot,
        timeLimit: Duration = MeetingAgentLimits.timeLimit,
        versionTimeLimit: Duration = MeetingAgentLimits.versionProbeTimeLimit,
        environment: [String: String] = MeetingAgentEnvironment.make(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeProvider = store
        self.diagnostics = diagnostics
        self.processRunner = processRunner
        self.locator = locator
        self.runsRoot = runsRoot
        self.timeLimit = timeLimit
        self.versionTimeLimit = versionTimeLimit
        self.environment = environment
        self.clock = clock
    }

    // MARK: - Public API

    func ask(_ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> MeetingAgentReply
    {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= MeetingAgentLimits.maximumQuestionCharacters
        else { throw MeetingAgentError.failed }
        guard case .answer(let run) = try await perform(.user(trimmed), meeting: meeting, cli: cli)
        else { throw MeetingAgentError.failed }

        let ids = MeetingCitationParser.citations(in: run.text)
        let check: MeetingCitationCheck
        do {
            check = try await run.library.verifyCitations(
                ids.map { MeetingCitation(turn: $0, quote: "") }, in: meeting)
        } catch {
            record(run, outcome: .failed, citations: 0, failed: 0, meeting: meeting)
            throw MeetingAgentError.failed
        }
        let reply = MeetingAgentReply(cli: cli, text: run.text, citations: check.verified)
        do {
            let now = clock()
            try await run.library.appendConversation(
                MeetingConversationEntry(date: now, role: .question, text: trimmed), to: meeting)
            try await run.library.appendConversation(
                MeetingConversationEntry(
                    date: now, role: .answer, text: reply.text, cli: cli,
                    citations: check.verified),
                to: meeting)
        } catch {
            record(run, outcome: .failed, citations: 0, failed: 0, meeting: meeting)
            throw MeetingAgentError.failed
        }
        record(
            run, outcome: .answered, citations: check.verified.count, failed: check.failedCount,
            meeting: meeting)
        return reply
    }

    func suggestSpeakerNames(for meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> [MeetingSpeakerLabel: String]
    {
        guard case .answer(let run) = try await perform(.speakerNames, meeting: meeting, cli: cli)
        else { return [:] }
        let parsed: MeetingNameSuggestionsReply
        do {
            parsed = try MeetingNameReplyParser.parse(run.text)
        } catch {
            record(run, outcome: .failed, citations: 0, failed: 0, meeting: meeting)
            throw MeetingAgentError.failed
        }
        record(run, outcome: .answered, citations: 0, failed: 0, meeting: meeting)
        return parsed.names.filter { run.labels.contains($0.key) }
    }

    func availability(of cli: MeetingAgentCLI) async -> MeetingAgentAvailability {
        guard let executable = locator.locate(cli) else { return .notInstalled }
        switch cli {
        case .claudeCode:
            return .ready
        case .codex:
            let version = await codexVersion(of: executable)
            return MeetingAgentVersionRule.isSupportedCodex(version: version)
                ? .ready : .unsupportedVersion(found: version ?? "unknown")
        }
    }

    // MARK: - One run

    private enum Request {
        case user(String)
        case speakerNames
    }

    private struct RunSuccess {
        var library: any MeetingLibraryServicing
        var cli: MeetingAgentCLI
        var text: String
        var cliVersion: String?
        var exitCode: Int32?
        var wallSeconds: Double
        /// The speaker labels of the meeting (name suggestions only).
        var labels: Set<MeetingSpeakerLabel>
    }

    private enum RunResult {
        case answer(RunSuccess)
        /// A name-suggestion run for a meeting with no speaker to name.
        case nothingToAsk
    }

    /// The failure facts of a run that started a process.
    private struct RunFailure: Error {
        var error: MeetingAgentError
        var outcome: MeetingAgentRunOutcome
        var cliVersion: String?
        var exitCode: Int32?
    }

    private func perform(_ request: Request, meeting: MeetingID, cli: MeetingAgentCLI)
        async throws -> RunResult
    {
        // Busy check and claim before the first await, so two calls can never
        // both pass it.
        guard !running.contains(meeting) else { throw MeetingAgentError.busy }
        running.insert(meeting)
        defer { running.remove(meeting) }

        guard let library = await storeProvider() as? any MeetingLibraryServicing else {
            throw MeetingAgentError.failed
        }
        let summary: MeetingSummaryRecord?
        do {
            summary = try await library.summary(of: meeting)
        } catch {
            throw MeetingAgentError.failed
        }
        guard let summary, summary.state == .ready else { throw MeetingAgentError.meetingNotReady }

        let question: String
        var labels: Set<MeetingSpeakerLabel> = []
        switch request {
        case .user(let text):
            question = text
        case .speakerNames:
            let shown: [(label: MeetingSpeakerLabel, shownAs: String)]
            do {
                shown = Self.nameableLabels(in: try await library.document(of: meeting))
            } catch {
                throw MeetingAgentError.failed
            }
            if shown.isEmpty { return .nothingToAsk }
            labels = Set(shown.map(\.label))
            question = MeetingAgentPrompts.speakerNamesQuestion(labels: shown)
        }
        let kind: MeetingAgentRunKind = if case .user = request { .question } else { .speakerNames }

        guard let executable = locator.locate(cli) else {
            recordUserError(MeetingAgentError.notInstalled(cli), meeting: meeting)
            throw MeetingAgentError.notInstalled(cli)
        }
        if Task.isCancelled { throw MeetingAgentError.cancelled }

        let started = ContinuousClock.now
        do {
            let (text, version, exit): (String, String?, Int32?)
            switch cli {
            case .claudeCode:
                (text, version, exit) = try await runClaude(
                    executable: executable, question: question, kind: kind, library: library,
                    meeting: meeting)
            case .codex:
                (text, version, exit) = try await runCodex(
                    executable: executable, question: question, kind: kind, library: library,
                    meeting: meeting)
            }
            return .answer(
                RunSuccess(
                    library: library, cli: cli, text: text, cliVersion: version, exitCode: exit,
                    wallSeconds: Self.seconds(since: started), labels: labels))
        } catch let failure as RunFailure {
            diagnostics.record(
                .agentRun(
                    cli: cli, cliVersion: failure.cliVersion.map { MeetingDiagnosticString($0) },
                    exitCode: failure.exitCode, wallSeconds: Self.seconds(since: started),
                    replyBytes: 0, citations: 0, failedCitations: 0, outcome: failure.outcome),
                meeting: meeting)
            throw failure.error
        } catch let error as MeetingAgentError {
            recordUserError(error, meeting: meeting)
            throw error
        }
    }

    // MARK: Claude Code

    private func runClaude(
        executable: MeetingAgentExecutable, question: String, kind: MeetingAgentRunKind,
        library: any MeetingLibraryServicing, meeting: MeetingID
    ) async throws -> (String, String?, Int32?) {
        let snapshot: MeetingAgentSnapshot
        do {
            snapshot = try await library.makeAgentSnapshot(of: meeting)
        } catch {
            throw MeetingAgentError.failed
        }
        defer { snapshot.remove() }
        let questionURL = snapshot.folder.appendingPathComponent("question.md", isDirectory: false)
        guard
            FileManager.default.createFile(
                atPath: questionURL.path,
                contents: Data(
                    MeetingAgentPrompts.questionFile(question: question, kind: kind).utf8),
                attributes: [.posixPermissions: 0o600])
        else { throw MeetingAgentError.failed }

        let spec = MeetingAgentProcessSpec(
            executableURL: executable.url,
            arguments: MeetingAgentArguments.claude(
                prompt: MeetingAgentPrompts.claudePromptArgument),
            environment: environment, currentDirectoryURL: snapshot.folder, standardInput: nil)
        let (parser, end, termination) = try await drive(spec, parser: ClaudeStreamParser())
        let version = parser.cliVersion
        let exitCode = termination?.exitCode
        func fail(_ error: MeetingAgentError, _ outcome: MeetingAgentRunOutcome) -> RunFailure {
            RunFailure(error: error, outcome: outcome, cliVersion: version, exitCode: exitCode)
        }

        if parser.initCheck == .refused {
            throw fail(.unsupportedVersion(.claudeCode), .failed)
        }
        if parser.notLoggedIn { throw fail(.notSignedIn(.claudeCode), .notSignedIn) }
        try Self.checkEnd(end, fail: fail)
        guard parser.initCheck == .accepted else {
            throw fail(.unsupportedVersion(.claudeCode), .failed)
        }
        guard termination == .exited(0), let answer = parser.answer else {
            throw fail(.failed, .failed)
        }
        return (try Self.cleaned(answer, fail: fail), version, exitCode)
    }

    // MARK: Codex

    private func runCodex(
        executable: MeetingAgentExecutable, question: String, kind: MeetingAgentRunKind,
        library: any MeetingLibraryServicing, meeting: MeetingID
    ) async throws -> (String, String?, Int32?) {
        let version = await codexVersion(of: executable)
        guard MeetingAgentVersionRule.isSupportedCodex(version: version) else {
            throw MeetingAgentError.unsupportedVersion(.codex)
        }
        let meetingText: String
        do {
            meetingText = try await library.agentPacketText(of: meeting)
        } catch {
            throw MeetingAgentError.failed
        }
        let packet = Data(
            MeetingAgentPrompts.codexPacket(
                question: question, kind: kind, meetingText: meetingText
            )
            .utf8)
        guard packet.count <= MeetingAgentLimits.maximumPacketBytes else {
            throw MeetingAgentError.transcriptTooLarge
        }
        let run: MeetingAgentRunFolders.Run
        do {
            run = try MeetingAgentRunFolders.make(in: runsRoot)
        } catch {
            throw MeetingAgentError.failed
        }
        defer { try? FileManager.default.removeItem(at: run.root) }

        // Launch the resolved file, not the Homebrew link: under the `meeting`
        // permission profile Codex's file-system sandbox helper re-executes
        // the launch path, and the `/opt/homebrew/bin` link is outside the
        // readable set ("sandbox-exec: execvp() … Operation not permitted",
        // checked 2026-11-23 with Codex 0.171.0). The re-check used the
        // resolved Caskroom path.
        let spec = MeetingAgentProcessSpec(
            executableURL: URL(fileURLWithPath: executable.resolvedPath),
            arguments: MeetingAgentArguments.codex(emptyFolder: run.emptyFolder),
            environment: environment, currentDirectoryURL: run.emptyFolder, standardInput: packet)
        let (parser, end, termination) = try await drive(spec, parser: CodexStreamParser())
        let exitCode = termination?.exitCode
        func fail(_ error: MeetingAgentError, _ outcome: MeetingAgentRunOutcome) -> RunFailure {
            RunFailure(error: error, outcome: outcome, cliVersion: version, exitCode: exitCode)
        }

        if parser.notSignedIn { throw fail(.notSignedIn(.codex), .notSignedIn) }
        if parser.unrecognizedSetting { throw fail(.unsupportedVersion(.codex), .failed) }
        try Self.checkEnd(end, fail: fail)
        guard termination == .exited(0), let answer = parser.answer else {
            throw fail(.failed, .failed)
        }
        return (try Self.cleaned(answer, fail: fail), version, exitCode)
    }

    // MARK: Codex version

    /// `codex --version` (argument array, the same four-key environment,
    /// 5 s limit), kept for one executable path and modification date.
    private func codexVersion(of executable: MeetingAgentExecutable) async -> String? {
        if let cached = codexVersions[executable.resolvedPath],
            cached.modified == executable.modified
        {
            return cached.version
        }
        let spec = MeetingAgentProcessSpec(
            executableURL: executable.url, arguments: MeetingAgentArguments.versionProbe,
            environment: environment, currentDirectoryURL: FileManager.default.temporaryDirectory,
            standardInput: nil)
        guard
            let probe = try? await drive(
                spec, parser: VersionCollector(), timeLimit: versionTimeLimit,
                maximumOutputBytes: MeetingAgentLimits.maximumVersionOutputBytes),
            probe.1 == .finished, probe.2 == .exited(0)
        else { return nil }
        let version = MeetingAgentVersionRule.version(fromVersionOutput: probe.0.firstLine ?? "")
        codexVersions[executable.resolvedPath] = CachedVersion(
            modified: executable.modified, version: version)
        return version
    }

    /// Keeps the first line of the `--version` output.
    private struct VersionCollector: MeetingAgentStreamParsing {
        var firstLine: String?

        mutating func consume(line: Data) -> MeetingAgentStreamVerdict {
            if firstLine == nil { firstLine = String(decoding: line, as: UTF8.self) }
            return .more
        }
    }

    // MARK: - Process driving

    enum DriveEnd: Equatable {
        /// Standard output ended and the process exited.
        case finished
        /// The parser asked to end the process.
        case stopped
        case outputTooLarge
        case timedOut
        case cancelled
    }

    private enum DriveStep<P: MeetingAgentStreamParsing>: Sendable {
        case read(P, DriveEnd)
        case timedOut
        case timerEnded
    }

    /// Starts the process and reads its output with the parser until the
    /// end, a stop, the byte limit, the time limit or cancellation. The
    /// process is always ended before this returns.
    private func drive<P: MeetingAgentStreamParsing>(
        _ spec: MeetingAgentProcessSpec, parser: P, timeLimit: Duration? = nil,
        maximumOutputBytes: Int = MeetingAgentLimits.maximumOutputBytes
    ) async throws -> (P, DriveEnd, MeetingAgentTermination?) {
        if Task.isCancelled { throw MeetingAgentError.cancelled }
        let handle: any MeetingAgentProcessHandle
        do {
            handle = try processRunner.start(spec)
        } catch {
            throw RunFailure(error: .failed, outcome: .failed, cliVersion: nil, exitCode: nil)
        }
        let limit = timeLimit ?? self.timeLimit
        let (finalParser, end) = await withTaskCancellationHandler {
            await withTaskGroup(of: DriveStep<P>.self) { group -> (P, DriveEnd) in
                group.addTask {
                    await Self.read(
                        handle, parser: parser, maximumOutputBytes: maximumOutputBytes)
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: limit)
                        return .timedOut
                    } catch {
                        return .timerEnded
                    }
                }
                var timedOut = false
                var didRead = false
                var result: (P, DriveEnd) = (parser, .cancelled)
                while let step = await group.next() {
                    switch step {
                    case .read(let finished, let end):
                        didRead = true
                        result = (finished, end)
                        group.cancelAll()
                    case .timedOut:
                        // A reader that already ended wins over a late timer.
                        guard !didRead else { break }
                        timedOut = true
                        handle.terminate()
                        group.cancelAll()
                    case .timerEnded:
                        break
                    }
                }
                if timedOut { return (result.0, .timedOut) }
                if Task.isCancelled { return (result.0, .cancelled) }
                return result
            }
        } onCancel: {
            handle.terminate()
        }
        handle.terminate()
        let termination = await handle.termination()
        return (finalParser, end, termination)
    }

    private static func read<P: MeetingAgentStreamParsing>(
        _ handle: any MeetingAgentProcessHandle, parser: P, maximumOutputBytes: Int
    ) async -> DriveStep<P> {
        var parser = parser
        var splitter = MeetingAgentLineSplitter(maximumOutputBytes: maximumOutputBytes)
        for await chunk in handle.output {
            let lines: [Data]
            do {
                lines = try splitter.append(chunk)
            } catch {
                handle.terminate()
                return .read(parser, .outputTooLarge)
            }
            for line in lines where parser.consume(line: line) == .stop {
                handle.terminate()
                return .read(parser, .stopped)
            }
        }
        if Task.isCancelled { return .read(parser, .cancelled) }
        if let last = splitter.finish(), parser.consume(line: last) == .stop {
            handle.terminate()
            return .read(parser, .stopped)
        }
        // The exit is inside the time limit too.
        _ = await handle.termination()
        return .read(parser, .finished)
    }

    // MARK: - Helpers

    private static func checkEnd(
        _ end: DriveEnd, fail: (MeetingAgentError, MeetingAgentRunOutcome) -> RunFailure
    ) throws {
        switch end {
        case .finished: return
        case .timedOut: throw fail(.timedOut, .timedOut)
        case .cancelled: throw fail(.cancelled, .cancelled)
        case .outputTooLarge: throw fail(.replyTooLarge, .failed)
        case .stopped: throw fail(.failed, .failed)
        }
    }

    private static func cleaned(
        _ answer: String, fail: (MeetingAgentError, MeetingAgentRunOutcome) -> RunFailure
    ) throws -> String {
        do {
            return try MeetingAgentAnswerText.clean(answer)
        } catch .tooLarge {
            throw fail(.replyTooLarge, .failed)
        } catch {
            throw fail(.failed, .failed)
        }
    }

    /// The labels that can get a name: each speaker of a shown turn except
    /// `me`, in the order of their first turn, with the name shown for it.
    static func nameableLabels(in document: MeetingDocument)
        -> [(label: MeetingSpeakerLabel, shownAs: String)]
    {
        var seen = Set<MeetingSpeakerLabel>()
        var result: [(label: MeetingSpeakerLabel, shownAs: String)] = []
        for turn in document.shownTurns(includeEcho: false)
        where turn.speaker != .me && seen.insert(turn.speaker).inserted {
            result.append((turn.speaker, document.displayName(for: turn.speaker)))
        }
        return result
    }

    private func record(
        _ run: RunSuccess, outcome: MeetingAgentRunOutcome, citations: Int, failed: Int,
        meeting: MeetingID
    ) {
        diagnostics.record(
            .agentRun(
                cli: run.cli, cliVersion: run.cliVersion.map { MeetingDiagnosticString($0) },
                exitCode: run.exitCode, wallSeconds: run.wallSeconds,
                replyBytes: run.text.utf8.count, citations: citations, failedCitations: failed,
                outcome: outcome),
            meeting: meeting)
    }

    private func recordUserError(_ error: MeetingAgentError, meeting: MeetingID) {
        diagnostics.record(
            .userFacingError(
                place: .agent, domain: MeetingDiagnosticString("agent.\(Self.code(of: error))"),
                code: 0),
            meeting: meeting)
    }

    /// A short stable code for an error, with no private text.
    static func code(of error: MeetingAgentError) -> String {
        switch error {
        case .notInstalled: "notInstalled"
        case .unsupportedVersion: "unsupportedVersion"
        case .notSignedIn: "notSignedIn"
        case .meetingNotReady: "meetingNotReady"
        case .busy: "busy"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        case .replyTooLarge: "replyTooLarge"
        case .transcriptTooLarge: "transcriptTooLarge"
        case .failed: "failed"
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
