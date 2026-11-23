import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: probe")
struct MeetingAgentProbeTests {
    typealias S = AgentStreamLines

    static let claudeVersion = "2.1.330 (Claude Code)"
    static let codexVersion = "codex-cli 0.171.0"

    private struct Setup {
        let base: URL
        let process: FakeAgentProcessRunner
        let cache: FakeProbeCache

        init(
            _ behaviours: [FakeAgentBehaviour], version: String, cache: FakeProbeCache = .init()
        ) {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("rafu-probe-test-\(UUID().uuidString)", isDirectory: true)
            process = FakeAgentProcessRunner(behaviours, versionOutput: version)
            self.cache = cache
        }

        func prober(
            locator: FakeAgentLocator = FakeAgentLocator(), runTimeLimit: Duration = .seconds(30)
        ) -> MeetingAgentProber {
            MeetingAgentProber(
                processRunner: process, locator: locator,
                environment: MeetingAgentEnvironment.make(
                    path: "/usr/bin:/bin", home: "/Users/test", user: "test"),
                runsRoot: base, runTimeLimit: runTimeLimit, cache: cache)
        }

        var leftovers: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private static func claudeReady() -> FakeAgentBehaviour {
        .lines([S.claudeUIEvent, S.claudeInit, S.claudeResult("The color is blue.")], exit: 0)
    }

    private static func codexReady() -> FakeAgentBehaviour {
        .lines(
            [S.codexThread, S.codexTurnStarted, S.codexMessage("Blue."), S.codexTurnCompleted],
            exit: 0)
    }

    // MARK: Results

    @Test("Claude Code: the probe reads a fixed meeting copy and is ready")
    func claudeReady() async throws {
        let setup = Setup([Self.claudeReady()], version: Self.claudeVersion)
        defer { setup.remove() }
        let prober = setup.prober()
        #expect(await prober.probe(.claudeCode, refresh: false) == .ready)
        let run = try #require(setup.process.runs.first)
        #expect(run.directoryEntries == ["meeting.md", "question.md", "transcript.md"])
        #expect(run.directoryMode == 0o700)
        #expect(
            run.spec.arguments
                == MeetingAgentArguments.claude(prompt: MeetingAgentPrompts.claudePromptArgument))
        #expect(Set(run.spec.environment.keys) == MeetingAgentEnvironment.keys)
        #expect(run.spec.standardInput == nil)
        #expect(await prober.readyVersion(of: .claudeCode) == "2.1.330")
        #expect(setup.cache.entry(for: .claudeCode)?.key.version == "2.1.330")
        #expect(setup.leftovers.isEmpty)
    }

