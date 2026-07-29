import Foundation
import Testing

@testable import RafuApp

@MainActor
private final class ThrowingRunTerminalRenderer: ConductorRunOutputRendering {
    private enum TestError: Error {
        case renderingFailed
    }

    func render(_: ArraySlice<UInt8>) throws -> Data {
        throw TestError.renderingFailed
    }

    func finish() throws -> Data {
        throw TestError.renderingFailed
    }
}

@MainActor
private final class RunTerminalRenderingLauncher: ConductorRunProcessLaunching {
    let sessionID = UUID()
    private var onExit: (@MainActor @Sendable (UUID, Int32?) -> Void)?

    func launch(
        specification _: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        self.onExit = onExit
        return sessionID
    }

    func terminate(sessionID _: UUID) {}

    func finish(exitCode: Int32?) {
        onExit?(sessionID, exitCode)
    }
}

private func makeRunTerminalRenderingRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-run-terminal-rendering-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for arguments in [
        ["init", "-b", "main"],
        ["config", "user.email", "tests@rafu.invalid"],
        ["config", "user.name", "Rafu Tests"],
    ] {
        try runTerminalRenderingGit(arguments, at: root)
    }
    try Data("fixture\n".utf8).write(to: root.appending(path: "fixture.txt"))
    try runTerminalRenderingGit(["add", "fixture.txt"], at: root)
    try runTerminalRenderingGit(["commit", "-m", "Fixture"], at: root)
    return root
}

private func runTerminalRenderingGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RunTerminalRenderingTestError.gitFailed
    }
}

private enum RunTerminalRenderingTestError: Error {
    case gitFailed
}

@MainActor
private func rendered(
    _ line: String,
    by renderer: ConductorRunTerminalOutputRenderer
) throws -> String {
    String(decoding: try renderer.render(ArraySlice(Data(line.utf8))), as: UTF8.self)
}

@MainActor
@Test(
    "Claude stream-json lines render as short terminal evidence and output.log records the same lines"
)
func claudeStreamJSONRendersForTerminalAndOutputLog() async throws {
    let renderer = ConductorRunTerminalOutputRenderer()
    let initLine =
        """
        {"type":"system","subtype":"init","session_id":"session-123","model":"claude-sonnet-4-20250514","permissionMode":"default"}

        """
    let firstHalf = String(initLine.prefix(initLine.count / 2))
    let secondHalf = String(initLine.dropFirst(initLine.count / 2))
    #expect(try rendered(firstHalf, by: renderer).isEmpty)
    #expect(
        try rendered(secondHalf, by: renderer)
            == "initialized: claude-sonnet-4-20250514 (permission: default)\n")

    // These shapes are from the F2 manual-run evidence: rate-limit update,
    // thinking-token accounting, assistant text, tool use, and final result.
    let fixtures: [(input: String, expected: String)] = [
        (
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\"}}\n",
            "rate limit: allowed\n"
        ),
        (
            "{\"type\":\"assistant\",\"message\":{\"content\":[],\"usage\":{\"thinking_tokens\":128}}}\n",
            "thinking…\n"
        ),
        (
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"I wrote the brief.\"}]}}\n",
            "I wrote the brief.\n"
        ),
        (
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Write\",\"input\":{\"file_path\":\"/tmp/handoff/brief.md\"}}]}}\n",
            "tool: Write brief.md\n"
        ),
        (
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"duration_ms\":2310,\"total_cost_usd\":0.74}\n",
            "result: completed in 2.3 s; cost $0.74\n"
        ),
    ]

    var expectedOutputLog = "initialized: claude-sonnet-4-20250514 (permission: default)\n"
    for fixture in fixtures {
        let renderedLine = try rendered(fixture.input, by: renderer)
        #expect(renderedLine == fixture.expected)
        expectedOutputLog += renderedLine
    }

    let malformed = "{\"type\":\"result\", this is not JSON}\n"
    #expect(try rendered(malformed, by: renderer) == malformed)
    expectedOutputLog += malformed

    let root = try makeRunTerminalRenderingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outputURL = root.appending(path: "output.log")
    let capture = ConductorRunOutputCapture(outputLogURL: outputURL)
    for fixture in [initLine] + fixtures.map(\.input) + [malformed] {
        let displayed = capture.render(ArraySlice(Data(fixture.utf8)))
        capture.record(ArraySlice(displayed))
    }
    capture.finish()
    await capture.waitUntilFinished()

    let loggedOutput = try Data(contentsOf: outputURL)
    #expect(String(decoding: loggedOutput, as: UTF8.self) == expectedOutputLog)
}

