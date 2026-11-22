import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: runner")
struct MeetingAgentRunnerTests {
    typealias S = AgentStreamLines

    private static let question = "When do we ship the quokka build?"

    private func codexAnswer(_ text: String) -> FakeAgentBehaviour {
        .lines(
            [S.codexThread, S.codexTurnStarted, S.codexMessage(text), S.codexTurnCompleted],
            exit: 0)
    }

    private func claudeAnswer(_ text: String) -> FakeAgentBehaviour {
        .lines([S.claudeInit, S.claudeResult(text)], exit: 0)
    }

    // 1
    @Test("Codex gets the note's array, a new empty 0700 folder and the packet on standard input")
    func codexSpec() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([codexAnswer("Ships March 14 [t2].")])
        let runner = library.makeRunner(process)

        let reply = try await runner.ask(Self.question, about: meeting, using: .codex)
        #expect(reply.text == "Ships March 14 [t2].")

        let run = try #require(process.runs.first)
        #expect(process.runs.count == 1)
        let folder = run.spec.currentDirectoryURL
        #expect(run.spec.arguments == MeetingAgentArguments.codex(emptyFolder: folder))
        #expect(run.directoryExisted)
        #expect(run.directoryEntries.isEmpty)
        #expect(run.directoryMode == 0o700)
        #expect(folder.path.hasPrefix(library.runsRoot.path))
        let stdin = String(decoding: try #require(run.spec.standardInput), as: UTF8.self)
        #expect(stdin.contains(Self.question))
        #expect(stdin.contains(AgentTestLibrary.marker))
        #expect(Set(run.spec.environment.keys) == MeetingAgentEnvironment.keys)
        Self.expectNoPrivateText(in: run.spec)
        // The run root is removed.
        #expect(library.leftovers().isEmpty)
        // The version probe holds no private text either.
        let probe = try #require(process.starts.first { $0.spec.arguments == ["--version"] })
        #expect(probe.spec.standardInput == nil)
        #expect(Set(probe.spec.environment.keys) == MeetingAgentEnvironment.keys)
    }

    // 2
    @Test("Claude Code reads only the meeting copy; the copy is gone after success")
    func claudeSpec() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([claudeAnswer("Ships March 14 [t2].")])
        let runner = library.makeRunner(process)

