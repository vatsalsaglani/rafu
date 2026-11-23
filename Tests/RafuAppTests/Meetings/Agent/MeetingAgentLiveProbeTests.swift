import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A manual check with the real CLIs on this Mac. Off by default: each run
/// makes one small model call for each CLI. Run it with
/// `RAFU_LIVE_AGENT_PROBE=1 swift test --filter MeetingAgentLiveProbeTests`.
@Suite(
    "Hidden meeting agent: live probe (manual)",
    .enabled(if: ProcessInfo.processInfo.environment["RAFU_LIVE_AGENT_PROBE"] == "1"))
struct MeetingAgentLiveProbeTests {
    @Test("Each installed CLI passes the probe", arguments: MeetingAgentCLI.allCases)
    func liveProbe(cli: MeetingAgentCLI) async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-live-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let prober = MeetingAgentProber(
            processRunner: MeetingAgentSystemProcessRunner(registry: MeetingAgentProcessRegistry()),
            locator: MeetingAgentExecutableLocator(), environment: MeetingAgentEnvironment.make(),
            runsRoot: base, cache: FakeProbeCache(),
            toolListCapture: MeetingAgentCodexToolListCapture())
        let result = await prober.probe(cli, refresh: true)
        #expect(result == .ready, "\(cli.displayName): \(result)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).isEmpty)
    }

    /// The summary reply of each real CLI parses into notes.
    @Test("A real summary run gives notes", arguments: MeetingAgentCLI.allCases)
    func liveSummary(cli: MeetingAgentCLI) async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let store = library.store
        let runner = MeetingAgentRunner(
            store: { store }, diagnostics: AgentTestDiagnostics(),
            processRunner: MeetingAgentSystemProcessRunner(registry: MeetingAgentProcessRegistry()),
            runsRoot: library.runsRoot,
            prober: MeetingAgentProber(
                processRunner: MeetingAgentSystemProcessRunner(
                    registry: MeetingAgentProcessRegistry()),
                locator: MeetingAgentExecutableLocator(),
                environment: MeetingAgentEnvironment.make(), runsRoot: library.runsRoot,
                cache: FakeProbeCache(), toolListCapture: MeetingAgentCodexToolListCapture()))
        let notes = try await runner.summarize(meeting, using: cli)
        #expect(!notes.title.isEmpty)
        #expect(!notes.summaryMarkdown.isEmpty)
        #expect(notes.cli == cli)
        #expect(library.leftovers().isEmpty)
    }

    /// Claude Code streams more than one piece; Codex gives one piece at
    /// the end. The final answer cites the synthetic meeting.
    @Test("A real question streams its answer", arguments: MeetingAgentCLI.allCases)
    func liveStream(cli: MeetingAgentCLI) async throws {
        let library = AgentTestLibrary()
        defer { library.remove() }
        let meeting = try await library.makeMeeting()
        let store = library.store
        let runner = MeetingAgentRunner(
            store: { store }, diagnostics: AgentTestDiagnostics(),
            processRunner: MeetingAgentSystemProcessRunner(registry: MeetingAgentProcessRegistry()),
            runsRoot: library.runsRoot,
            prober: MeetingAgentProber(
                processRunner: MeetingAgentSystemProcessRunner(
                    registry: MeetingAgentProcessRegistry()),
                locator: MeetingAgentExecutableLocator(),
                environment: MeetingAgentEnvironment.make(), runsRoot: library.runsRoot,
                cache: FakeProbeCache(), toolListCapture: MeetingAgentCodexToolListCapture()))
        var deltas = 0
        var reply: MeetingAgentReply?
        for try await event in runner.askStream(
            "When does the team ship the build?", about: meeting, using: cli)
        {
            switch event {
            case .textDelta: deltas += 1
            case .finished(let final): reply = final
            case .started, .textReset: break
            }
        }
        #expect(reply?.text.isEmpty == false)
        #expect(reply?.citations.isEmpty == false)
        switch cli {
        case .claudeCode: #expect(deltas > 1)
        case .codex: #expect(deltas == 1)
        }
        #expect(library.leftovers().isEmpty)
    }
}