@MainActor
@Test("An oversized unterminated line passes through raw without retaining formatter memory")
func oversizedUnterminatedLinePassesThroughRaw() throws {
    let renderer = ConductorRunTerminalOutputRenderer()
    let oversized = Data(repeating: 0x41, count: 65 * 1_024)
    #expect(try renderer.render(ArraySlice(oversized)) == oversized)

    let lineEnding = Data("tail\n".utf8)
    #expect(try renderer.render(ArraySlice(lineEnding)) == lineEnding)
    #expect(
        try renderer.render(
            ArraySlice(
                Data(
                    "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\"}}\n"
                        .utf8)))
            == Data("rate limit: allowed\n".utf8))
}

@MainActor
@Test("A renderer error falls back to raw output and cannot alter artifact-plus-exit completion")
func rendererErrorCannotChangeRunState() async throws {
    let root = try makeRunTerminalRenderingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outputURL = root.appending(path: "output.log")
    let capture = ConductorRunOutputCapture(
        outputLogURL: outputURL,
        renderer: ThrowingRunTerminalRenderer())
    let raw = Data("{\"type\":\"assistant\"}\n".utf8)
    let displayed = capture.render(ArraySlice(raw))
    capture.record(ArraySlice(displayed))
    capture.finish()
    await capture.waitUntilFinished()
    #expect(displayed == raw)
    let loggedOutput = try Data(contentsOf: outputURL)
    #expect(loggedOutput == raw)

    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)])
    controller.attach(workspaceRoot: root)
    let launcher = RunTerminalRenderingLauncher()
    let role = ConductorAgentDefinition(
        name: "advisor",
        provider: .claudeCode,
        model: "fake-fast",
        autonomy: .readOnly,
        handoffArtifact: "brief.md",
        promptBody: "Review the request.")

    await controller.start(
        ConductorRunRequest(role: role, taskPrompt: "Review.", runID: "renderer-error"),
        launcher: launcher)
    #expect(controller.state == .running)

    let handoff = root.appending(path: ".rafu/runs/renderer-error/handoff/brief.md")
    try Data("artifact".utf8).write(to: handoff)
    launcher.finish(exitCode: 0)
    await controller.waitForPendingOperation()

    #expect(controller.state == .awaitingMergeGate)
    #expect(controller.manifest?.steps[0].status == .awaitingGate)
}

@MainActor
@Test("Exited Ensemble step terminals suppress the restart overlay while shells keep it")
func exitedRunTerminalSuppressesRestartOverlay() {
    let runTerminal = WorkspaceTerminalController(
        index: 1,
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            currentDirectoryPath: "/tmp",
            environment: [:],
            roleBadge: "advisor",
            outputLogURL: URL(fileURLWithPath: "/tmp/output.log")))
    let shellTerminal = WorkspaceTerminalController(
        index: 2,
        startingDirectory: "/tmp",
        shell: TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true))

    runTerminal.processDidTerminate(exitCode: 0)
    shellTerminal.processDidTerminate(exitCode: 0)

    #expect(runTerminal.isEnsembleRunTerminal)
    #expect(!runTerminal.showsShellExitedOverlay)
    #expect(!shellTerminal.isEnsembleRunTerminal)
    #expect(shellTerminal.showsShellExitedOverlay)
}
