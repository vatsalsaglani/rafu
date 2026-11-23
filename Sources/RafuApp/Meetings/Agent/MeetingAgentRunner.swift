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
///   checked before an answer counts, and a tool call outside Glob, Grep and
///   Read ends the run.
/// - Codex gets the packet (rules, question, meeting text) on standard
///   input. Its working directory is a new empty 0700 folder.
///
/// Private text is never in a process argument, an environment value or a
/// diagnostics event. The reply is untrusted data: bounded, cleaned, never
/// run and never used as a path. One run of each kind for each meeting at a
/// time (a question can run while the summary runs).
actor MeetingAgentRunner: MeetingAgentRunning, MeetingAgentAvailabilityChecking,
    MeetingAgentStreaming, MeetingAgentProbing, MeetingAgentSummarizing
{
    typealias StoreProvider = @Sendable () async -> (any MeetingStoring)?
    /// Called at the start (`true`) and at the end (`false`) of each run.
    typealias ActivitySink = @Sendable (MeetingID, MeetingAgentActivity, Bool) async -> Void
    /// Receives the events of a streamed answer.
    typealias StreamSink = @Sendable (MeetingAgentStreamEvent) -> Void

    private let storeProvider: StoreProvider
    private let diagnostics: any MeetingDiagnosticsRecording
    private let processRunner: any MeetingAgentProcessRunning
    private let locator: any MeetingAgentLocating
    private let runsRoot: URL
    private let timeLimit: Duration
    private let versionTimeLimit: Duration
    private let environment: [String: String]
    private let clock: @Sendable () -> Date
    private let activity: ActivitySink
    private let prober: any MeetingAgentProbeService

    /// The cancel action of the run in each lane.
    private var lanes: [Lane: @Sendable () -> Void] = [:]

    private struct Lane: Hashable {
        var meeting: MeetingID
        var kind: MeetingAgentRunKind
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
        clock: @escaping @Sendable () -> Date = { Date() },
        activity: @escaping ActivitySink = { _, _, _ in },
        prober: (any MeetingAgentProbeService)? = nil
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
        self.activity = activity
        self.prober =
            prober
            ?? MeetingAgentProber(
                processRunner: processRunner, locator: locator, environment: environment,
                runsRoot: runsRoot, versionTimeLimit: versionTimeLimit,
                toolListCapture: MeetingAgentCodexToolListCapture())
    }

    // MARK: - Public API

    func ask(_ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> MeetingAgentReply
    {
        try await ask(question, about: meeting, using: cli, sink: nil)
    }

    nonisolated func askStream(
        _ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI
    ) -> AsyncThrowingStream<MeetingAgentStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<MeetingAgentStreamEvent, Error>
            .makeStream()
        let task = Task {
            do {
                let reply = try await self.ask(
                    question, about: meeting, using: cli, sink: { continuation.yield($0) })
                continuation.yield(.finished(reply))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        // The consumer stopped iterating (or the stream ended): end the run.
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func cancelRun(_ kind: MeetingAgentRunKind, for meeting: MeetingID) async {
        lanes[Lane(meeting: meeting, kind: kind)]?()
    }

    func suggestSpeakerNames(for meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> [MeetingSpeakerLabel: String]
    {
        switch try await suggestSpeakerNameResult(for: meeting, using: cli) {
        case .names(let names): names
        case .noNamesFound, .nothingToName: [:]
        }
    }

    func suggestSpeakerNameResult(for meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> MeetingNameSuggestionResult
    {
        guard
            case .answer(let run) = try await perform(
                .speakerNames, meeting: meeting, cli: cli, sink: nil)
        else { return .nothingToName }
        let parsed: MeetingNameSuggestionsReply
        do {
            parsed = try MeetingNameReplyParser.parse(run.text)
        } catch {
            record(run, outcome: .failed, citations: 0, failed: 0, meeting: meeting)
            throw MeetingAgentError.failed
        }
        record(run, outcome: .answered, citations: 0, failed: 0, meeting: meeting)
        let names = parsed.names.filter { run.labels.contains($0.key) }
        return names.isEmpty ? .noNamesFound : .names(names)
    }

    /// Starts no process: the kept probe result. A CLI with no kept result
    /// shows as ready; its first run probes it.
    func availability(of cli: MeetingAgentCLI) async -> MeetingAgentAvailability {
        guard locator.locate(cli) != nil else { return .notInstalled }
        switch await prober.lastResult(of: cli) {
        case nil, .ready?, .notSignedIn?: return .ready
        case .notInstalled?: return .notInstalled
        case .unsupportedVersion(let found)?: return .unsupportedVersion(found: found)
        case .failed?: return .unsupportedVersion(found: "unknown")
        }
    }

    func probe(_ cli: MeetingAgentCLI, refresh: Bool) async -> MeetingAgentProbeResult {
        await prober.probe(cli, refresh: refresh)
    }

    // MARK: - Summary

    /// The title and summary of one meeting (one run of kind `summary`).
    /// The notes carry the text revision that the agent read; the caller
    /// saves them.
    func summarize(_ meeting: MeetingID, using cli: MeetingAgentCLI) async throws
        -> MeetingSummaryNotes
    {
        guard
            case .answer(let run) = try await perform(
                .summary, meeting: meeting, cli: cli, sink: nil)
        else { throw MeetingAgentError.failed }
        let notes: MeetingSummaryNotes
        do {
            let known = Set(try await run.library.document(of: meeting).turns.map(\.id))
            notes = try MeetingSummaryReplyParser.parse(
                run.text, knownTurns: known, cli: cli, date: clock(),
                textRevision: run.textRevision ?? 0)
        } catch {
            record(run, outcome: .failed, citations: 0, failed: 0, meeting: meeting)
            throw MeetingAgentError.failed
        }
        record(
            run, outcome: .answered, citations: notes.citations.count, failed: 0, meeting: meeting)
        return notes
    }

    // MARK: - Question

    private func ask(
        _ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI,
        sink: StreamSink?
    ) async throws -> MeetingAgentReply {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= MeetingAgentLimits.maximumQuestionCharacters
        else { throw MeetingAgentError.failed }
        guard
            case .answer(let run) = try await perform(
                .user(trimmed), meeting: meeting, cli: cli, sink: sink)
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
                MeetingConversationEntry(
                    date: now, role: .question, text: trimmed, textRevision: run.textRevision),
                to: meeting)
            try await run.library.appendConversation(
                MeetingConversationEntry(
                    date: now, role: .answer, text: reply.text, cli: cli,
                    citations: check.verified, textRevision: run.textRevision),
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

    // MARK: - One run

    private enum Request: Sendable {
        case user(String)
        case speakerNames
        case summary

        var kind: MeetingAgentRunKind {
            switch self {
            case .user: .question
            case .speakerNames: .speakerNames
            case .summary: .summary
            }
        }
    }

    private struct RunSuccess: Sendable {
        var library: any MeetingLibraryServicing
        var cli: MeetingAgentCLI
        var text: String
        var cliVersion: String?
        var exitCode: Int32?
        var wallSeconds: Double
        /// The speaker labels of the meeting (name suggestions only).
        var labels: Set<MeetingSpeakerLabel>
        /// The text revision of the meeting that the agent read, when the
        /// library knows it.
        var textRevision: Int?
    }

    private enum RunResult: Sendable {
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

    /// Claims the lane of this meeting and kind, runs the request in a task
    /// that `cancelRun` can cancel, and reports the start and the end of
    /// the run to the activity sink.
    private func perform(
        _ request: Request, meeting: MeetingID, cli: MeetingAgentCLI, sink: StreamSink?
    ) async throws -> RunResult {
        // Busy check and claim before the first await, so two calls can
        // never both pass it.
        let lane = Lane(meeting: meeting, kind: request.kind)
        guard lanes[lane] == nil else { throw MeetingAgentError.busy }
        let work = Task {
            try await self.performClaimed(request, meeting: meeting, cli: cli, sink: sink)
        }
        lanes[lane] = { work.cancel() }
        let started = MeetingAgentActivity(kind: request.kind, cli: cli, started: clock())
        await activity(meeting, started, true)

        let outcome: Result<RunResult, any Error>
        do {
            outcome = .success(
                try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                })
        } catch {
            outcome = .failure(error)
        }
        lanes[lane] = nil
        await activity(meeting, started, false)
        return try outcome.get()
    }

    private func performClaimed(
        _ request: Request, meeting: MeetingID, cli: MeetingAgentCLI, sink: StreamSink?
    ) async throws -> RunResult {
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
        let textRevision = try? await (library as? any MeetingNotesStoring)?.textRevision(
            of: meeting)

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
        case .summary:
            question = MeetingAgentPrompts.summaryQuestion
        }
        let kind = request.kind

        guard let executable = locator.locate(cli) else {
            recordUserError(MeetingAgentError.notInstalled(cli), meeting: meeting)
            throw MeetingAgentError.notInstalled(cli)
        }
        if Task.isCancelled { throw MeetingAgentError.cancelled }
        if let notReady = await probeBeforeRun(cli) {
            recordUserError(notReady, meeting: meeting)
            throw notReady
        }
        if Task.isCancelled { throw MeetingAgentError.cancelled }

        let started = ContinuousClock.now
        do {
            let (text, version, exit): (String, String?, Int32?)
            switch cli {
            case .claudeCode:
                (text, version, exit) = try await runClaude(
                    executable: executable, question: question, kind: kind, library: library,
                    meeting: meeting, sink: sink)
            case .codex:
                (text, version, exit) = try await runCodex(
                    executable: executable, question: question, kind: kind, library: library,
                    meeting: meeting, sink: sink)
            }
            return .answer(
                RunSuccess(
                    library: library, cli: cli, text: text, cliVersion: version, exitCode: exit,
                    wallSeconds: Self.seconds(since: started), labels: labels,
                    textRevision: textRevision))
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
        library: any MeetingLibraryServicing, meeting: MeetingID, sink: StreamSink?
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
        let result = try await drive(
            spec, parser: ClaudeStreamParser(), onEvent: Self.claudeEvents(to: sink))
        let parser = result.parser
        let version = parser.cliVersion
        let exitCode = result.termination?.exitCode
        func fail(_ error: MeetingAgentError, _ outcome: MeetingAgentRunOutcome) -> RunFailure {
            RunFailure(error: error, outcome: outcome, cliVersion: version, exitCode: exitCode)
        }

        if parser.initCheck == .refused || parser.forbiddenTool || parser.notLoggedIn {
            // The kept probe result no longer holds.
            await prober.invalidate(.claudeCode)
        }
        if parser.initCheck == .refused {
            throw fail(.unsupportedVersion(.claudeCode), .failed)
        }
        if parser.forbiddenTool { throw fail(.failed, .failed) }
        if parser.notLoggedIn { throw fail(.notSignedIn(.claudeCode), .notSignedIn) }
        try Self.checkEnd(result.end, fail: fail)
        guard parser.initCheck == .accepted else {
            throw fail(.unsupportedVersion(.claudeCode), .failed)
        }
        guard result.termination == .exited(0), let answer = parser.answer else {
            throw fail(.failed, .failed)
        }
        return (try Self.cleaned(answer, fail: fail), version, exitCode)
    }

    /// Streamed Claude Code text goes to the sink as it comes.
    private static func claudeEvents(to sink: StreamSink?)
        -> (@Sendable (MeetingAgentDriveEvent) -> Void)?
    {
        guard let sink else { return nil }
        return { event in
            switch event {
            case .started:
                sink(.started)
            case .text(let pieces):
                for piece in pieces {
                    switch piece {
                    case .delta(let text): sink(.textDelta(text))
                    case .reset: sink(.textReset)
                    }
                }
            }
        }
    }

    /// Only the start goes to the sink (Codex streams no text).
    private static func startOnly(to sink: StreamSink?)
        -> (@Sendable (MeetingAgentDriveEvent) -> Void)?
    {
        guard let sink else { return nil }
        return { event in
            if case .started = event { sink(.started) }
        }
    }

    // MARK: Codex

    private func runCodex(
        executable: MeetingAgentExecutable, question: String, kind: MeetingAgentRunKind,
        library: any MeetingLibraryServicing, meeting: MeetingID, sink: StreamSink?
    ) async throws -> (String, String?, Int32?) {
        let version = await prober.readyVersion(of: .codex)
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
        let result = try await drive(
            spec, parser: CodexStreamParser(), onEvent: Self.startOnly(to: sink))
        let parser = result.parser
        let exitCode = result.termination?.exitCode
        func fail(_ error: MeetingAgentError, _ outcome: MeetingAgentRunOutcome) -> RunFailure {
            RunFailure(error: error, outcome: outcome, cliVersion: version, exitCode: exitCode)
        }
        // Codex shows no tool list and its stream is not a full audit log:
        // each run checks that it wrote no file, with the item-type rule.
        let wroteFiles = !MeetingAgentRunFolders.isUntouched(run)
        if parser.notSignedIn || parser.unrecognizedSetting || parser.toolEvent || wroteFiles {
            await prober.invalidate(.codex)
        }
        if wroteFiles { throw fail(.failed, .failed) }
        if parser.notSignedIn { throw fail(.notSignedIn(.codex), .notSignedIn) }
        if parser.unrecognizedSetting { throw fail(.unsupportedVersion(.codex), .failed) }
        if parser.toolEvent { throw fail(.failed, .failed) }
        try Self.checkEnd(result.end, fail: fail)
        guard result.termination == .exited(0), let answer = parser.answer else {
            throw fail(.failed, .failed)
        }
        let text = try Self.cleaned(answer, fail: fail)
        // Codex streams no text: the whole answer comes as one piece at the end.
        sink?(.textDelta(text))
        return (text, version, exitCode)
    }

    // MARK: Probe

    /// Nil when the CLI is ready. A kept result that is not ready is probed
    /// again: a run is an explicit user action, and the user may have
    /// signed in since.
    private func probeBeforeRun(_ cli: MeetingAgentCLI) async -> MeetingAgentError? {
        var result = await prober.probe(cli, refresh: false)
        if !result.isReady, result != .notInstalled {
            result = await prober.probe(cli, refresh: true)
        }
        switch result {
        case .ready: return nil
        case .notInstalled: return .notInstalled(cli)
        case .notSignedIn: return .notSignedIn(cli)
        case .unsupportedVersion: return .unsupportedVersion(cli)
        case .failed: return .failed
        }
    }

    // MARK: - Process driving

    /// Runs the process with the runner's time limit. A process that did not
    /// start, or a cancel before the start, is a run failure.
    private func drive<P: MeetingAgentStreamParsing>(
        _ spec: MeetingAgentProcessSpec, parser: P,
        onEvent: (@Sendable (MeetingAgentDriveEvent) -> Void)? = nil
    ) async throws -> MeetingAgentDrive.Result<P> {
        do {
            return try await MeetingAgentDrive.run(
                spec, parser: parser, processRunner: processRunner, timeLimit: timeLimit,
                onEvent: onEvent)
        } catch is CancellationError {
            throw MeetingAgentError.cancelled
        } catch {
            throw RunFailure(error: .failed, outcome: .failed, cliVersion: nil, exitCode: nil)
        }
    }

    // MARK: - Helpers

    private static func checkEnd(
        _ end: MeetingAgentDriveEnd, fail: (MeetingAgentError, MeetingAgentRunOutcome) -> RunFailure
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

/// Keeps the first line of the `--version` output.
nonisolated struct MeetingAgentVersionCollector: MeetingAgentStreamParsing {
    var firstLine: String?

    mutating func consume(line: Data) -> MeetingAgentStreamVerdict {
        if firstLine == nil { firstLine = String(decoding: line, as: UTF8.self) }
        return .more
    }
}

/// What the summary coordinator needs from the runner. Tests inject a fake.
nonisolated protocol MeetingAgentSummarizing: MeetingAgentProbing {
    func summarize(_ meeting: MeetingID, using cli: MeetingAgentCLI) async throws
        -> MeetingSummaryNotes
    func cancelRun(_ kind: MeetingAgentRunKind, for meeting: MeetingID) async
}
