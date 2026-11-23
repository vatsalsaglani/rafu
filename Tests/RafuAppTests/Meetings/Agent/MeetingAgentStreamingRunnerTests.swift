import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: streamed answers, lanes and name results")
struct MeetingAgentStreamingRunnerTests {
    typealias S = AgentStreamLines

    private static let question = "When do we ship the quokka build?"
    private static let messageStart =
        #"{"type":"stream_event","event":{"type":"message_start","message":{"content":[]}},"parent_tool_use_id":null}"#

    private static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"parent_tool_use_id":null}"#
    }

    private func collect(_ stream: AsyncThrowingStream<MeetingAgentStreamEvent, Error>)
        async throws -> [MeetingAgentStreamEvent]
    {
        var events: [MeetingAgentStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test("Claude Code streams its deltas, then the final answer")
    func claudeStream() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .lines(
                [
                    S.claudeInit, Self.messageStart, Self.delta("Ships"), Self.delta(" March 14"),
                    S.claudeResult("Ships March 14 [t2]."),
                ], exit: 0)
        ])
        let runner = library.makeRunner(process)

        let events = try await collect(
            runner.askStream(Self.question, about: meeting, using: .claudeCode))
        let reply = MeetingAgentReply(
            cli: .claudeCode, text: "Ships March 14 [t2].",
            citations: [MeetingCitation(turn: MeetingTurnID(2), quote: "")])
        #expect(
            events == [
                .started, .textReset, .textDelta("Ships"), .textDelta(" March 14"),
                .finished(reply),
            ])
        #expect(
            try await library.store.conversation(of: meeting).map(\.role) == [.question, .answer])
    }

    @Test("Codex gives one delta at the end, then the final answer")
    func codexStream() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .lines(
                [
                    S.codexThread, S.codexTurnStarted, S.codexMessage("Ships [t2]."),
                    S.codexTurnCompleted,
                ],
                exit: 0)
        ])
        let runner = library.makeRunner(process)
        let events = try await collect(
            runner.askStream(Self.question, about: meeting, using: .codex))
        #expect(events.count == 3)
        #expect(events.first == .started)
        #expect(events.dropFirst().first == .textDelta("Ships [t2]."))
        guard case .finished(let reply) = events.last else {
            Issue.record("no finished event")
            return
        }
        #expect(reply.cli == .codex)
    }

    @Test("A failed stream ends with the error and stores nothing")
    func streamError() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([.hang([S.claudeInit, S.claudeNotLoggedIn])])
        let runner = library.makeRunner(process)
        await #expect(throws: MeetingAgentError.notSignedIn(.claudeCode)) {
            _ = try await collect(
                runner.askStream(Self.question, about: meeting, using: .claudeCode))
        }
        #expect(try await library.store.conversation(of: meeting).isEmpty)
    }

    @Test("Ending the iteration of a stream ends the process")
    func streamTerminationCancels() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([.hang([S.claudeInit, Self.delta("Ships")])])
        let log = AgentActivityLog()
        let runner = library.makeRunner(process, activity: log.sink)

        let (gate, opened) = AsyncStream<[MeetingAgentStreamEvent]>.makeStream()
        let consumer = Task {
            var seen: [MeetingAgentStreamEvent] = []
            for try await event in runner.askStream(
                Self.question, about: meeting, using: .claudeCode)
            {
                seen.append(event)
                if seen.count == 2 { opened.yield(seen) }
            }
        }
        var gates = gate.makeAsyncIterator()
        #expect(await gates.next() == [.started, .textDelta("Ships")])
        consumer.cancel()
        await log.waitForEnd(of: .question)
        #expect(process.runHandles.first?.terminateCalls == 1)
        #expect(try await library.store.conversation(of: meeting).isEmpty)
        #expect(library.leftovers().isEmpty)
    }

    @Test("Same kind twice is busy; another kind for the same meeting runs")
    func lanes() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let names = #"{\"speaker-2\": {\"name\": \"Ann\", \"evidence\": [\"t3\"]}}"#
        let process = FakeAgentProcessRunner([
            .hang([S.claudeInit]),
            .lines([S.claudeInit, S.claudeResult(names)], exit: 0),
        ])
        let log = AgentActivityLog()
        let runner = library.makeRunner(process, activity: log.sink)

        let first = Task { try await runner.ask(Self.question, about: meeting, using: .claudeCode) }
        var starts = process.started.makeAsyncIterator()
        _ = await starts.next()
        await #expect(throws: MeetingAgentError.busy) {
            try await runner.ask(Self.question, about: meeting, using: .codex)
        }
        let result = try await runner.suggestSpeakerNameResult(for: meeting, using: .claudeCode)
        #expect(result == .names([.speaker(2): "Ann"]))

        await runner.cancelRun(.question, for: meeting)
        await #expect(throws: MeetingAgentError.cancelled) { try await first.value }
        #expect(process.runHandles.first?.terminateCalls == 1)

        let entries = log.entries
        #expect(
            entries.filter(\.isRunning).map(\.kind).sorted { $0.rawValue < $1.rawValue }
                == [.question, .speakerNames])
        #expect(entries.filter { !$0.isRunning }.count == 2)
    }

    @Test("Each run reports its start and its end, after success, error and cancel")
    func activity() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .lines([S.claudeInit, S.claudeResult("Ships [t2]")], exit: 0),
            .lines([S.claudeInit], exit: 1),
            .hang([S.claudeInit]),
        ])
        let log = AgentActivityLog()
        let runner = library.makeRunner(process, activity: log.sink)

        _ = try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        await #expect(throws: MeetingAgentError.failed) {
            try await runner.ask(Self.question, about: meeting, using: .claudeCode)
        }
        let task = Task { try await runner.ask(Self.question, about: meeting, using: .claudeCode) }
        var starts = process.started.makeAsyncIterator()
        _ = await starts.next()
        _ = await starts.next()
        _ = await starts.next()
        task.cancel()
        await #expect(throws: MeetingAgentError.cancelled) { try await task.value }

        #expect(log.entries.map(\.isRunning) == [true, false, true, false, true, false])
        #expect(log.entries.allSatisfy { $0.kind == .question && $0.cli == .claudeCode })
    }

    @Test("No names found and nothing to name are told apart")
    func nameResults() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let solo = try await library.makeMeOnlyMeeting()
        let process = FakeAgentProcessRunner([
            .lines([S.claudeInit, S.claudeResult("{}")], exit: 0),
            .lines(
                [
                    S.claudeInit,
                    S.claudeResult(
                        #"{\"speaker-7\": {\"name\": \"Ghost\", \"evidence\": [\"t3\"]}}"#),
                ], exit: 0),
        ])
        let runner = library.makeRunner(process)
        #expect(
            try await runner.suggestSpeakerNameResult(for: meeting, using: .claudeCode)
                == .noNamesFound)
        // A name for a label that is not in the meeting is dropped: none found.
        #expect(
            try await runner.suggestSpeakerNameResult(for: meeting, using: .claudeCode)
                == .noNamesFound)
        #expect(
            try await runner.suggestSpeakerNameResult(for: solo, using: .claudeCode)
                == .nothingToName)
        #expect(process.runs.count == 2)
        #expect(try await runner.suggestSpeakerNames(for: solo, using: .claudeCode).isEmpty)
    }
}