        _ = try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        let run = try #require(process.runs.first)
        #expect(run.directoryEntries == ["meeting.md", "question.md", "transcript.md"])
        #expect(run.spec.standardInput == nil)
        #expect(
            run.spec.arguments
                == MeetingAgentArguments.claude(prompt: MeetingAgentPrompts.claudePromptArgument))
        #expect(Set(run.spec.environment.keys) == MeetingAgentEnvironment.keys)
        Self.expectNoPrivateText(in: run.spec)
        #expect(!FileManager.default.fileExists(atPath: run.spec.currentDirectoryURL.path))
        #expect(library.leftovers().isEmpty)
    }

    @Test("The Claude Code copy is removed after a failure and after a cancel")
    func claudeCopyRemovedOnFailureAndCancel() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .lines([S.claudeInit], exit: 1), .hang([S.claudeInit]),
        ])
        let runner = library.makeRunner(process)

        await #expect(throws: MeetingAgentError.failed) {
            try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        }
        #expect(library.leftovers().isEmpty)

        let task = Task { try await runner.ask(Self.question, about: meeting, using: .claudeCode) }
        var starts = process.started.makeAsyncIterator()
        _ = await starts.next()
        _ = await starts.next()
        task.cancel()
        await #expect(throws: MeetingAgentError.cancelled) { try await task.value }
        #expect(process.runHandles.last?.terminateCalls == 1)
        #expect(library.leftovers().isEmpty)
        #expect(try await library.store.conversation(of: meeting).isEmpty)
    }

    // 3
    @Test("A good answer keeps the checked citations and is stored with its question")
    func goodAnswerStored() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let diagnostics = AgentTestDiagnostics()
        let process = FakeAgentProcessRunner([codexAnswer("Ships March 14 [t2]. Also [t99].")])
        let runner = library.makeRunner(process, diagnostics: diagnostics)

        let reply = try await runner.ask("  \(Self.question)  ", about: meeting, using: .codex)
        #expect(reply.cli == .codex)
        #expect(reply.citations.map(\.turn) == [MeetingTurnID(2)])

        let conversation = try await library.store.conversation(of: meeting)
        #expect(conversation.map(\.role) == [.question, .answer])
        #expect(conversation.first?.text == Self.question)
        #expect(conversation.last?.text == reply.text)
        #expect(conversation.last?.cli == .codex)
        #expect(conversation.last?.citations.map(\.turn) == [MeetingTurnID(2)])

        let run = try #require(diagnostics.agentRuns.first)
        #expect(diagnostics.agentRuns.count == 1)
        guard
            case .agentRun(
                let cli, let version, let exitCode, _, let replyBytes, let citations, let failed,
                let outcome) = run
        else { return }
        #expect(cli == .codex)
        #expect(version?.value == "0.171.0")
        #expect(exitCode == 0)
        #expect(replyBytes == reply.text.utf8.count)
        #expect(citations == 1)
        #expect(failed == 1)
        #expect(outcome == .answered)
    }

    // 4
    @Test("Not signed in ends each CLI early and stores nothing")
    func notSignedIn() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .hang([S.codexThread, S.codexTurnStarted, S.codex401, S.codex401]),
            .hang([S.claudeUIEvent, S.claudeInit, S.claudeNotLoggedIn]),
        ])
        let diagnostics = AgentTestDiagnostics()
        let runner = library.makeRunner(process, diagnostics: diagnostics)

        await #expect(throws: MeetingAgentError.notSignedIn(.codex)) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        await #expect(throws: MeetingAgentError.notSignedIn(.claudeCode)) {
            try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        }
        #expect(process.runHandles.map(\.terminateCalls) == [1, 1])
        #expect(try await library.store.conversation(of: meeting).isEmpty)
        #expect(library.leftovers().isEmpty)
        let outcomes = diagnostics.agentRuns.compactMap { event -> MeetingAgentRunOutcome? in
            if case .agentRun(_, _, _, _, _, _, _, let outcome) = event { return outcome }
            return nil
        }
        #expect(outcomes == [.notSignedIn, .notSignedIn])
    }

    // 5
    @Test("A Claude Code init event that is not the checked one ends the run before the result")
    func badInitEvent() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let badInit = S.claudeInit.replacingOccurrences(
            of: #"["Glob","Grep","Read"]"#, with: #"["Bash","Glob","Grep","Read"]"#)
        let process = FakeAgentProcessRunner([.hang([badInit, S.claudeResult("Ships [t2]")])])
        let runner = library.makeRunner(process)

        await #expect(throws: MeetingAgentError.unsupportedVersion(.claudeCode)) {
            try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        }
        #expect(process.runHandles.first?.terminateCalls == 1)
        #expect(try await library.store.conversation(of: meeting).isEmpty)
    }

    // 6
    @Test("The time limit ends the process")
    func timeLimit() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([.hang([S.codexThread])])
        let runner = library.makeRunner(process, timeLimit: .milliseconds(100))

        await #expect(throws: MeetingAgentError.timedOut) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        #expect(process.runHandles.first?.terminateCalls == 1)
        #expect(library.leftovers().isEmpty)
    }

    @Test("Cancel ends the Codex process and removes the run folder")
    func cancelCodex() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([.hang([S.codexThread])])
        let runner = library.makeRunner(process)

        let task = Task { try await runner.ask(Self.question, about: meeting, using: .codex) }
        var starts = process.started.makeAsyncIterator()
        _ = await starts.next()
        task.cancel()
        await #expect(throws: MeetingAgentError.cancelled) { try await task.value }
        #expect(process.runHandles.first?.terminateCalls == 1)
        #expect(library.leftovers().isEmpty)
    }

    // 7
    @Test("A second question for the same meeting during a run is busy")
    func busy() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([.hang([S.claudeInit])])
        let runner = library.makeRunner(process)

        let first = Task { try await runner.ask(Self.question, about: meeting, using: .claudeCode) }
        var starts = process.started.makeAsyncIterator()
        _ = await starts.next()
        await #expect(throws: MeetingAgentError.busy) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        first.cancel()
        await #expect(throws: MeetingAgentError.cancelled) { try await first.value }
        #expect(process.runs.count == 1)
    }

    @Test("A meeting that is still processing is not ready, and no process starts")
    func notReady() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting(state: .processing)
        let process = FakeAgentProcessRunner([])
        let runner = library.makeRunner(process)

        await #expect(throws: MeetingAgentError.meetingNotReady) {
            try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        }
        await #expect(throws: MeetingAgentError.meetingNotReady) {
            try await runner.suggestSpeakerNames(for: meeting, using: .codex)
        }
        #expect(process.starts.isEmpty)
    }

    // 8
    @Test("A reply over the limit is refused; a packet over the limit starts no process")
    func oversize() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            codexAnswer(String(repeating: "a", count: MeetingAgentLimits.maximumAnswerBytes + 1))
        ])
        let runner = library.makeRunner(process)
        await #expect(throws: MeetingAgentError.replyTooLarge) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        #expect(try await library.store.conversation(of: meeting).isEmpty)

        let long = try await library.makeMeeting(
            turnText: String(repeating: "word ", count: 2_000), turnCount: 70)
        let quiet = FakeAgentProcessRunner([])
        let second = library.makeRunner(quiet)
        await #expect(throws: MeetingAgentError.transcriptTooLarge) {
            try await second.ask(Self.question, about: long, using: .codex)
        }
        #expect(quiet.runs.isEmpty)
        #expect(library.leftovers().isEmpty)
    }

    @Test("An empty or too long question starts no process")
    func questionBounds() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([])
        let runner = library.makeRunner(process)
        await #expect(throws: MeetingAgentError.failed) {
            try await runner.ask("   ", about: meeting, using: .claudeCode)
        }
        await #expect(throws: MeetingAgentError.failed) {
            try await runner.ask(
                String(repeating: "q", count: MeetingAgentLimits.maximumQuestionCharacters + 1),
                about: meeting, using: .claudeCode)
        }
        #expect(process.starts.isEmpty)
    }

    // 9
    @Test("Name suggestions drop a label that is not in the meeting and store nothing")
    func nameSuggestions() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let before = try #require(try await library.store.summary(of: meeting))
        let reply =
            #"{"speaker-1": {"name": "Priya", "evidence": ["t2"]}, "speaker-7": {"name": "Ghost", "evidence": ["t3"]}, "me": {"name": "Vee", "evidence": ["t1"]}}"#
        let escaped = reply.replacingOccurrences(of: "\"", with: "\\\"")
        let process = FakeAgentProcessRunner([claudeAnswer(escaped)])
        let runner = library.makeRunner(process)

        let names = try await runner.suggestSpeakerNames(for: meeting, using: .claudeCode)
        #expect(names == [.speaker(1): "Priya"])

        let file = try #require(process.runs.first)
        #expect(file.directoryEntries == ["meeting.md", "question.md", "transcript.md"])
        #expect(try await library.store.conversation(of: meeting).isEmpty)
        #expect(try await library.store.speakerNames(of: meeting).isEmpty)
        #expect(try await library.store.summary(of: meeting)?.version == before.version)
        #expect(library.leftovers().isEmpty)
    }

    @Test("Codex name suggestions send the label list on standard input")
    func codexNameSuggestions() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let reply = #"{\"speaker-2\": {\"name\": \"Ann\", \"evidence\": [\"t3\"]}}"#
        let process = FakeAgentProcessRunner([codexAnswer(reply)])
        let runner = library.makeRunner(process)

        let names = try await runner.suggestSpeakerNames(for: meeting, using: .codex)
        #expect(names == [.speaker(2): "Ann"])
        let stdin = String(
            decoding: try #require(process.runs.first?.spec.standardInput), as: UTF8.self)
        #expect(stdin.contains("- speaker-1: Speaker 1"))
        #expect(stdin.contains("- speaker-2: Speaker 2"))
        #expect(!stdin.contains("- me:"))
    }

    // 10
    @Test("A Codex version that was not checked is not available and starts no exec")
    func unsupportedCodexVersion() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([], versionOutput: "codex-cli 0.172.0")
        let runner = library.makeRunner(process)

        #expect(await runner.availability(of: .codex) == .unsupportedVersion(found: "0.172.0"))
        await #expect(throws: MeetingAgentError.unsupportedVersion(.codex)) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        #expect(process.runs.isEmpty)
        // The version is kept for the same executable: one probe only.
        #expect(process.starts.count == 1)
        #expect(await runner.availability(of: .claudeCode) == .ready)
        #expect(process.starts.count == 1)
    }

    @Test("A CLI that is not installed is reported and starts nothing")
    func notInstalled() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([])
        let runner = library.makeRunner(process, locator: FakeAgentLocator(installed: []))
        #expect(await runner.availability(of: .claudeCode) == .notInstalled)
        #expect(await runner.availability(of: .codex) == .notInstalled)
        await #expect(throws: MeetingAgentError.notInstalled(.codex)) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        #expect(process.starts.isEmpty)
    }

    @Test("A Codex setting that no longer works makes the version not supported")
    func unrecognizedSetting() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .hang([S.codexThread, S.codexUnrecognized, S.codexMessage("x")])
        ])
        let runner = library.makeRunner(process)
        await #expect(throws: MeetingAgentError.unsupportedVersion(.codex)) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        #expect(process.runHandles.first?.terminateCalls == 1)
    }

    @Test("An answer with a non-zero exit is a failure")
    func nonZeroExit() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .lines([S.claudeInit, S.claudeResult("Ships [t2]")], exit: 1)
        ])
        let runner = library.makeRunner(process)
        await #expect(throws: MeetingAgentError.failed) {
            try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        }
        #expect(try await library.store.conversation(of: meeting).isEmpty)
    }

    /// No marker, no question word and no title in the arguments or the
    /// environment.
    private static func expectNoPrivateText(in spec: MeetingAgentProcessSpec) {
        let visible = (spec.arguments + spec.environment.keys + spec.environment.values)
            .joined(separator: " ")
        for word in [AgentTestLibrary.marker, "quokka", "ship", "Sync", "March"] {
            #expect(!visible.contains(word), "found \(word)")
        }
        #expect(!spec.environment.keys.contains { $0.hasPrefix("RAFU") })
    }
}

/// The parser test lines, shared through this app-test file (the core
/// test target is a different module).
enum AgentStreamLines {
    static let claudeInit =
        #"{"type":"system","subtype":"init","cwd":"/D","tools":["Glob","Grep","Read"],"mcp_servers":[],"model":"claude-haiku-5-5","permissionMode":"dontAsk","claude_code_version":"2.1.330"}"#
    static let claudeUIEvent = #"{"type":"system","subtype":"ui_invalidate","event":"ui.render"}"#
    static func claudeResult(_ text: String, isError: Bool = false) -> String {
        #"{"type":"result","subtype":"success","is_error":\#(isError),"result":"\#(text)"}"#
    }
    static let claudeNotLoggedIn = claudeResult("Not logged in · Please run /login", isError: true)

    static let codexThread = #"{"type":"thread.started","thread_id":"01a2"}"#
    static let codexTurnStarted = #"{"type":"turn.started"}"#
    static func codexMessage(_ text: String) -> String {
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"\#(text)"}}"#
    }
    static let codexTurnCompleted = #"{"type":"turn.completed","usage":{"input_tokens":6901}}"#
    static let codex401 =
        #"{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header)"}"#
    static let codexUnrecognized =
        #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings."}}"#
}
