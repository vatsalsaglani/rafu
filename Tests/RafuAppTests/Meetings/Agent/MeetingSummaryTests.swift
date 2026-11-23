import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: summary")
@MainActor
struct MeetingSummaryTests {
    typealias S = AgentStreamLines

    private static let defaultTitle = MeetingDefaultTitle.text(for: Date())

    private struct Defaults {
        let name = "rafu-summary-test-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() { defaults = UserDefaults(suiteName: name)! }

        func remove() { defaults.removePersistentDomain(forName: name) }
    }

    nonisolated private static func notes(_ cli: MeetingAgentCLI, revision: Int)
        -> MeetingSummaryNotes
    {
        MeetingSummaryNotes(
            title: "Quokka launch plan", summaryMarkdown: "Ships on March 14 [t2].",
            citations: [MeetingTurnID(2)], cli: cli, date: Date(timeIntervalSince1970: 1),
            textRevision: revision)
    }

    private func coordinator(
        _ session: MeetingsSessionModel, _ agent: FakeSummarizer, _ library: AgentTestLibrary,
        _ defaults: Defaults
    ) -> MeetingSummaryCoordinator {
        let store = library.store
        let coordinator = MeetingSummaryCoordinator(
            session: session, agent: agent, store: { store }, defaults: defaults.defaults)
        coordinator.install()
        return coordinator
    }

    // MARK: Runner

    @Test("The runner writes notes from a summary reply; a question can run at the same time")
    func runnerSummarize() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let reply =
            #"{\"title\": \"Quokka plan\", \"summary\": \"Ships [t2] [t9].\", \"actionItems\": [{\"text\": \"Notes\", \"owner\": \"Priya\", \"turns\": [\"t3\"]}]}"#
        let process = FakeAgentProcessRunner([
            .hang([S.claudeInit]),
            .lines([S.claudeInit, S.claudeResult(reply)], exit: 0),
        ])
        let runner = library.makeRunner(process)
        let question = Task {
            try await runner.ask("When do we ship?", about: meeting, using: .claudeCode)
        }
        var starts = process.started.makeAsyncIterator()
        _ = await starts.next()

        let notes = try await runner.summarize(meeting, using: .claudeCode)
        #expect(notes.title == "Quokka plan")
        #expect(notes.citations == [MeetingTurnID(2), MeetingTurnID(3)])
        #expect(notes.actionItems.first?.owner == "Priya")
        #expect(notes.textRevision == 0)
        #expect(notes.cli == .claudeCode)
        let file = try #require(process.runs.last)
        #expect(file.directoryEntries == ["meeting.md", "question.md", "transcript.md"])
        // Nothing is saved by the runner.
        #expect(try await library.store.summaryNotes(of: meeting) == nil)

