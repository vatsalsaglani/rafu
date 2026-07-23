import Foundation
import Synchronization
import Testing

@testable import RafuApp

private let recordedCodexWhichTranscript =
    "/Applications/ChatGPT.app/Contents/Resources/codex\n"
private let recordedCodexVersionTranscript = "codex-cli 0.146.0-alpha.3\n"
private let recordedCodexAuthenticatedTranscript = "Logged in using ChatGPT\n"
private let recordedCodexUnauthenticatedTranscript = "Not logged in\n"

struct CodexInvocationFixture: Sendable {
    let autonomy: ConductorAutonomy
    let model: String
    let workingDirectory: URL
    let runDirectory: URL
    let handoffDirectory: URL
}

private let codexInvocationFixtures: [CodexInvocationFixture] = {
    let models = [
        "",
        "gpt-5.6",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "provider/custom-model",
    ]
    let directories = [
        (
            URL(fileURLWithPath: "/tmp/rafu-c2/work"),
            URL(fileURLWithPath: "/tmp/rafu-c2/run"),
            URL(fileURLWithPath: "/tmp/rafu-c2/run/step")
        ),
        (
            URL(fileURLWithPath: "/tmp/rafu C2/$(work); literal"),
            URL(fileURLWithPath: "/tmp/rafu C2/run [one]"),
            URL(fileURLWithPath: "/tmp/rafu C2/run [one]/handoff & notes")
        ),
    ]
    return ConductorAutonomy.allCases.flatMap { autonomy in
        models.flatMap { model in
            directories.map { working, run, handoff in
                CodexInvocationFixture(
                    autonomy: autonomy,
                    model: model,
                    workingDirectory: working,
                    runDirectory: run,
                    handoffDirectory: handoff)
            }
        }
    }
}()

private final class CodexRecordingProbeRunner: ConductorProbeCommandRunning, Sendable {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
        let outputPolicy: ConductorProbeOutputPolicy
    }

    private let calls = Mutex<[Call]>([])
    private let response: @Sendable (Call) -> ConductorProbeCommandOutcome

    init(response: @escaping @Sendable (Call) -> ConductorProbeCommandOutcome) {
        self.response = response
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputPolicy: ConductorProbeOutputPolicy
    ) async -> ConductorProbeCommandOutcome {
        let call = Call(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            outputPolicy: outputPolicy)
        calls.withLock { $0.append(call) }
        return response(call)
    }

    func recordedCalls() -> [Call] {
        calls.withLock { $0 }
    }
}

