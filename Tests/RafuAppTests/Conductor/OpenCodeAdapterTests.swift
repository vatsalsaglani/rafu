import Foundation
import Testing

@testable import RafuApp

private func openCodeFixture(_ name: String) throws -> String {
    guard let fixture = OpenCodeAdapterFixtures.named(name) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return fixture
}

private func openCodeResult(
    stdout: String = "",
    stderr: String = "",
    completion: C3AdapterCommandResult.Completion = .exited(0)
) -> C3AdapterCommandResult {
    C3AdapterCommandResult(
        completion: completion,
        standardOutput: Data(stdout.utf8),
        standardError: Data(stderr.utf8))
}

private func unavailableOpenCodeRuntime() -> C3AdapterRuntime {
    C3AdapterRuntime(
        resolveExecutable: { _, _ in nil },
        run: { _, _, _, _, _ in openCodeResult(completion: .launchFailed) })
}

private let openCodeExecutable = URL(
    fileURLWithPath: "/Users/fixture/.opencode/bin/opencode")
private let openCodeWorkingDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-worktree")
private let openCodeRunDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-run")
private let openCodeHandoffDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-run/step-1")

@Test("OpenCode is registered with curated fallback and reachable model discovery")
func openCodeRegistryAndModels() async {
    let adapter = OpenCodeAdapter(runtime: unavailableOpenCodeRuntime())
    #expect(adapter.id == .openCode)
    #expect(adapter.defaultEnabled)
    #expect(ConductorAdapterRegistry.adapter(for: .openCode) is OpenCodeAdapter)
    #expect(adapter.supportsModelDiscovery)
    #expect(adapter.curatedModels().count == 3)
    #expect(adapter.curatedModels().allSatisfy { $0.source == .curated })

    let discovered = await adapter.discoverModels()
    #expect(discovered == adapter.curatedModels())
    #expect(adapter.supportsModelDiscovery == (discovered != nil))
}

@Test("OpenCode 1.18.4 recorded fixtures classify only worktree-write as supported")
func openCodeProbeFixtureClassification() async throws {
    let version = try openCodeFixture("version-1.18.4.txt")
    let help = try openCodeFixture("run-help-1.18.4.txt")
    let classification = OpenCodeAdapter.classifyProbe(
        executableURL: openCodeExecutable,
        versionResult: openCodeResult(stdout: version),
        runHelpResult: openCodeResult(stdout: help))

    #expect(classification.probe.installed)
    #expect(classification.probe.executableURL == openCodeExecutable)
    #expect(classification.probe.version == "1.18.4")
    #expect(classification.supportedAutonomies == [.worktreeWrite])
    #expect(classification.hasHeadlessMode)
}

@Test("OpenCode probe method records fixture classification for the later pure invocation")
func openCodeProbeFeedsInvocationCache() async throws {
    let version = try openCodeFixture("version-1.18.4.txt")
    let help = try openCodeFixture("run-help-1.18.4.txt")
    let runtime = C3AdapterRuntime(
        resolveExecutable: { name, _ in name == "opencode" ? openCodeExecutable : nil },
        run: { _, arguments, _, _, _ in
            if arguments.contains("--version") {
                return openCodeResult(stdout: version)
            }
            return openCodeResult(stdout: help)
        })
    let adapter = OpenCodeAdapter(runtime: runtime)

    #expect(await adapter.probe().version == "1.18.4")
    let invocation = adapter.invocation(
        prompt: "implement",
        model: "opencode/big-pickle",
        autonomy: .worktreeWrite,
        workingDirectory: openCodeWorkingDirectory,
        runDirectory: openCodeRunDirectory,
        handoffDirectory: openCodeHandoffDirectory)
    #expect(invocation.executableURL == openCodeExecutable)
}

@Test("OpenCode missing headless flags is installed but fails closed")
func openCodeProbeRejectsChurnedHelp() {
    let classification = OpenCodeAdapter.classifyProbe(
        executableURL: openCodeExecutable,
        versionResult: openCodeResult(stdout: "9.9.9\n"),
        runHelpResult: openCodeResult(stdout: "opencode run [message]\n--model\n"))

    #expect(classification.probe.installed)
    #expect(classification.supportedAutonomies.isEmpty)
    #expect(classification.probe.version?.contains("adapter needs update") == true)
}

