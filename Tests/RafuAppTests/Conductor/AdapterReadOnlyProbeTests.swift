import Foundation
import Testing

@testable import RafuApp

@Test("Codex read-only moves its writable workspace to the handoff directory")
func codexReadOnlyInvocationUsesHandoffWorkspace() {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/codex")
    let workspace = URL(fileURLWithPath: "/fixture/workspace")
    let handoff = workspace.appending(path: ".rafu/runs/probe/handoff")
    let adapter = CodexAdapter(executableURL: executableURL)

    let invocation = adapter.invocation(
        prompt: "Review the repository.",
        model: "gpt-5.4-mini",
        autonomy: .readOnly,
        workingDirectory: workspace,
        runDirectory: workspace.appending(path: ".rafu/runs/probe"),
        handoffDirectory: handoff)

    #expect(adapter.readOnlyHandoffSupport == .supported)
    #expect(
        invocation.arguments
            == [
                "exec",
                "--model",
                "gpt-5.4-mini",
                "--sandbox",
                "workspace-write",
                "--cd",
                handoff.path,
                "--json",
                "--ephemeral",
                "Review the repository.",
            ])
    #expect(!invocation.arguments.contains("--ask-for-approval"))
    #expect(
        invocation.environment[RafuConductorEnvironment.readOnlyHandoffUnsupportedReason] == nil)
}

@Test("OpenCode read-only allows only the nested handoff edit")
func openCodeReadOnlyInvocationUsesInlineScopedPolicy() throws {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/opencode")
    let workspace = URL(fileURLWithPath: "/fixture/workspace")
    let handoff = workspace.appending(path: ".rafu/runs/probe/handoff")
    let adapter = OpenCodeAdapter(executableURL: executableURL)

    let invocation = adapter.invocation(
        prompt: "Review the repository.",
        model: "opencode/big-pickle",
        autonomy: .readOnly,
        workingDirectory: workspace,
        runDirectory: workspace.appending(path: ".rafu/runs/probe"),
        handoffDirectory: handoff)

    #expect(adapter.readOnlyHandoffSupport == .supported)
    #expect(invocation.arguments.contains("--pure"))
    #expect(invocation.arguments.contains("--agent"))
    #expect(invocation.arguments.contains("rafu-readonly-handoff"))
    #expect(!invocation.arguments.contains("--auto"))

    let content = try #require(invocation.environment["OPENCODE_CONFIG_CONTENT"])
    let data = try #require(content.data(using: .utf8))
    let configuration = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let agents = try #require(configuration["agent"] as? [String: Any])
    let agent = try #require(agents["rafu-readonly-handoff"] as? [String: Any])
    let permission = try #require(agent["permission"] as? [String: Any])
    let edits = try #require(permission["edit"] as? [String: String])

    #expect(agent["mode"] as? String == "primary")
    #expect(permission["*"] as? String == "deny")
    #expect(permission["bash"] as? String == "deny")
    #expect(edits["*"] == "deny")
    #expect(edits[".rafu/runs/probe/handoff/**"] == "allow")
}

@Test("OpenCode read-only fails closed when the handoff is outside its workspace")
func openCodeReadOnlyRejectsExternalHandoff() {
    let adapter = OpenCodeAdapter(executableURL: URL(fileURLWithPath: "/fixture/bin/opencode"))
    let workspace = URL(fileURLWithPath: "/fixture/workspace")
    let runDirectory = workspace.appending(path: ".rafu/runs/probe")
    let externalHandoff = URL(fileURLWithPath: "/fixture/handoff")

    let invocation = adapter.invocation(
        prompt: "Review the repository.",
        model: "opencode/big-pickle",
        autonomy: .readOnly,
        workingDirectory: workspace,
        runDirectory: runDirectory,
        handoffDirectory: externalHandoff)

    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(invocation.arguments.isEmpty)
    #expect(
        invocation.environment[RafuConductorEnvironment.readOnlyHandoffUnsupportedReason]
            == "OpenCode requires the read-only handoff directory to be inside the workspace.")
}
