import Foundation
import Testing

@testable import RafuApp

private func kimiFixture(_ name: String) throws -> String {
    guard let fixture = KimiAdapterFixtures.named(name) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return fixture
}

private func kimiResult(
    stdout: String = "",
    completion: C3AdapterCommandResult.Completion = .exited(0)
) -> C3AdapterCommandResult {
    C3AdapterCommandResult(
        completion: completion,
        standardOutput: Data(stdout.utf8),
        standardError: Data())
}

private func unavailableKimiRuntime() -> C3AdapterRuntime {
    C3AdapterRuntime(
        resolveExecutable: { _, _ in nil },
        run: { _, _, _, _, _ in kimiResult(completion: .launchFailed) })
}

private let kimiExecutable = URL(fileURLWithPath: "/Users/fixture/.local/bin/kimi")
private let kimiWorkingDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-worktree")
private let kimiRunDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-run")
private let kimiHandoffDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-run/step-1")

@Test("Kimi is registered and an absent executable degrades honestly")
func kimiAbsentProbeAndMetadata() async {
    let adapter = KimiAdapter(runtime: unavailableKimiRuntime())
    #expect(adapter.id == .kimi)
    #expect(adapter.defaultEnabled)
    #expect(ConductorAdapterRegistry.adapter(for: .kimi) is KimiAdapter)
    #expect(await adapter.probe() == .notInstalled)
    #expect(await adapter.authStatus() == .unknown())
    #expect(!adapter.supportsModelDiscovery)
    #expect(await adapter.discoverModels() == nil)
    #expect(adapter.supportsModelDiscovery == ((await adapter.discoverModels()) != nil))
    #expect(
        adapter.curatedModels().map(\.id) == [
            "kimi-for-coding", "kimi-k2.6", "kimi-k2-thinking",
        ])
}

@Test("Kimi upstream-documented fixture is explicitly not a local verification")
func kimiDocumentedFixtureClassification() async throws {
    let version = try kimiFixture("documented-version-1.49.0.txt")
    let help = try kimiFixture("documented-help-1.49.0.txt")
    #expect(help.contains("DOCUMENTED-UPSTREAM-NOT-RECORDED-LOCALLY"))

    let classification = KimiAdapter.classifyProbe(
        executableURL: kimiExecutable,
        versionResult: kimiResult(stdout: version),
        helpResult: kimiResult(stdout: help))
    #expect(classification.probe.installed)
    #expect(classification.probe.version == "1.49.0")
    #expect(classification.supportedAutonomies == [.worktreeWrite])
}

@Test("Kimi installed without prompt flags is marked no-headless and supports nothing")
func kimiNoHeadlessModeClassification() {
    let classification = KimiAdapter.classifyProbe(
        executableURL: kimiExecutable,
        versionResult: kimiResult(stdout: "2.0.0\n"),
        helpResult: kimiResult(stdout: "Usage: kimi\ninteractive terminal\n"))
    #expect(classification.probe.installed)
    #expect(
        classification.probe.version?.contains("installed, but no supported headless mode") == true)
    #expect(classification.supportedAutonomies.isEmpty)
}

@Test("Kimi read-only always fails closed with no prompt argv")
func kimiReadOnlyUnsupported() {
    let hostile = "inspect; rm -rf / and $(whoami) and `id`"
    let adapter = KimiAdapter(executableURL: kimiExecutable)
    let invocation = adapter.invocation(
        prompt: hostile,
        model: "kimi-k2.6",
        autonomy: .readOnly,
        workingDirectory: kimiWorkingDirectory,
        runDirectory: kimiRunDirectory,
        handoffDirectory: kimiHandoffDirectory)
    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(invocation.arguments.isEmpty)
    #expect(!invocation.arguments.contains(hostile))
}

@Test(
    "Kimi documented print-mode argv never automates the TUI or adds conflicting permission flags",
    arguments: [
        ("", ["--print", "-p", "HOSTILE", "--output-format=stream-json"]),
        (
            "kimi-k2-thinking",
            [
                "--print", "-p", "HOSTILE", "--output-format=stream-json", "--model",
                "kimi-k2-thinking",
            ]
        ),
    ])
func kimiWorktreeInvocation(model: String, expectedArguments: [String]) {
    let hostile = "implement; rm -rf / and $(whoami) and `id`"
    let adapter = KimiAdapter(executableURL: kimiExecutable)
    let invocation = adapter.invocation(
        prompt: hostile,
        model: model,
        autonomy: .worktreeWrite,
        workingDirectory: kimiWorkingDirectory,
        runDirectory: kimiRunDirectory,
        handoffDirectory: kimiHandoffDirectory)
    let expected = expectedArguments.map { $0 == "HOSTILE" ? hostile : $0 }

    #expect(invocation.executableURL == kimiExecutable)
    #expect(invocation.arguments == expected)
    #expect(invocation.arguments.filter { $0 == hostile }.count == 1)
    #expect(!invocation.arguments.contains("--plan"))
    #expect(!invocation.arguments.contains("--auto"))
    #expect(!invocation.arguments.contains("--yolo"))
    #expect(!invocation.arguments.contains("--tui"))
}

@Test("Kimi path correction and run-directory environment stay exact")
func kimiPathCorrection() {
    let adapter = KimiAdapter(executableURL: kimiExecutable)
    let invocation = adapter.invocation(
        prompt: "implement",
        model: "",
        autonomy: .worktreeWrite,
        workingDirectory: kimiWorkingDirectory,
        runDirectory: kimiRunDirectory,
        handoffDirectory: kimiHandoffDirectory)
    let path = invocation.environment[RafuConductorEnvironment.path] ?? ""
    let components = path.split(separator: ":").map(String.init)

    #expect(components.first == "/Users/fixture/.local/bin")
    #expect(components.filter { $0 == "/Users/fixture/.local/bin" }.count == 1)
    #expect(path.hasSuffix(RafuConductorEnvironment.curatedPath))
    #expect(invocation.environment[RafuConductorEnvironment.runDirectory] == kimiRunDirectory.path)
    #expect(
        invocation.environment[RafuConductorEnvironment.handoff]
            == kimiHandoffDirectory.path)
}