    @Test("Codex: the probe sends the fixed packet in an empty folder and is ready")
    func codexReady() async throws {
        let setup = Setup([Self.codexReady()], version: Self.codexVersion)
        defer { setup.remove() }
        let prober = setup.prober()
        #expect(await prober.probe(.codex, refresh: false) == .ready)
        let run = try #require(setup.process.runs.first)
        #expect(run.directoryEntries.isEmpty)
        #expect(
            run.spec.arguments
                == MeetingAgentArguments.codex(emptyFolder: run.spec.currentDirectoryURL))
        #expect(run.spec.standardInput == Data(MeetingAgentProbeTexts.codexPacket.utf8))
        #expect(setup.leftovers.isEmpty)
    }

    @Test(
        "Claude Code: each failure gives its own result",
        arguments: [
            (
                [
                    S.claudeInit.replacingOccurrences(
                        of: #"["Glob","Grep","Read"]"#, with: #"["Bash","Glob","Grep","Read"]"#)
                ], MeetingAgentProbeResult.unsupportedVersion(found: "2.1.330")
            ),
            ([S.claudeInit, S.claudeNotLoggedIn], .notSignedIn),
            (
                [
                    S.claudeInit,
                    #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
                ], .failed(reason: .toolEvent)
            ),
            ([S.claudeInit, S.claudeResult("x", isError: true)], .failed(reason: .noAnswer)),
            (
                [
                    S.claudeInit.replacingOccurrences(of: "2.1.330", with: "2.1.329"),
                    S.claudeResult("Blue."),
                ], .unsupportedVersion(found: "2.1.330")
            ),
        ] as [([String], MeetingAgentProbeResult)])
    func claudeFailures(lines: [String], expected: MeetingAgentProbeResult) async {
        let setup = Setup([.lines(lines, exit: 0)], version: Self.claudeVersion)
        defer { setup.remove() }
        #expect(await setup.prober().probe(.claudeCode, refresh: false) == expected)
        #expect(setup.cache.entry(for: .claudeCode) == nil)
        #expect(setup.leftovers.isEmpty)
    }

    @Test(
        "Codex: each failure gives its own result",
        arguments: [
            (
                [S.codexThread, S.codexUnrecognized],
                MeetingAgentProbeResult.failed(reason: .settingNotKnown)
            ),
            ([S.codexThread, S.codexTurnStarted, S.codex401], .notSignedIn),
            (
                [
                    S.codexThread,
                    #"{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call"}}"#,
                ], .failed(reason: .toolEvent)
            ),
            (
                [
                    S.codexThread, S.codexTurnStarted,
                    #"{"type":"turn.failed","error":{"message":"high demand"}}"#,
                ], .failed(reason: .noAnswer)
            ),
        ] as [([String], MeetingAgentProbeResult)])
    func codexFailures(lines: [String], expected: MeetingAgentProbeResult) async {
        let setup = Setup([.lines(lines, exit: 0)], version: Self.codexVersion)
        defer { setup.remove() }
        #expect(await setup.prober().probe(.codex, refresh: false) == expected)
        #expect(setup.cache.entry(for: .codex) == nil)
    }

    @Test("A file written during the probe run fails it, for each CLI")
    func wroteFiles() async {
        let claude = Setup(
            [
                .writeFile(
                    "out.md", lines: [S.claudeInit, S.claudeResult("Blue.")], exit: 0)
            ], version: Self.claudeVersion)
        defer { claude.remove() }
        #expect(
            await claude.prober().probe(.claudeCode, refresh: false)
                == .failed(reason: .wroteFiles))
        let codex = Setup(
            [
                .writeFile(
                    "AGENTS.md",
                    lines: [
                        S.codexThread, S.codexTurnStarted, S.codexMessage("Blue."),
                        S.codexTurnCompleted,
                    ], exit: 0)
            ], version: Self.codexVersion)
        defer { codex.remove() }
        #expect(await codex.prober().probe(.codex, refresh: false) == .failed(reason: .wroteFiles))
    }

    @Test("No readable version, or no CLI, fails before any run")
    func versionAndInstall() async {
        let setup = Setup([Self.claudeReady()], version: "garbage")
        defer { setup.remove() }
        #expect(
            await setup.prober().probe(.claudeCode, refresh: false)
                == .failed(reason: .versionUnreadable))
        #expect(setup.process.runs.isEmpty)
        let none = setup.prober(locator: FakeAgentLocator(installed: []))
        #expect(await none.probe(.codex, refresh: false) == .notInstalled)
        #expect(await none.lastResult(of: .codex) == .notInstalled)
    }

    @Test("A probe run past its time limit is timed out")
    func timeLimit() async {
        let setup = Setup([.hang([S.claudeInit])], version: Self.claudeVersion)
        defer { setup.remove() }
        #expect(
            await setup.prober(runTimeLimit: .milliseconds(100)).probe(.claudeCode, refresh: false)
                == .failed(reason: .timedOut))
        #expect(setup.process.runHandles.first?.terminateCalls == 1)
    }

    // MARK: Cache

    @Test("A second call starts no process; refresh probes again")
    func memoryCache() async {
        let setup = Setup([Self.claudeReady(), Self.claudeReady()], version: Self.claudeVersion)
        defer { setup.remove() }
        let prober = setup.prober()
        #expect(await prober.probe(.claudeCode, refresh: false) == .ready)
        #expect(await prober.probe(.claudeCode, refresh: false) == .ready)
        #expect(setup.process.starts.count == 2)
        #expect(await prober.lastResult(of: .claudeCode) == .ready)
        #expect(setup.process.starts.count == 2)
        #expect(await prober.probe(.claudeCode, refresh: true) == .ready)
        #expect(setup.process.runs.count == 2)
    }

    @Test("A kept ready result skips the run for the same binary only")
    func keptResult() async {
        let cache = FakeProbeCache()
        let first = Setup([Self.codexReady()], version: Self.codexVersion, cache: cache)
        defer { first.remove() }
        #expect(await first.prober().probe(.codex, refresh: false) == .ready)
        let kept = try? #require(cache.entry(for: .codex))

        // A new launch (new prober), same binary: the version only.
        let again = Setup([], version: Self.codexVersion, cache: cache)
        defer { again.remove() }
        #expect(await again.prober().lastResult(of: .codex) == .ready)
        #expect(await again.prober().probe(.codex, refresh: false) == .ready)
        #expect(again.process.runs.isEmpty)
        #expect(again.process.starts.count == 1)

        // A new modification date, a new version or a new argument revision
        // probes again.
        let newDate = Setup([Self.codexReady()], version: Self.codexVersion, cache: cache)
        defer { newDate.remove() }
        let moved = FakeAgentLocator(modified: Date(timeIntervalSince1970: 2))
        #expect(await newDate.prober(locator: moved).lastResult(of: .codex) == nil)
        #expect(await newDate.prober(locator: moved).probe(.codex, refresh: false) == .ready)
        #expect(newDate.process.runs.count == 1)

        if var entry = kept {
            let newVersion = Setup([Self.codexReady()], version: Self.codexVersion, cache: cache)
            defer { newVersion.remove() }
            entry.key.version = "0.170.0"
            cache.setEntry(entry, for: .codex)
            #expect(await newVersion.prober().probe(.codex, refresh: false) == .ready)
            #expect(newVersion.process.runs.count == 1)

            let newRevision = Setup([Self.codexReady()], version: Self.codexVersion, cache: cache)
            defer { newRevision.remove() }
            entry.key.version = "0.171.0"
            entry.key.revision = MeetingAgentArguments.revision - 1
            cache.setEntry(entry, for: .codex)
            #expect(await newRevision.prober().lastResult(of: .codex) == nil)
            #expect(await newRevision.prober().probe(.codex, refresh: false) == .ready)
            #expect(newRevision.process.runs.count == 1)
        }
    }

    @Test("Not signed in is not kept across launches, and a sign-in is seen at refresh")
    func notSignedInNotPersisted() async {
        let setup = Setup(
            [.lines([S.claudeInit, S.claudeNotLoggedIn], exit: 0), Self.claudeReady()],
            version: Self.claudeVersion)
        defer { setup.remove() }
        let prober = setup.prober()
        #expect(await prober.probe(.claudeCode, refresh: false) == .notSignedIn)
        #expect(setup.cache.entry(for: .claudeCode) == nil)
        #expect(await prober.lastResult(of: .claudeCode) == .notSignedIn)
        #expect(await prober.probe(.claudeCode, refresh: true) == .ready)
        #expect(setup.cache.entry(for: .claudeCode) != nil)
    }

    @Test("Invalidate forgets the kept result in memory and across launches")
    func invalidate() async {
        let setup = Setup([Self.claudeReady(), Self.claudeReady()], version: Self.claudeVersion)
        defer { setup.remove() }
        let prober = setup.prober()
        #expect(await prober.probe(.claudeCode, refresh: false) == .ready)
        await prober.invalidate(.claudeCode)
        #expect(setup.cache.entry(for: .claudeCode) == nil)
        #expect(await prober.lastResult(of: .claudeCode) == nil)
        #expect(await prober.probe(.claudeCode, refresh: false) == .ready)
        #expect(setup.process.runs.count == 2)
    }

    @Test("Two calls at the same time share one probe")
    func concurrentCallsShareOneProbe() async {
        let setup = Setup([.hang([S.claudeInit])], version: Self.claudeVersion)
        defer { setup.remove() }
        let prober = setup.prober(runTimeLimit: .seconds(5))
        // Both calls reach the actor before the probe can end: the first sets
        // the probe in flight before its first suspension, the second joins.
        async let first = prober.probe(.claudeCode, refresh: false)
        async let second = prober.probe(.claudeCode, refresh: true)
        var starts = setup.process.started.makeAsyncIterator()
        _ = await starts.next()
        setup.process.runHandles.first?.terminate()
        #expect(await first == .failed(reason: .noAnswer))
        #expect(await second == .failed(reason: .noAnswer))
        #expect(setup.process.runs.count == 1)
    }
}
