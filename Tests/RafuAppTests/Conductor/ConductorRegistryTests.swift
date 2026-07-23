import Foundation
import Testing

@testable import RafuApp

/// conductor/C0-shim.md increment 2: the registry's completeness contract,
/// the child-environment convention, and the fake adapter's argv-only
/// invocation.
///
/// This file holds ONLY assertions that stay true for the life of the
/// Conductor. Per-adapter behavior lives in `<Adapter>Tests.swift`, one file
/// per adapter, because C2/C3/C4 implement their adapters in PARALLEL
/// worktrees: a single shared "every adapter is still a stub" test would
/// force all three branches to edit the same line, which is precisely the
/// conflict C0 exists to prevent.

// MARK: - Registry completeness

@Test("The registry lists exactly the ConductorCLIID roster, in case order")
func registryMatchesTheRoster() {
    #expect(ConductorAdapterRegistry.all.map(\.id) == ConductorCLIID.allCases)
    #expect(ConductorAdapterRegistry.all.count == 7)
    for id in ConductorCLIID.allCases {
        #expect(ConductorAdapterRegistry.adapter(for: id)?.id == id)
    }
}

@Test("FakeConductorAdapter is absent from the shipping registry")
func fakeAdapterIsNotShipped() {
    // It is a real, working adapter for tests and C1 — never something a
    // user can pick.
    let fake = FakeConductorAdapter()
    #expect(!ConductorAdapterRegistry.all.contains { type(of: $0) == type(of: fake) })
    #expect(ConductorAdapterRegistry.all.allSatisfy { !($0 is FakeConductorAdapter) })
}

@Test("Every ConductorCLIID has a distinct, non-empty display name")
func everyRosterEntryHasADisplayName() {
    let names = ConductorCLIID.allCases.map(\.displayName)
    #expect(names.allSatisfy { !$0.isEmpty })
    #expect(Set(names).count == names.count)
}

// MARK: - Child environment

@Test("childEnvironment takes the run root EXPLICITLY and never derives it")
func childEnvironmentNeverDerivesTheRunRoot() {
    let runDirectory = URL(fileURLWithPath: "/tmp/rafu-c0/.rafu/runs/20260724-1")
    let handoffDirectory = runDirectory.appending(path: "step-1", directoryHint: .isDirectory)
    let environment = RafuConductorEnvironment.childEnvironment(
        runDirectory: runDirectory, handoffDirectory: handoffDirectory)

    #expect(environment[RafuConductorEnvironment.handoff] == handoffDirectory.path)
    #expect(environment[RafuConductorEnvironment.runDirectory] == runDirectory.path)
    // Nothing walks parent directories: a run root derived from a handoff
    // directory that happens to BE the run root would land on the shared
    // `.rafu/runs/` tree, where a worktreeWrite role could reach other runs'
    // evidence with nothing to fail on.
    let flat = RafuConductorEnvironment.childEnvironment(
        runDirectory: runDirectory, handoffDirectory: runDirectory)
    #expect(flat[RafuConductorEnvironment.runDirectory] == runDirectory.path)
    #expect(flat[RafuConductorEnvironment.handoff] == runDirectory.path)
    #expect(!(flat[RafuConductorEnvironment.runDirectory] ?? "").hasSuffix("/runs"))
}

@Test("The child PATH is curated, non-empty, and NOT the user's inherited PATH")
func childEnvironmentSuppliesACuratedPath() {
    let environment = RafuConductorEnvironment.childEnvironment(
        runDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run/step-1"))
    let path = environment[RafuConductorEnvironment.path]

    // A PTY child inherits no PATH at all, so an agent CLI would fail at its
    // shebang or its first `git` call without one.
    #expect(path == RafuConductorEnvironment.curatedPath)
    #expect(!(path ?? "").isEmpty)
    #expect(path?.contains("/opt/homebrew/bin") == true)
    // Curated, never inherited: forwarding the developer's real PATH would
    // hand an agent process unbounded, user-mutable trust (ADR 0018).
    #expect(path != ProcessInfo.processInfo.environment["PATH"])
    #expect(environment.count == 3)
}

// MARK: - Fake adapter

@Test("The fake adapter builds an absolute /bin/echo invocation with exact argv")
func fakeAdapterBuildsArgv() {
    let fake = FakeConductorAdapter(id: .codex)
    let invocation = fake.invocation(
        prompt: "write the brief",
        model: "fake-deep",
        autonomy: .worktreeWrite,
        workingDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-workdir"),
        runDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run/step-1"))

    #expect(fake.id == .codex)
    #expect(invocation.executableURL.path == "/bin/echo")
    #expect(
        invocation.arguments == [
            "--model", "fake-deep", "--autonomy", "worktreeWrite", "write the brief",
        ])
    #expect(
        invocation.environment == [
            "RAFU_HANDOFF": "/tmp/rafu-c0-run/step-1",
            "RAFU_RUN_DIR": "/tmp/rafu-c0-run",
            "PATH": RafuConductorEnvironment.curatedPath,
        ])
}

@Test("A shell-metacharacter prompt survives as ONE unexpanded argv element")
func fakeAdapterNeverBuildsAShellString() {
    // argv arrays only, never shell strings (ADR 0018, standing invariant):
    // repo text reaches the child verbatim, so nothing here can be executed
    // by a shell that is never involved.
    let hostile = "summarize this; rm -rf / and $(whoami) and `id`"
    let invocation = FakeConductorAdapter().invocation(
        prompt: hostile,
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-workdir"),
        runDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/rafu-c0-run/step-1"))

    #expect(invocation.arguments.last == hostile)
    #expect(invocation.arguments.filter { $0.contains("rm -rf") }.count == 1)
    #expect(invocation.arguments.contains("$(whoami)") == false)
    #expect(invocation.arguments.last?.contains("$(whoami)") == true)
    // No element is a shell, and no element concatenates the prompt with
    // anything else.
    #expect(!invocation.executableURL.path.hasSuffix("sh"))
    #expect(invocation.arguments.allSatisfy { $0 == hostile || !$0.contains(hostile) })
    // Default model resolution still applies when the role names none.
    #expect(invocation.arguments[1] == FakeConductorAdapter.curatedModelChoices[0].id)
}

@Test("The fake adapter probes as installed and offers curated plus discovered models")
func fakeAdapterProbesAndLists() async {
    let fake = FakeConductorAdapter()
    let probe = await fake.probe()
    #expect(probe.installed)
    #expect(probe.executableURL?.path == "/bin/echo")
    #expect(probe.version == "fake-1.0")
    #expect(fake.curatedModels().map(\.source).allSatisfy { $0 == .curated })
    #expect(await fake.discoverModels()?.map(\.source) == [.discovered])
    #expect(await FakeConductorAdapter(supportsModelDiscovery: false).discoverModels() == nil)
    #expect(await fake.authStatus() == .notAuthenticated(hint: "run `fake login` in a terminal"))
}
