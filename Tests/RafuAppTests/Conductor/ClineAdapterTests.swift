import Foundation
import Testing

@testable import RafuApp

private func clineFixture(_ name: String) throws -> String {
    guard let fixture = ClineAdapterFixtures.named(name) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return fixture
}

private func clineResult(
    stdout: String = "",
    completion: C3AdapterCommandResult.Completion = .exited(0)
) -> C3AdapterCommandResult {
    C3AdapterCommandResult(
        completion: completion,
        standardOutput: Data(stdout.utf8),
        standardError: Data())
}

private func unavailableClineRuntime() -> C3AdapterRuntime {
    C3AdapterRuntime(
        resolveExecutable: { _, _ in nil },
        run: { _, _, _, _, _ in clineResult(completion: .launchFailed) })
}

private let clineExecutable = URL(
    fileURLWithPath: "/Users/fixture/.nvm/versions/node/v22.0.0/bin/cline")
private let clineWorkingDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-worktree")
private let clineRunDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-run")
private let clineHandoffDirectory = URL(fileURLWithPath: "/tmp/rafu-c3-run/step-1")

@Test("Cline is registered with curated routes and offline model discovery")
func clineRegistryAndMetadata() async {
    let adapter = ClineAdapter(runtime: unavailableClineRuntime())
    #expect(adapter.id == .cline)
    #expect(adapter.defaultEnabled)
    #expect(ConductorAdapterRegistry.adapter(for: .cline) is ClineAdapter)
    // Discovery now reads Cline's own bundled catalog. With no resolvable
    // executable it degrades to the curated list rather than returning nil.
    #expect(adapter.supportsModelDiscovery)
    #expect(await adapter.discoverModels() == adapter.curatedModels())
    // Unknown, but no longer a bare shrug: Cline 3.0.46 has no
    // non-interactive sign-in check (`config`/`mcp` demand a TTY, `auth`
    // MUTATES rather than reports, and reading its 0600 provider store is
    // forbidden), so the adapter says why and states that runs still work.
    let clineAuth = await adapter.authStatus()
    guard case .unknown(let reason) = clineAuth, let reason else {
        Issue.record("Expected Cline to report unknown WITH a reason")
        return
    }
    #expect(reason.contains("non-interactive"))
    #expect(reason.lowercased().contains("does not block runs"))
    // Never leaks where credentials live.
    #expect(!reason.contains("providers.json"))
    #expect(adapter.curatedModels().count == 6)
    #expect(adapter.curatedModels().allSatisfy { $0.source == .curated })
}

@Test("Cline 3.0.46 recorded fixtures classify both autonomy levels")
func clineProbeFixtureClassification() async throws {
    let version = try clineFixture("version-3.0.46.txt")
    let help = try clineFixture("help-3.0.46.txt")
    let classification = ClineAdapter.classifyProbe(
        executableURL: clineExecutable,
        versionResult: clineResult(stdout: version),
        helpResult: clineResult(stdout: help))

    #expect(classification.probe.installed)
    #expect(classification.probe.executableURL == clineExecutable)
    #expect(classification.probe.version == "3.0.46")
    #expect(classification.supportedAutonomies == [.readOnly, .worktreeWrite])
}

@Test("Cline missing plan mode retains write support but declines read-only")
func clineProbeClassifiesPerAutonomy() throws {
    let version = try clineFixture("version-3.0.46.txt")
    let help = try clineFixture("help-3.0.46.txt")
        .replacingOccurrences(of: "  -p, --plan                    Run in plan mode\n", with: "")
    let classification = ClineAdapter.classifyProbe(
        executableURL: clineExecutable,
        versionResult: clineResult(stdout: version),
        helpResult: clineResult(stdout: help))

    #expect(classification.supportedAutonomies == [.worktreeWrite])
    #expect(classification.probe.version == "3.0.46")
}

@Test("Cline probe method records fixture capabilities for invocation")
func clineProbeFeedsInvocationCache() async throws {
    let version = try clineFixture("version-3.0.46.txt")
    let help = try clineFixture("help-3.0.46.txt")
    let runtime = C3AdapterRuntime(
        resolveExecutable: { name, _ in name == "cline" ? clineExecutable : nil },
        run: { _, arguments, _, _, _ in
            arguments.contains("--version")
                ? clineResult(stdout: version)
                : clineResult(stdout: help)
        })
    let adapter = ClineAdapter(runtime: runtime)

    #expect(await adapter.probe().version == "3.0.46")
    let invocation = adapter.invocation(
        prompt: "plan",
        model: "",
        autonomy: .readOnly,
        workingDirectory: clineWorkingDirectory,
        runDirectory: clineRunDirectory,
        handoffDirectory: clineHandoffDirectory)
    #expect(invocation.executableURL == clineExecutable)
    #expect(invocation.arguments.contains("--plan"))
}

@Test(
    "Cline constructs exact argv for both autonomy levels and empty or selected models",
    arguments: [
        (
            ConductorAutonomy.readOnly,
            "",
            [
                "--json", "--cwd", "/tmp/rafu-c3-worktree", "--plan", "--auto-approve",
                "false", "--", "HOSTILE",
            ]
        ),
        (
            ConductorAutonomy.worktreeWrite,
            "anthropic/claude-sonnet-4-6",
            [
                "--json", "--cwd", "/tmp/rafu-c3-worktree", "--auto-approve", "true",
                "--model", "anthropic/claude-sonnet-4-6", "--", "HOSTILE",
            ]
        ),
    ])
