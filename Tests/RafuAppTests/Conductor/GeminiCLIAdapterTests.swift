import Foundation
import Testing

@testable import RafuApp

@Suite("GeminiCLIAdapter")
struct GeminiCLIAdapterTests {
    @Test("Registry, curated models, and model-discovery claims stay honest")
    func registryAndModels() async {
        let adapter = GeminiCLIAdapter(currentPath: "")

        #expect(adapter.id == .geminiCLI)
        #expect(ConductorAdapterRegistry.adapter(for: .geminiCLI) is GeminiCLIAdapter)
        #expect(adapter.defaultEnabled)
        #expect(!adapter.supportsModelDiscovery)
        // The user-facing set from Gemini CLI 0.52.0's own model registry.
        // Internal `*-base` and `-customtools` entries are excluded.
        #expect(
            adapter.curatedModels().map(\.id) == [
                "gemini-3.5-flash",
                "gemini-3.1-pro-preview",
                "gemini-3.1-flash-lite",
                "gemini-3-pro-preview",
                "gemini-3-flash-preview",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
            ])
        #expect(!adapter.curatedModels().contains { $0.id.hasSuffix("-base") })
        #expect(!adapter.curatedModels().contains { $0.id.hasSuffix("-customtools") })
        #expect(adapter.curatedModels().allSatisfy { $0.source == .curated })
        #expect(await adapter.discoverModels() == nil)
        // There is no verified status command and no credential-file read.
        #expect(await adapter.authStatus() == .unknown())
    }

    @Test("Documented autonomy modes build exact argv without a shell")
    func invocationArgv() {
        let executable = URL(fileURLWithPath: "/private/var/tools/gemini")
        let adapter = GeminiCLIAdapter(cachedExecutableURL: executable)
        let hostilePrompt = "review this; $(whoami) and `id`"

        let readOnly = adapter.invocation(
            prompt: hostilePrompt,
            model: "",
            autonomy: .readOnly,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(readOnly.executableURL == executable)
        // An empty model passes NO `-m` flag: the CLI applies its own
        // configured default, which is what `.cliDecides` means. This
        // previously substituted `curatedModels()[0]`, so reordering the
        // curated list would silently have changed which model ran.
        #expect(
            readOnly.arguments == [
                "-p", hostilePrompt,
                "--output-format", "json",
                "--approval-mode", "default",
            ])
        #expect(!readOnly.arguments.contains("-m"))
        #expect(readOnly.arguments[1] == hostilePrompt)

        let write = adapter.invocation(
            prompt: "implement it",
            model: "gemini-custom-preview",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(
            write.arguments == [
                "-p", "implement it",
                "-m", "gemini-custom-preview",
                "--output-format", "json",
                "--approval-mode", "auto_edit",
            ])
    }

    @Test("Invocation environment is minimal and prepends only a non-curated binary directory")
    func invocationPathAndCredentials() {
        let run = URL(fileURLWithPath: "/tmp/rafu-run")
        let handoff = URL(fileURLWithPath: "/tmp/rafu-run/step")

        let external = GeminiCLIAdapter(
            cachedExecutableURL: URL(fileURLWithPath: "/private/var/gvm/bin/gemini")
        )
        .invocation(
            prompt: "x",
            model: "",
            autonomy: .readOnly,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: run,
            handoffDirectory: handoff)
        #expect(
            external.environment["PATH"]
                == "/private/var/gvm/bin:\(RafuConductorEnvironment.curatedPath)")
        #expect(external.environment["RAFU_RUN_DIR"] == run.path)
        #expect(external.environment["RAFU_HANDOFF"] == handoff.path)
        #expect(
            external.environment[RafuConductorEnvironment.readOnlyHandoffUnsupportedReason]
                == "Gemini CLI does not have a verified read-only mode that permits the required Ensemble handoff write."
        )
        #expect(external.environment.count == 4)
        #expect(!GeminiCLIAdapter.containsCredentialEnvironmentKey(external.environment))

        let curated = GeminiCLIAdapter(
            cachedExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/gemini")
        )
        .invocation(
            prompt: "x",
            model: "",
            autonomy: .readOnly,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: run,
            handoffDirectory: handoff)
        #expect(curated.environment["PATH"] == RafuConductorEnvironment.curatedPath)
    }

    @Test("Synthetic documented transcripts classify the locally unverified headless surface")
    func fixtureClassification() {
        let version = GeminiCLITranscriptFixtures.version
        let help = GeminiCLITranscriptFixtures.help
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/gemini")
        let probe = GeminiCLIAdapter.classifyProbe(
            executableURL: executable,
            versionResult: GeminiProbeProcessResult(
                exitCode: 0, output: version, timedOut: false),
            helpResult: GeminiProbeProcessResult(
                exitCode: 0, output: help, timedOut: false))

        #expect(probe.installed)
        #expect(probe.executableURL == executable)
        #expect(probe.version == "0.20.0")
        #expect(GeminiCLIAdapter.helpSupportsInvocation(help))
        #expect(!GeminiCLIAdapter.helpSupportsInvocation("Usage: gemini [prompt]"))
    }

    @Test("A successful bounded probe caches its absolute URL for pure invocation")
    func probeCachesExecutable() async throws {
        let fixtureDirectory = try makeExecutable(
            named: "gemini",
            body: """
                case "$1" in
                  --version) printf '%s\n' '0.20.0' ;;
                  --help) printf '%s\n' '-p --model --output-format --approval-mode' ;;
                  *) exit 64 ;;
                esac
                """)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory.directory) }

        let adapter = GeminiCLIAdapter(currentPath: fixtureDirectory.directory.path)
        let probe = await adapter.probe()
        #expect(probe.installed)
        #expect(probe.executableURL == fixtureDirectory.executable)
        #expect(probe.version == "0.20.0")

        let invocation = adapter.invocation(
            prompt: "after probe",
            model: "",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(invocation.executableURL == fixtureDirectory.executable)
        #expect(invocation.environment["PATH"]?.hasPrefix(fixtureDirectory.directory.path) == true)
    }

    @Test("No successful probe and cancellation both fail closed")
    func failClosedAndCancellation() async throws {
        let unprobed = GeminiCLIAdapter(currentPath: "")
        let invocation = unprobed.invocation(
            prompt: "must not run",
            model: "",
            autonomy: .worktreeWrite,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(invocation.executableURL.path == "/usr/bin/false")
        #expect(invocation.arguments.isEmpty)

        let fixtureDirectory = try makeExecutable(
            named: "gemini",
            body: """
                while :; do :; done
                """)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory.directory) }
        let adapter = GeminiCLIAdapter(
            currentPath: fixtureDirectory.directory.path,
            timeout: .seconds(30))
        let task = Task { await adapter.probe() }
        await Task.yield()
        task.cancel()
        let cancelled = await task.value
        #expect(!cancelled.installed)

        let cancelledInvocation = adapter.invocation(
            prompt: "must still not run",
            model: "",
            autonomy: .readOnly,
            workingDirectory: URL(fileURLWithPath: "/tmp/work"),
            runDirectory: URL(fileURLWithPath: "/tmp/run"),
            handoffDirectory: URL(fileURLWithPath: "/tmp/run/step"))
        #expect(cancelledInvocation.executableURL.path == "/usr/bin/false")
    }

    private func makeExecutable(
        named name: String,
        body: String
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-gemini-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
