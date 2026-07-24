import Foundation
import Testing

@testable import RafuApp

@Suite("CursorAdapter")
struct CursorAdapterTests {
    @Test("Registry and no-listing model claims stay honest")
    func registryAndModels() async {
        let adapter = CursorAdapter(currentPath: "")

        #expect(adapter.id == .cursor)
        #expect(ConductorAdapterRegistry.adapter(for: .cursor) is CursorAdapter)
        #expect(adapter.defaultEnabled)
        #expect(!adapter.supportsModelDiscovery)
        #expect(
            adapter.curatedModels().map(\.id) == [
                "gpt-5",
                "sonnet-4",
                "sonnet-4-thinking",
            ])
        #expect(adapter.curatedModels().allSatisfy { $0.source == .curated })
        #expect(await adapter.discoverModels() == nil)
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
        #expect(CursorAdapter.classifyAuthStatus(exitCode: 1, output: "network error") == .unknown)
        #expect(
            CursorAdapter.classifyAuthStatus(
                exitCode: 0,
                output: loggedIn,
                timedOut: true) == .unknown)
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
        #expect(invocation.arguments.contains("gpt-5"))
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
        #expect(await timedOutAdapter.authStatus() == .unknown)
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