func clineInvocation(
    autonomy: ConductorAutonomy,
    model: String,
    expectedArguments: [String]
) {
    let hostile = "--help; rm -rf / and $(whoami) and `id`"
    let adapter = ClineAdapter(executableURL: clineExecutable)
    let invocation = adapter.invocation(
        prompt: hostile,
        model: model,
        autonomy: autonomy,
        workingDirectory: clineWorkingDirectory,
        runDirectory: clineRunDirectory,
        handoffDirectory: clineHandoffDirectory)
    let expected = expectedArguments.map { $0 == "HOSTILE" ? hostile : $0 }

    #expect(invocation.arguments == expected)
    #expect(invocation.arguments.filter { $0 == hostile }.count == 1)
    #expect(!invocation.arguments.contains("--tui"))
    #expect(!invocation.arguments.contains("--worktree"))
    #expect(!invocation.arguments.contains("--key"))
}

@Test("Cline NVM directory is prepended once and no credential-shaped key is forwarded")
func clinePathCorrection() {
    let adapter = ClineAdapter(executableURL: clineExecutable)
    let invocation = adapter.invocation(
        prompt: "implement",
        model: "",
        autonomy: .worktreeWrite,
        workingDirectory: clineWorkingDirectory,
        runDirectory: clineRunDirectory,
        handoffDirectory: clineHandoffDirectory)
    let path = invocation.environment[RafuConductorEnvironment.path] ?? ""
    let components = path.split(separator: ":").map(String.init)

    #expect(components.first == "/Users/fixture/.nvm/versions/node/v22.0.0/bin")
    #expect(
        components.filter { $0 == "/Users/fixture/.nvm/versions/node/v22.0.0/bin" }.count
            == 1)
    #expect(path.hasSuffix(RafuConductorEnvironment.curatedPath))
    #expect(invocation.environment[RafuConductorEnvironment.runDirectory] == clineRunDirectory.path)
    #expect(
        invocation.environment[RafuConductorEnvironment.handoff]
            == clineHandoffDirectory.path)
    let forbidden = ["TOKEN", "SECRET", "KEY", "PASSWORD", "COOKIE", "CREDENTIAL"]
    #expect(
        !invocation.environment.keys.contains { key in
            forbidden.contains { key.uppercased().contains($0) }
        })
}

@Test("Cline unsupported capability fails closed rather than guessing flags")
func clineUnsupportedCapabilityFailsClosed() {
    let adapter = ClineAdapter(
        executableURL: clineExecutable,
        supportedAutonomies: [.worktreeWrite])
    let invocation = adapter.invocation(
        prompt: "read",
        model: "",
        autonomy: .readOnly,
        workingDirectory: clineWorkingDirectory,
        runDirectory: clineRunDirectory,
        handoffDirectory: clineHandoffDirectory)
    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(invocation.arguments.isEmpty)
}

// MARK: - Bundled-catalog model discovery (2026-07-25)

/// Cline has no `models` subcommand — `cline config` accepts only
/// `workflows|rules|skills|agents|plugins|hooks|mcp|tools` — but it ships its
/// full catalog inside its own package, so discovery reads that.
@Test("Cline parses its bundled catalog into discovered model choices")
func clineParsesBundledCatalog() throws {
    let json = """
        [{"id":"anthropic/claude-sonnet-5","name":"Claude Sonnet 5"},
         {"id":"moonshotai/kimi-k3","name":"Kimi K3"}]
        """
    let parsed = try #require(ClineAdapter.parseCatalogModels(json))
    #expect(parsed.count == 2)
    #expect(parsed[0].id == "anthropic/claude-sonnet-5")
    #expect(parsed[0].displayName == "Claude Sonnet 5")
    // Marked discovered, not curated — the picker can tell the user these
    // came from their own installed CLI.
    #expect(parsed.allSatisfy { $0.source == .discovered })
}

@Test("Catalog parsing drops unusable entries and duplicates instead of rendering blanks")
func clineCatalogParsingIsDefensive() throws {
    let messy = """
        [{"id":"a/b","name":"A B"},
         {"id":"a/b","name":"duplicate"},
         {"id":"","name":"empty id"},
         {"name":"no id at all"},
         {"id":"c/d"}]
        """
    let parsed = try #require(ClineAdapter.parseCatalogModels(messy))
    #expect(parsed.map(\.id) == ["a/b", "c/d"])
    // A missing name falls back to the id rather than an empty row.
    #expect(parsed[1].displayName == "c/d")
}

@Test("Malformed catalog output parses to nil so discovery falls back to curated")
func clineCatalogParsingRejectsGarbage() {
    #expect(ClineAdapter.parseCatalogModels("") == nil)
    #expect(ClineAdapter.parseCatalogModels("not json") == nil)
    #expect(ClineAdapter.parseCatalogModels("{\"providers\":{}}") == nil)
}

@Test("The catalog script takes its path as an argument, never interpolated")
func clineCatalogScriptIsInjectionSafe() {
    // A path containing quotes must not be able to alter the script, so the
    // script reads argv rather than embedding the path.
    #expect(ClineAdapter.catalogScript.contains("process.argv"))
    #expect(!ClineAdapter.catalogScript.contains("\\("))
}

@Test("Curated Cline models are ids the installed catalog actually offers")
func clineCuratedModelsAreRealIDs() {
    let curated = ClineAdapter().curatedModels()
    // Regression: the list previously shipped `anthropic/claude-sonnet-4-6`,
    // which Cline does not offer — Rafu advertised a model that would fail.
    #expect(!curated.contains { $0.id == "anthropic/claude-sonnet-4-6" })
    #expect(curated.contains { $0.id == "anthropic/claude-sonnet-5" })
    #expect(curated.allSatisfy { $0.id.contains("/") })
    #expect(curated.allSatisfy { $0.source == .curated })
}
