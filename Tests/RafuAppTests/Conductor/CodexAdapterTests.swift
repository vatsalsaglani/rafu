import Foundation
import Testing

@testable import RafuApp

/// `CodexAdapter` — OWNED BY PHASE C2
/// (`docs/plans/phases/conductor/C2-adapters-claude-codex.md`).
/// C2 REWRITES THIS FILE when it implements the adapter.
///
/// C0 keeps every per-adapter assertion in a per-adapter file on purpose:
/// C2, C3, and C4 run in PARALLEL worktrees, so a single shared "all seven
/// adapters are still stubs" test would force all three branches to edit the
/// same line to make their own gate pass — exactly the conflict C0 exists to
/// prevent.
///
/// The second test below is NOT a stub assertion and must survive C2's
/// rewrite.

@Test("CodexAdapter is registered and degrades honestly until C2 implements it")
func codexAdapterIsAnHonestStub() async {
    let adapter = CodexAdapter()
    #expect(adapter.id == .codex)
    #expect(ConductorAdapterRegistry.adapter(for: .codex) is CodexAdapter)

    // The truthful "we have not implemented this yet" answers — never an
    // optimistic guess about the user's machine.
    let probe = await adapter.probe()
    #expect(!probe.installed)
    #expect(probe.executableURL == nil)
    #expect(probe.version == nil)
    #expect(await adapter.authStatus() == .unknown)
    #expect(adapter.curatedModels().isEmpty)
    #expect(await adapter.discoverModels() == nil)
    #expect(!adapter.supportsModelDiscovery)

    let invocation = adapter.invocation(
        prompt: "anything",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-workdir"),
        runDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run/step-1"))
    // A stub that somehow reached a run must FAIL the step, never exit
    // cleanly and let the engine record work that did not happen.
    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(invocation.arguments.isEmpty)
    // A SUPERSET, not an exact key set: C2 may add whatever its own CLI
    // needs without touching a shared test.
    #expect(
        Set(invocation.environment.keys).isSuperset(of: [
            RafuConductorEnvironment.handoff,
            RafuConductorEnvironment.runDirectory,
            RafuConductorEnvironment.path,
        ]))
    // The run root is whatever the caller passed, never derived from the
    // handoff directory.
    #expect(invocation.environment[RafuConductorEnvironment.runDirectory] == "/tmp/rafu-c0-run")
    #expect(invocation.environment[RafuConductorEnvironment.handoff] == "/tmp/rafu-c0-run/step-1")
}

@Test("CodexAdapter agrees with itself about model discovery")
func codexAdapterDiscoveryFlagIsHonest() async {
    // Two sources of truth that must never disagree. `true` + nil degrades
    // visibly to "unsupported", but `false` + a non-nil list is SILENT:
    // Settings never renders Refresh models, so the discovered models are
    // unreachable and nothing reports an error.
    let adapter = CodexAdapter()
    let discovered = await adapter.discoverModels()
    #expect(adapter.supportsModelDiscovery == (discovered != nil))
}