@Test("OpenCode read-only fails without putting the prompt in any argv")
func openCodeReadOnlyIsUnsupported() {
    let hostile = "inspect; rm -rf / and $(whoami) and `id`"
    let adapter = OpenCodeAdapter(executableURL: openCodeExecutable)
    let invocation = adapter.invocation(
        prompt: hostile,
        model: "opencode/big-pickle",
        autonomy: .readOnly,
        workingDirectory: openCodeWorkingDirectory,
        runDirectory: openCodeRunDirectory,
        handoffDirectory: openCodeHandoffDirectory)

    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(invocation.arguments.isEmpty)
    #expect(!invocation.arguments.contains(hostile))
    #expect(
        invocation.environment[RafuConductorEnvironment.runDirectory]
            == openCodeRunDirectory.path)
    #expect(
        invocation.environment[RafuConductorEnvironment.handoff]
            == openCodeHandoffDirectory.path)
}

@Test(
    "OpenCode worktree-write builds exact argv and preserves a hostile prompt as one element",
    arguments: [
        (
            "",
            [
                "run", "--format", "json", "--dir", "/tmp/rafu-c3-worktree", "--auto",
                "--", "HOSTILE",
            ]
        ),
        (
            "opencode-go/kimi-k2.7-code",
            [
                "run", "--format", "json", "--dir", "/tmp/rafu-c3-worktree",
                "--model", "opencode-go/kimi-k2.7-code", "--auto", "--", "HOSTILE",
            ]
        ),
    ])
func openCodeInvocation(model: String, expectedArguments: [String]) {
    let hostile = "--help; rm -rf / and $(whoami) and `id`"
    let adapter = OpenCodeAdapter(executableURL: openCodeExecutable)
    let invocation = adapter.invocation(
        prompt: hostile,
        model: model,
        autonomy: .worktreeWrite,
        workingDirectory: openCodeWorkingDirectory,
        runDirectory: openCodeRunDirectory,
        handoffDirectory: openCodeHandoffDirectory)
    let expected = expectedArguments.map { $0 == "HOSTILE" ? hostile : $0 }

    #expect(invocation.executableURL == openCodeExecutable)
    #expect(invocation.arguments == expected)
    #expect(invocation.arguments.filter { $0 == hostile }.count == 1)
    #expect(!invocation.arguments.contains("--interactive"))
    #expect(!invocation.arguments.contains("--agent"))
}

@Test("OpenCode prepends its non-curated install directory exactly once")
func openCodePathCorrectionAndMinimalEnvironment() {
    let adapter = OpenCodeAdapter(executableURL: openCodeExecutable)
    let invocation = adapter.invocation(
        prompt: "implement",
        model: "",
        autonomy: .worktreeWrite,
        workingDirectory: openCodeWorkingDirectory,
        runDirectory: openCodeRunDirectory,
        handoffDirectory: openCodeHandoffDirectory)
    let path = invocation.environment[RafuConductorEnvironment.path] ?? ""
    let components = path.split(separator: ":").map(String.init)

    #expect(components.first == "/Users/fixture/.opencode/bin")
    #expect(components.filter { $0 == "/Users/fixture/.opencode/bin" }.count == 1)
    #expect(path.hasSuffix(RafuConductorEnvironment.curatedPath))
    #expect(
        Set(invocation.environment.keys)
            == [
                RafuConductorEnvironment.handoff,
                RafuConductorEnvironment.runDirectory,
                RafuConductorEnvironment.path,
            ])
    let forbidden = ["TOKEN", "SECRET", "KEY", "PASSWORD", "COOKIE", "CREDENTIAL"]
    #expect(
        !invocation.environment.keys.contains { key in
            forbidden.contains { key.uppercased().contains($0) }
        })
}

@Test("C3 executable discovery falls back to audited candidates when which misses")
func c3ExecutableDiscoveryFallsBackToCandidates() async {
    let resolved = await C3AdapterProcess.resolveExecutable(
        name: "rafu-c3-missing-\(UUID().uuidString)",
        candidates: [URL(fileURLWithPath: "/usr/bin/true")])

    #expect(resolved?.path == "/usr/bin/true")
}

@Test("OpenCode recorded model transcript parses in order as discovered choices")
func openCodeModelTranscriptParses() throws {
    let fixture = try openCodeFixture("models-1.18.4.txt")
    let choices = try #require(OpenCodeAdapter.parseDiscoveredModels(Data(fixture.utf8)))

    #expect(choices.count == 66)
    #expect(choices.first?.id == "opencode/big-pickle")
    #expect(choices.last?.id == "google-vertex-anthropic/claude-sonnet-5@default")
    #expect(choices.allSatisfy { $0.source == .discovered })
    #expect(choices.map(\.id) == choices.map(\.displayName))
}