        question.cancel()
        await #expect(throws: MeetingAgentError.cancelled) { try await question.value }
    }

    @Test("A summary reply that is not the JSON shape fails")
    func runnerBadReply() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let process = FakeAgentProcessRunner([
            .lines([S.claudeInit, S.claudeResult("Here is a summary.")], exit: 0)
        ])
        let runner = library.makeRunner(process)
        await #expect(throws: MeetingAgentError.failed) {
            try await runner.summarize(meeting, using: .claudeCode)
        }
    }

    // MARK: Coordinator

    @Test("With the Settings switch off, processing starts no summary")
    func switchOff() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        defaults.defaults.set(false, forKey: MeetingAutoSummaryPreference.key)
        let meeting = try await library.makeMeeting()
        let agent = FakeSummarizer { _, cli in Self.notes(cli, revision: 0) }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)

        session.summaryHandlers.afterProcessing(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(session.summaryStates[meeting] == nil)
        #expect(session.summaryStepActive.isEmpty)
        #expect(agent.summarized.isEmpty)

        // A user action still writes it.
        session.makeSummary(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(session.summaryStates[meeting] == .ready)
    }

    @Test("With no agent ready the summary is unavailable and no run starts")
    func noAgent() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        let meeting = try await library.makeMeeting()
        let agent = FakeSummarizer([.claudeCode: .notSignedIn, .codex: .notInstalled]) { _, cli in
            Self.notes(cli, revision: 0)
        }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)

        session.summaryHandlers.afterProcessing(meeting)
        #expect(session.summaryStates[meeting] == .generating)
        #expect(session.summaryStepActive == [meeting])
        await coordinator.waitForRun(of: meeting)
        #expect(session.summaryStates[meeting] == .unavailable)
        #expect(session.summaryStepActive.isEmpty)
        #expect(agent.summarized.isEmpty)
    }

    @Test("Success saves the notes, sets the agent title and uses the last agent first")
    func success() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        defaults.defaults.set(
            MeetingAgentCLI.codex.rawValue, forKey: MeetingDetailModel.lastAgentKey)
        let meeting = try await library.makeMeeting(title: Self.defaultTitle)
        let agent = FakeSummarizer { _, cli in Self.notes(cli, revision: 0) }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)
        let revision = session.libraryRevision

        session.summaryHandlers.afterProcessing(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(agent.summarized == [.codex])
        #expect(session.summaryStates[meeting] == .ready)
        #expect(session.summaryStepActive.isEmpty)
        #expect(session.libraryRevision > revision)
        #expect(try await library.store.summaryNotes(of: meeting)?.cli == .codex)
        #expect(try await library.store.summary(of: meeting)?.title == "Quokka launch plan")
    }

    @Test("A title that the user gave is kept")
    func userTitleKept() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        let meeting = try await library.makeMeeting(title: "Weekly sync")
        let agent = FakeSummarizer { _, cli in Self.notes(cli, revision: 0) }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)
        session.summaryHandlers.afterProcessing(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(agent.summarized == [.claudeCode])
        #expect(session.summaryStates[meeting] == .ready)
        #expect(try await library.store.summary(of: meeting)?.title == "Weekly sync")
    }

    @Test("Cancel ends the run, saves nothing and shows the state on disk")
    func cancel() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        let meeting = try await library.makeMeeting()
        let agent = FakeSummarizer { _, _ in
            // Waits until the run is cancelled.
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                throw MeetingAgentError.cancelled
            }
            throw MeetingAgentError.failed
        }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)

        session.summaryHandlers.afterProcessing(meeting)
        var started = agent.started.makeAsyncIterator()
        _ = await started.next()
        session.cancelSummary(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(session.summaryStates[meeting] == MeetingSummaryState.none)
        #expect(session.summaryStepActive.isEmpty)
        #expect(try await library.store.summaryNotes(of: meeting) == nil)
    }

    @Test("Notes for a text that was made again during the run are not saved")
    func textRemadeDuringRun() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        let meeting = try await library.makeMeeting(title: Self.defaultTitle)
        let store = library.store
        let agent = FakeSummarizer { meeting, cli in
            // The text is made again while the agent reads the old one.
            let version = try #require(try await store.summary(of: meeting)).version
            let turns = try await store.turns(of: meeting, after: nil, limit: 10).turns
            _ = try await store.replaceTurns(turns, in: meeting, expectedVersion: version)
            return Self.notes(cli, revision: 0)
        }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)
        session.summaryHandlers.afterProcessing(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(session.summaryStates[meeting] == .stale)
        #expect(try await library.store.summaryNotes(of: meeting) == nil)
        #expect(try await library.store.summary(of: meeting)?.title == Self.defaultTitle)
    }

    @Test("A failed run shows the error")
    func failure() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        let meeting = try await library.makeMeeting()
        let agent = FakeSummarizer { _, _ in throw MeetingAgentError.timedOut }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)
        session.summaryHandlers.afterProcessing(meeting)
        await coordinator.waitForRun(of: meeting)
        #expect(session.summaryStates[meeting] == .failed(.timedOut))
        #expect(session.summaryStepActive.isEmpty)
    }

    @Test("Refresh reads one notes file: ready, stale or none")
    func refresh() async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let defaults = Defaults()
        defer { defaults.remove() }
        let meeting = try await library.makeMeeting()
        let agent = FakeSummarizer { _, cli in Self.notes(cli, revision: 0) }
        let session = MeetingsSessionModel()
        let coordinator = coordinator(session, agent, library, defaults)

        await coordinator.refreshNow(meeting)
        #expect(session.summaryStates[meeting] == MeetingSummaryState.none)

        session.summaryStates[meeting] = nil
        #expect(
            try await library.store.saveSummaryNotes(Self.notes(.codex, revision: 0), for: meeting))
        await coordinator.refreshNow(meeting)
        #expect(session.summaryStates[meeting] == .ready)

        session.summaryStates[meeting] = nil
        let version = try #require(try await library.store.summary(of: meeting)).version
        _ = try await library.store.replaceTurns([], in: meeting, expectedVersion: version)
        await coordinator.refreshNow(meeting)
        #expect(session.summaryStates[meeting] == .stale)
    }
}
