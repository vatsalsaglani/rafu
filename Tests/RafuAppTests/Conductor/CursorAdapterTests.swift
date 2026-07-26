import Foundation
import Testing

@testable import RafuApp

@Suite("CursorAdapter")
struct CursorAdapterTests {
    @Test("Registry and curated model claims stay honest")
    func registryAndModels() async {
        let adapter = CursorAdapter(currentPath: "")

        #expect(adapter.id == .cursor)
        #expect(ConductorAdapterRegistry.adapter(for: .cursor) is CursorAdapter)
        #expect(adapter.defaultEnabled)
        // cursor-agent 2026.07.23 answers `models` headlessly.
        #expect(adapter.supportsModelDiscovery)
        // `auto` first: the probed catalog is not an entitlement list, and
        // `--model auto` was the only value verified end to end.
        #expect(adapter.curatedModels().first?.id == "auto")
        #expect(
            adapter.curatedModels().map(\.id) == [
                "auto",
                "composer-2.5",
                "cursor-grok-4.5-high",
                "claude-opus-5-thinking-high",
                "gpt-5.6-sol-high",
                "claude-4.5-sonnet-thinking",
            ])
        #expect(adapter.curatedModels().allSatisfy { $0.source == .curated })
        // The stale help-example ids that failed against a real account.
        #expect(!adapter.curatedModels().contains { $0.id == "gpt-5" })
    }

    @Test("Discovery runs the CLI's own listing, and degrades to curated when it cannot")
    func discoveryUsesTheListingCommandAndFallsBack() async throws {
        // Fixture executables throughout: a unit test must never run the
        // developer's real `cursor-agent`, which would make the result depend
        // on their account's entitlements.
        let listing = try makeExecutable(
            named: "cursor-agent",
            body: """
                echo 'Available models'
                echo ''
                echo 'auto - Auto (current, default)'
                echo 'composer-2.5 - Composer 2.5'
                """)
        defer { try? FileManager.default.removeItem(at: listing.directory) }
        let listingAdapter = CursorAdapter(
            currentPath: "", cachedExecutableURL: listing.executable)
        let discovered = try #require(await listingAdapter.discoverModels())
        #expect(discovered.map(\.id) == ["auto", "composer-2.5"])
        #expect(discovered.allSatisfy { $0.source == .discovered })

        // A CLI that fails the listing must yield the curated list, never an
        // empty catalog — an empty picker would read as "you have no models".
        let failing = try makeExecutable(named: "cursor-agent", body: "exit 3")
        defer { try? FileManager.default.removeItem(at: failing.directory) }
        let failingAdapter = CursorAdapter(
            currentPath: "", cachedExecutableURL: failing.executable)
        #expect(await failingAdapter.discoverModels() == failingAdapter.curatedModels())

        // So must one that hangs: the probe is time-bounded, and a model
        // listing must never hang a UI path.
        let hanging = try makeExecutable(named: "cursor-agent", body: "while :; do :; done")
        defer { try? FileManager.default.removeItem(at: hanging.directory) }
        let hangingAdapter = CursorAdapter(
            currentPath: "",
            modelTimeout: .milliseconds(25),
            cachedExecutableURL: hanging.executable)
        #expect(await hangingAdapter.discoverModels() == hangingAdapter.curatedModels())
    }

    @Test("Cursor's real `models` table parses to id + display name")
    func parsesModelsTable() throws {
        // Verbatim shape of `cursor-agent models </dev/null`, 2026-07-27:
        // header, blank line, `<id> - <display name>` rows, trailing tip.
        let output = """
            Available models

            auto - Auto (current, default)
            gpt-5.3-codex-low - Codex 5.3 Low
            composer-2.5 - Composer 2.5
            claude-opus-5-thinking-high - Opus 5 1M Thinking
            claude-fable-5-thinking-high - Fable 5 1M Thinking (NO ZDR)

            Tip: use --model <id> (or /model <id> in interactive mode) to switch. \
            Parameterized models also accept quoted overrides, e.g. \
            --model 'claude-opus-4-8[context=1m,effort=high,fast=false]'.
            """
        let parsed = try #require(CursorAdapter.parseDiscoveredModels(output))

        #expect(
            parsed.map(\.id) == [
                "auto",
                "gpt-5.3-codex-low",
                "composer-2.5",
                "claude-opus-5-thinking-high",
                "claude-fable-5-thinking-high",
            ])
        // The header and the tip are prose, not rows, and neither survives.
        #expect(!parsed.contains { $0.displayName.contains("Tip:") })
        #expect(parsed.first?.displayName == "Auto (current, default)")
        // A display name with parentheses stays verbatim.
        #expect(parsed.last?.displayName == "Fable 5 1M Thinking (NO ZDR)")
        #expect(parsed.allSatisfy { $0.source == .discovered })
    }

    @Test("Unparseable listing output yields nil, never an empty catalog")
    func rejectsUnparseableOutput() {
        #expect(CursorAdapter.parseDiscoveredModels("") == nil)
        #expect(CursorAdapter.parseDiscoveredModels("Available models\n\n") == nil)
        #expect(CursorAdapter.parseDiscoveredModels("error: not logged in") == nil)
        // A row whose id carries shell metacharacters is dropped, not
        // forwarded to `--model`.
        #expect(CursorAdapter.parseDiscoveredModels("$(whoami) - Sneaky") == nil)
    }

    @Test("Installed status transcript classifies exit-zero Not logged in correctly")
    func authFixtureClassification() {
        let notLoggedIn = CursorTranscriptFixtures.statusNotLoggedIn
        let loggedIn = CursorTranscriptFixtures.statusLoggedIn

        #expect(
            CursorAdapter.classifyAuthStatus(exitCode: 0, output: notLoggedIn)
                == .notAuthenticated(hint: CursorAdapter.notAuthenticatedHint))
        #expect(
            CursorAdapter.classifyAuthStatus(exitCode: 0, output: loggedIn)
                == .authenticated)
        #expect(
            CursorAdapter.classifyAuthStatus(exitCode: 1, output: "network error") == .unknown())
        #expect(
            CursorAdapter.classifyAuthStatus(
                exitCode: 0,
                output: loggedIn,
                timedOut: true) == .unknown())
    }

    @Test("Worktree write builds verified print/json/force/model argv")
    func worktreeWriteArgv() {
        let executable = URL(fileURLWithPath: "/private/var/tools/cursor-agent")
        let adapter = CursorAdapter(cachedExecutableURL: executable)
        let hostilePrompt = "implement this; $(whoami) and `id`"
        let invocation = adapter.invocation(
            prompt: hostilePrompt,
            model: "sonnet-custom",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))

        #expect(invocation.executableURL == executable)
        #expect(
            invocation.arguments == [
                "-p",
                "--output-format", "json",
                "--force",
                "--model", "sonnet-custom",
                hostilePrompt,
            ])
        #expect(invocation.arguments.last == hostilePrompt)
    }

    @Test("Read-only is explicitly unsupported and always fails closed")
    func readOnlyFailsClosed() {
        let adapter = CursorAdapter(
            cachedExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/cursor-agent"))
        #expect(CursorAdapter.supportedAutonomies == [.worktreeWrite])
        #expect(
            CursorAdapter.readOnlyUnsupportedReason
                == "Cursor CLI has no verified read-only or plan mode; read-only runs fail closed.")
        let invocation = adapter.invocation(
            prompt: "analyze only",
            model: "",
            autonomy: .readOnly,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))

        #expect(invocation.executableURL.path == "/usr/bin/false")
        #expect(invocation.arguments.isEmpty)
        #expect(invocation.environment["RAFU_RUN_DIR"] == "/tmp/run")
        #expect(invocation.environment["RAFU_HANDOFF"] == "/tmp/run/step")
    }

    @Test("Invocation environment is minimal, curated, and contains no credential key")
    func invocationPathAndCredentials() {
        let adapter = CursorAdapter(
            cachedExecutableURL: URL(fileURLWithPath: "/private/var/cursor/bin/cursor-agent"))
        let invocation = adapter.invocation(
            prompt: "x",
            model: "",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))

        #expect(
            invocation.environment["PATH"]
                == "/private/var/cursor/bin:\(RafuConductorEnvironment.curatedPath)")
        #expect(invocation.environment.count == 3)
        #expect(!CursorAdapter.containsCredentialEnvironmentKey(invocation.environment))
    }

    @Test("An empty model passes no --model flag and lets the CLI decide")
    func emptyModelDefersToTheCLI() {
        let executable = URL(fileURLWithPath: "/private/var/cursor/bin/cursor-agent")
        let adapter = CursorAdapter(cachedExecutableURL: executable)

        // Regression guard. This used to substitute `curatedModels()[0]`,
        // silently running a model the account may not be entitled to — and
        // the then-first choice, `gpt-5`, was verified on 2026-07-27 to fail
        // before the agent even started. `ConductorModelResolution` documents
        // that guess as forbidden; the argv must now match `.cliDecides`.
        for blank in ["", "   ", "\n\t "] {
            let invocation = adapter.invocation(
                prompt: "go",
                model: blank,
                autonomy: .worktreeWrite,
                workingDirectory: URL(fileURLWithPath: "/tmp/work"),
                runDirectory: URL(fileURLWithPath: "/tmp/run"),
                handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
            #expect(invocation.arguments == ["-p", "--output-format", "json", "--force", "go"])
            #expect(!invocation.arguments.contains("--model"))
            #expect(!invocation.arguments.contains("gpt-5"))
        }

        // A model that IS set still rides through verbatim, trimmed.
        let named = adapter.invocation(
            prompt: "go",
            model: "  auto  ",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(
            named.arguments == [
                "-p", "--output-format", "json", "--force", "--model", "auto", "go",
            ])
    }

    @Test("Recorded version/help fixtures classify the installed CLI surface")
    func probeFixtureClassification() {
        let version = CursorTranscriptFixtures.version
        let help = CursorTranscriptFixtures.help
        let executable = URL(
            fileURLWithPath: "/Users/tester/.local/bin/cursor-agent")
        let probe = CursorAdapter.classifyProbe(
            executableURL: executable,
            versionResult: CursorProbeProcessResult(
                exitCode: 0, output: version, timedOut: false),
            helpResult: CursorProbeProcessResult(
                exitCode: 0, output: help, timedOut: false))

        #expect(probe.installed)
        #expect(probe.executableURL == executable)
        #expect(probe.version == "2025.09.18-7ae6800")
        #expect(CursorAdapter.helpSupportsInvocation(help))
        #expect(!CursorAdapter.helpSupportsInvocation("--print --model"))
    }

    @Test("Bounded probe caches URL and auth probe honors exit-zero negative text")
    func probeAndAuthStatus() async throws {
        let fixtureDirectory = try makeExecutable(
            named: "cursor-agent",
            body: """
                case "$1" in
                  --version) printf '%s\n' '2025.09.18-7ae6800' ;;
                  --help) printf '%s\n' '--print --output-format --force --model status' ;;
                  status) printf '%s\n' 'Not logged in'; exit 0 ;;
                  *) exit 64 ;;
                esac
                """)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory.directory) }
        let adapter = CursorAdapter(currentPath: fixtureDirectory.directory.path)

        let probe = await adapter.probe()
        #expect(probe.installed)
        #expect(probe.executableURL == fixtureDirectory.executable)
        #expect(probe.version == "2025.09.18-7ae6800")
        #expect(
            await adapter.authStatus()
                == .notAuthenticated(hint: CursorAdapter.notAuthenticatedHint))

        let invocation = adapter.invocation(
            prompt: "after probe",
            model: "",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(invocation.executableURL == fixtureDirectory.executable)
        #expect(invocation.environment["PATH"]?.hasPrefix(fixtureDirectory.directory.path) == true)

        let timeoutFixture = try makeExecutable(
            named: "cursor-agent",
            body: """
                while :; do :; done
                """)
        defer { try? FileManager.default.removeItem(at: timeoutFixture.directory) }
        let timedOutAdapter = CursorAdapter(
            currentPath: "",
            timeout: .milliseconds(25),
            cachedExecutableURL: timeoutFixture.executable)
        #expect(await timedOutAdapter.authStatus() == .unknown())
    }

    @Test("Cancellation cannot populate the executable cache")
    func cancellationFailsClosed() async throws {
        let fixtureDirectory = try makeExecutable(
            named: "cursor-agent",
            body: """
                while :; do :; done
                """)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory.directory) }
        let adapter = CursorAdapter(
            currentPath: fixtureDirectory.directory.path,
            timeout: .seconds(30))

        let task = Task { await adapter.probe() }
        await Task.yield()
        task.cancel()
        let cancelled = await task.value
        #expect(!cancelled.installed)

        let invocation = adapter.invocation(
            prompt: "must not run",
            model: "",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(invocation.executableURL.path == "/usr/bin/false")
        #expect(invocation.arguments.isEmpty)
    }

    private func makeExecutable(
        named name: String,
        body: String
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-cursor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
