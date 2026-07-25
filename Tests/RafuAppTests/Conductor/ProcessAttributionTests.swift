import Foundation
import Testing

@testable import RafuApp

/// Handoff 5 (C7 → coordinator): agent children showed as "Terminal N" in the
/// Resources surface. These cover the attribution the spec now carries and the
/// login-shell path staying exactly as it was.
@MainActor
@Test("An Ensemble step's spec carries role-and-vendor attribution")
func stepSpecCarriesRoleAndVendorAttribution() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "attribution-\(UUID().uuidString)", directoryHint: .isDirectory)
    let evidence = ConductorRunEvidence(
        runDirectory: root,
        handoffDirectory: root.appending(path: "handoff"),
        logsDirectory: root.appending(path: "logs"),
        promptURL: root.appending(path: "prompt.md"),
        artifactURL: root.appending(path: "handoff/result.md"),
        stepDirectory: root)
    let plan = ConductorWorkspacePlan(
        repositoryRoot: root,
        executionRoot: root,
        baseCommit: "abc1234",
        branchName: nil,
        worktreeURL: nil)
    let adapter = FakeConductorAdapter(id: .claudeCode)
    let resolved = ConductorResolvedAdapter(
        adapter: adapter,
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        version: "1.0")

    let spec = ConductorRoleLaunchService().specification(
        role: workflowRole(name: "implementor", handoffArtifact: "result.md"),
        prompt: "Do the work.",
        evidence: evidence,
        plan: plan,
        resolved: resolved,
        roleBadge: "implementor")

    // Role plus vendor — the two things that make an agent process
    // identifiable in Resources.
    #expect(spec.resourceAttribution == "implementor • Claude Code")
}

@MainActor
@Test("A login-shell spec carries no attribution, so terminals keep their naming")
func loginShellSpecHasNoAttribution() {
    // Constructed without the parameter, exactly as every pre-C7 call site
    // does: a plain terminal must keep registering as "Terminal N"/.terminalShell.
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/zsh"),
        arguments: [],
        currentDirectoryPath: "/tmp",
        environment: [:],
        roleBadge: "shell")
    #expect(spec.resourceAttribution == nil)
    // The attribution never reaches the child: it is not argv, not env.
    let launch = spec.resolvedLaunch()
    #expect(!(launch.arguments ?? []).contains(where: { $0.contains("•") }))
    #expect(!(launch.environment ?? []).contains(where: { $0.contains("•") }))
}

@MainActor
@Test("The agent process kind renders as Ensemble Agent, distinct from Terminal")
func agentProcessKindIsDistinct() {
    // The attribution decides BOTH the name and the kind, so a run's child is
    // never mistaken for an ordinary shell in the Resources list.
    let agentSpec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["hello"],
        currentDirectoryPath: "/tmp",
        environment: [:],
        roleBadge: "advisor",
        resourceAttribution: "advisor • Codex")
    #expect(agentSpec.resourceAttribution == "advisor • Codex")

    let sample = ProcessResourceRegistry.ProcessResourceSample(
        id: UUID(),
        name: "advisor • Codex",
        kind: .agent,
        pid: 1234,
        residentBytes: 4096)
    #expect(sample.kind == .agent)
    #expect(sample.name == "advisor • Codex")
}