@Test("OpenCode model parser deduplicates while preserving first-seen order")
func openCodeModelParserDeduplicates() throws {
    let fixture = """
        opencode/big-pickle
        openai/gpt-5.3-codex
        opencode/big-pickle
        """
    let choices = try #require(OpenCodeAdapter.parseDiscoveredModels(Data(fixture.utf8)))
    #expect(choices.map(\.id) == ["opencode/big-pickle", "openai/gpt-5.3-codex"])
}

@Test("OpenCode malformed, empty, oversized, and over-row-cap model output is rejected")
func openCodeModelParserBounds() throws {
    let malformed = try openCodeFixture("models-malformed.txt")
    #expect(OpenCodeAdapter.parseDiscoveredModels(Data(malformed.utf8)) == nil)
    #expect(OpenCodeAdapter.parseDiscoveredModels(Data()) == nil)

    let oversized = Data(
        repeating: 0x61,
        count: OpenCodeAdapter.maximumModelOutputBytes + 1)
    #expect(OpenCodeAdapter.parseDiscoveredModels(oversized) == nil)

    let tooManyRows = (0...OpenCodeAdapter.maximumModelRows)
        .map { "provider/model-\($0)" }
        .joined(separator: "\n")
    #expect(OpenCodeAdapter.parseDiscoveredModels(Data(tooManyRows.utf8)) == nil)
}

@Test("OpenCode discovery falls back to curated on malformed or failed subprocess output")
func openCodeDiscoveryFallsBack() async throws {
    let malformed = try openCodeFixture("models-malformed.txt")
    let malformedRuntime = C3AdapterRuntime(
        resolveExecutable: { _, _ in openCodeExecutable },
        run: { _, _, _, _, _ in openCodeResult(stdout: malformed) })
    let failedRuntime = C3AdapterRuntime(
        resolveExecutable: { _, _ in openCodeExecutable },
        run: { _, _, _, _, _ in openCodeResult(completion: .timedOut) })

    let malformedAdapter = OpenCodeAdapter(
        runtime: malformedRuntime,
        executableURL: openCodeExecutable)
    let failedAdapter = OpenCodeAdapter(
        runtime: failedRuntime,
        executableURL: openCodeExecutable)
    #expect(await malformedAdapter.discoverModels() == malformedAdapter.curatedModels())
    #expect(await failedAdapter.discoverModels() == failedAdapter.curatedModels())
}

@Test("OpenCode discovery maps a successful recorded transcript")
func openCodeDiscoveryUsesRecordedTranscript() async throws {
    let transcript = try openCodeFixture("models-1.18.4.txt")
    let runtime = C3AdapterRuntime(
        resolveExecutable: { _, _ in openCodeExecutable },
        run: { _, _, _, _, _ in openCodeResult(stdout: transcript) })
    let adapter = OpenCodeAdapter(
        runtime: runtime,
        executableURL: openCodeExecutable)

    let discovered = await adapter.discoverModels()
    let choices = try #require(discovered)
    #expect(choices.count == 66)
    #expect(choices.first?.source == .discovered)
    #expect(choices.first?.id == "opencode/big-pickle")
}

@Test("OpenCode auth fixtures classify positive, zero, ANSI, and failed outputs honestly")
func openCodeAuthClassification() throws {
    let positive = try openCodeFixture("auth-one-credential-1.18.4.txt")
    let zero = try openCodeFixture("auth-zero-credentials-1.18.4.txt")

    #expect(
        OpenCodeAdapter.classifyAuthStatus(openCodeResult(stdout: positive))
            == .authenticated)
    #expect(
        OpenCodeAdapter.classifyAuthStatus(
            openCodeResult(stdout: "\u{001B}[32m\(positive)\u{001B}[0m"))
            == .authenticated)
    #expect(
        OpenCodeAdapter.classifyAuthStatus(openCodeResult(stdout: zero))
            == .notAuthenticated(
                hint: "No OpenCode credentials reported; run `opencode auth login` in a terminal."))
    #expect(
        OpenCodeAdapter.classifyAuthStatus(
            openCodeResult(stderr: "permission denied", completion: .exited(1)))
            == .unknown)
}