private struct CodexFixtureExecutableChecker: ConductorExecutableChecking {
    let executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private func codexCompletion(
    status: Int32,
    stdout: String = "",
    stderr: String = ""
) -> ConductorProbeCommandOutcome {
    .completed(
        ConductorProbeCompletion(
            terminationStatus: status,
            standardOutput: Data(stdout.utf8),
            standardError: Data(stderr.utf8)))
}

@Test("CodexAdapter is the real registered adapter with verified curated models")
func codexAdapterContract() async {
    let adapter = CodexAdapter()

    #expect(adapter.id == .codex)
    #expect(adapter.defaultEnabled)
    #expect(ConductorAdapterRegistry.adapter(for: .codex) is CodexAdapter)
    #expect(
        adapter.curatedModels()
            == [
                ConductorModelChoice(id: "gpt-5.6", displayName: "GPT-5.6", source: .curated),
                ConductorModelChoice(
                    id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", source: .curated),
                ConductorModelChoice(
                    id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", source: .curated),
                ConductorModelChoice(
                    id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", source: .curated),
            ])
    #expect(!adapter.supportsModelDiscovery)
    #expect(await adapter.discoverModels() == nil)
}

@Test(
    "Codex argv is exact for every autonomy, curated/custom/default model, and directory",
    arguments: codexInvocationFixtures)
func codexInvocationIsExact(fixture: CodexInvocationFixture) {
    let executableURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    let adapter = CodexAdapter(executableURL: executableURL)
    let prompt = "-leading prompt; $(whoami) and `id`\nsecond line"

    let invocation = adapter.invocation(
        prompt: prompt,
        model: fixture.model,
        autonomy: fixture.autonomy,
        workingDirectory: fixture.workingDirectory,
        runDirectory: fixture.runDirectory,
        handoffDirectory: fixture.handoffDirectory)

    var expectedArguments = ["--ask-for-approval", "never", "exec"]
    if !fixture.model.isEmpty {
        expectedArguments.append(contentsOf: ["--model", fixture.model])
    }
    expectedArguments.append(contentsOf: [
        "--sandbox",
        fixture.autonomy == .readOnly ? "read-only" : "workspace-write",
        "--cd",
        fixture.workingDirectory.path,
        "--json",
        "--ephemeral",
        prompt,
    ])

    #expect(invocation.executableURL == executableURL)
    #expect(invocation.executableURL.path.hasPrefix("/"))
    #expect(invocation.arguments == expectedArguments)
    #expect(invocation.arguments.filter { $0 == prompt }.count == 1)
    #expect(invocation.arguments.firstIndex(of: "--ask-for-approval") == 0)
    #expect(invocation.arguments.firstIndex(of: "exec") == 2)
    #expect(!invocation.arguments.contains("danger-full-access"))
    #expect(!invocation.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    #expect(!invocation.arguments.contains("--dangerously-bypass-hook-trust"))
    #expect(
        invocation.environment
            == [
                RafuConductorEnvironment.handoff: fixture.handoffDirectory.path,
                RafuConductorEnvironment.runDirectory: fixture.runDirectory.path,
                RafuConductorEnvironment.path:
                    "/Applications/ChatGPT.app/Contents/Resources:"
                    + RafuConductorEnvironment.curatedPath,
            ])
}

@Test("Codex invocation fails closed until the same adapter instance probes successfully")
func codexInvocationFailsClosedBeforeProbe() {
    let adapter = CodexAdapter(
        executableChecker: CodexFixtureExecutableChecker(executablePaths: []),
        hostSearchPath: "")
    let invocation = adapter.invocation(
        prompt: "do nothing",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))

    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(invocation.arguments.isEmpty)
}

@Test("Codex probe uses argv-only which, preserves its app path, and caches the version")
func codexProbeUsesWhichAndCachesVersion() async {
    let executableURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    let runner = CodexRecordingProbeRunner { call in
        if call.executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            return codexCompletion(status: 0, stdout: recordedCodexWhichTranscript)
        }
        if call.arguments == ["--version"] {
            return codexCompletion(status: 0, stdout: recordedCodexVersionTranscript)
        }
        return .couldNotLaunch
    }
    let adapter = CodexAdapter(
        runner: runner,
        executableChecker: CodexFixtureExecutableChecker(
            executablePaths: [executableURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "/fixture/shims:relative:/usr/bin:/fixture/shims")

    let probe = await adapter.probe()

    #expect(probe.installed)
    #expect(probe.executableURL == executableURL)
    #expect(probe.version == "codex-cli 0.146.0-alpha.3")

    let calls = runner.recordedCalls()
    #expect(calls.count == 2)
    #expect(calls[0].executableURL.path == "/usr/bin/which")
    #expect(calls[0].arguments == ["codex"])
    #expect(calls[0].outputPolicy == .capture)
    let discoveryPath = calls[0].environment[RafuConductorEnvironment.path] ?? ""
    #expect(discoveryPath.hasPrefix("/fixture/shims:/usr/bin:"))
    #expect(!discoveryPath.contains("relative"))
    #expect(discoveryPath.split(separator: ":").filter { $0 == "/fixture/shims" }.count == 1)

    #expect(calls[1].executableURL == executableURL)
    #expect(calls[1].arguments == ["--version"])
    #expect(calls[1].outputPolicy == .capture)
    #expect(
        calls[1].environment
            == [
                "PATH":
                    "/Applications/ChatGPT.app/Contents/Resources:"
                    + RafuConductorEnvironment.curatedPath,
                "HOME": "/fixture/home",
                "USER": "fixture-user",
                "LOGNAME": "fixture-user",
            ])

    let invocation = adapter.invocation(
        prompt: "cached",
        model: "gpt-5.6",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))
    #expect(invocation.executableURL == executableURL)
    #expect(
        invocation.environment["PATH"]
            == "/Applications/ChatGPT.app/Contents/Resources:"
            + RafuConductorEnvironment.curatedPath)
}

@Test("Codex probe falls back to the ChatGPT app and keeps installed true without a version")
func codexProbeFallsBackWhenWhichFails() async {
    let fallbackURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    let runner = CodexRecordingProbeRunner { call in
        if call.executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            return codexCompletion(status: 1)
        }
        return .outputLimitExceeded
    }
    let adapter = CodexAdapter(
        runner: runner,
        executableChecker: CodexFixtureExecutableChecker(
            executablePaths: [fallbackURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    let probe = await adapter.probe()

    #expect(probe.installed)
    #expect(probe.executableURL == fallbackURL)
    #expect(probe.version == nil)
}

@Test("Codex auth uses login status exit metadata only and discards command output")
func codexAuthUsesExitMetadataOnly() async {
    let executableURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    let runner = CodexRecordingProbeRunner { _ in
        codexCompletion(status: 0, stdout: recordedCodexUnauthenticatedTranscript)
    }
    let adapter = CodexAdapter(
        executableURL: executableURL,
        runner: runner,
        executableChecker: CodexFixtureExecutableChecker(
            executablePaths: [executableURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    #expect(await adapter.authStatus() == .authenticated)
    let calls = runner.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls[0].arguments == ["login", "status"])
    #expect(calls[0].outputPolicy == .discard)
    #expect(
        calls[0].environment
            == [
                "PATH":
                    "/Applications/ChatGPT.app/Contents/Resources:"
                    + RafuConductorEnvironment.curatedPath,
                "HOME": "/fixture/home",
                "USER": "fixture-user",
                "LOGNAME": "fixture-user",
            ])
}

@Test("Codex auth exit 0, 1, unexpected, timeout, and cancellation classify honestly")
func codexAuthClassification() {
    #expect(
        CodexAdapter.authStatus(
            from: codexCompletion(status: 0, stdout: recordedCodexUnauthenticatedTranscript))
            == .authenticated)
    #expect(
        CodexAdapter.authStatus(
            from: codexCompletion(status: 1, stdout: recordedCodexAuthenticatedTranscript))
            == .notAuthenticated(hint: "run `codex login` in a terminal"))
    #expect(CodexAdapter.authStatus(from: codexCompletion(status: 2)) == .unknown)
    #expect(CodexAdapter.authStatus(from: .timedOut) == .unknown)
    #expect(CodexAdapter.authStatus(from: .cancelled) == .unknown)
}
