import Darwin
import Foundation
import Synchronization
import Testing

@testable import RafuApp

private let recordedClaudeWhichTranscript = "/fixture/bin/claude\n"
private let recordedClaudeVersionTranscript = "2.1.218 (Claude Code)\n"
private let recordedClaudeAuthenticatedTranscript = """
    {"loggedIn":true,"authMethod":"claude.ai"}
    """
private let recordedClaudeUnauthenticatedTranscript = """
    {"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}
    """

struct ClaudeInvocationFixture: Sendable {
    let autonomy: ConductorAutonomy
    let model: String
    let workingDirectory: URL
    let runDirectory: URL
    let handoffDirectory: URL
}

private let claudeInvocationFixtures: [ClaudeInvocationFixture] = {
    let models = ["", "fable", "opus", "sonnet", "haiku", "vendor/custom-model"]
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
                ClaudeInvocationFixture(
                    autonomy: autonomy,
                    model: model,
                    workingDirectory: working,
                    runDirectory: run,
                    handoffDirectory: handoff)
            }
        }
    }
}()

private final class ClaudeRecordingProbeRunner: ConductorProbeCommandRunning, Sendable {
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

private struct ClaudeFixtureExecutableChecker: ConductorExecutableChecking {
    let executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private final class ClaudeThreadRecordingExecutableChecker:
    ConductorExecutableChecking,
    Sendable
{
    private let sawMainThread = Mutex(false)
    let executablePath: String

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func isExecutableFile(atPath path: String) -> Bool {
        if Thread.isMainThread {
            sawMainThread.withLock { $0 = true }
        }
        return path == executablePath
    }

    func wasCalledOnMainThread() -> Bool {
        sawMainThread.withLock { $0 }
    }
}

private actor ClaudeOverlappingProbeRunner: ConductorProbeCommandRunning {
    private let executableURL: URL
    private var whichCallCount = 0
    private var firstWhichStarted = false
    private var firstWhichStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirstWhich: CheckedContinuation<Void, Never>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputPolicy: ConductorProbeOutputPolicy
    ) async -> ConductorProbeCommandOutcome {
        if executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            whichCallCount += 1
            if whichCallCount == 1 {
                firstWhichStarted = true
                let waiters = firstWhichStartWaiters
                firstWhichStartWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { continuation in
                    releaseFirstWhich = continuation
                }
                return claudeCompletion(status: 1)
            }

            releaseFirstWhich?.resume()
            releaseFirstWhich = nil
            return claudeCompletion(status: 0, stdout: "\(self.executableURL.path)\n")
        }
        if arguments == ["--version"] {
            return claudeCompletion(status: 0, stdout: recordedClaudeVersionTranscript)
        }
        return .couldNotLaunch
    }

    func waitUntilFirstWhichStarts() async {
        if firstWhichStarted { return }
        await withCheckedContinuation { continuation in
            firstWhichStartWaiters.append(continuation)
        }
    }
}

private actor ClaudeProbeRegistrationLatch {
    private var processIdentifier: pid_t?
    private var waiters: [CheckedContinuation<pid_t, Never>] = []

    func signal(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: processIdentifier)
        }
    }

    func wait() async -> pid_t {
        if let processIdentifier { return processIdentifier }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ClaudeSuccessfulThenCancelledProbeRunner: ConductorProbeCommandRunning {
    private let executableURL: URL
    private var whichCallCount = 0
    private var firstWhichStarted = false
    private var firstWhichStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirstWhich: CheckedContinuation<Void, Never>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputPolicy: ConductorProbeOutputPolicy
    ) async -> ConductorProbeCommandOutcome {
        if executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            whichCallCount += 1
            if whichCallCount == 1 {
                firstWhichStarted = true
                let waiters = firstWhichStartWaiters
                firstWhichStartWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { continuation in
                    releaseFirstWhich = continuation
                }
                return claudeCompletion(status: 0, stdout: "\(self.executableURL.path)\n")
            }

            releaseFirstWhich?.resume()
            releaseFirstWhich = nil
            return .cancelled
        }
        if arguments == ["--version"] {
            return claudeCompletion(status: 0, stdout: recordedClaudeVersionTranscript)
        }
        return .couldNotLaunch
    }

    func waitUntilFirstWhichStarts() async {
        if firstWhichStarted { return }
        await withCheckedContinuation { continuation in
            firstWhichStartWaiters.append(continuation)
        }
    }
}

private func claudeCompletion(
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

@Test("ClaudeCodeAdapter is the real registered adapter with verified curated models")
func claudeCodeAdapterContract() async {
    let adapter = ClaudeCodeAdapter()

    #expect(adapter.id == .claudeCode)
    #expect(adapter.defaultEnabled)
    #expect(ConductorAdapterRegistry.adapter(for: .claudeCode) is ClaudeCodeAdapter)
    #expect(
        adapter.curatedModels()
            == [
                ConductorModelChoice(id: "fable", displayName: "Fable", source: .curated),
                ConductorModelChoice(id: "opus", displayName: "Opus", source: .curated),
                ConductorModelChoice(id: "sonnet", displayName: "Sonnet", source: .curated),
                ConductorModelChoice(id: "haiku", displayName: "Haiku", source: .curated),
            ])
    #expect(!adapter.supportsModelDiscovery)
    #expect(await adapter.discoverModels() == nil)
}

@Test(
    "Claude argv is exact for every autonomy, curated/custom/default model, and directory",
    arguments: claudeInvocationFixtures)
func claudeInvocationIsExact(fixture: ClaudeInvocationFixture) {
    let executableURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/bin/claude")
    let adapter = ClaudeCodeAdapter(executableURL: executableURL)
    let prompt = "-leading prompt; $(whoami) and `id`\nsecond line"

    let invocation = adapter.invocation(
        prompt: prompt,
        model: fixture.model,
        autonomy: fixture.autonomy,
        workingDirectory: fixture.workingDirectory,
        runDirectory: fixture.runDirectory,
        handoffDirectory: fixture.handoffDirectory)

    var expectedArguments = ["-p", prompt]
    if !fixture.model.isEmpty {
        expectedArguments.append(contentsOf: ["--model", fixture.model])
    }
    expectedArguments.append(contentsOf: [
        "--output-format",
        "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--permission-mode",
        fixture.autonomy == .readOnly ? "plan" : "bypassPermissions",
    ])

    #expect(invocation.executableURL == executableURL)
    #expect(invocation.executableURL.path.hasPrefix("/"))
    #expect(invocation.arguments == expectedArguments)
    #expect(invocation.arguments.filter { $0 == prompt }.count == 1)
    #expect(!invocation.arguments.contains(fixture.workingDirectory.path))
    #expect(
        invocation.environment
            == RafuConductorEnvironment.childEnvironment(
                runDirectory: fixture.runDirectory,
                handoffDirectory: fixture.handoffDirectory))
}

@Test("Claude invocation fails closed until the same adapter instance probes successfully")
func claudeInvocationFailsClosedBeforeProbe() {
    let adapter = ClaudeCodeAdapter(
        executableChecker: ClaudeFixtureExecutableChecker(executablePaths: []),
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

@Test("Claude probe uses argv-only which, preserves its absolute path, and caches the version")
func claudeProbeUsesWhichAndCachesVersion() async {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/claude")
    let runner = ClaudeRecordingProbeRunner { call in
        if call.executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            return claudeCompletion(status: 0, stdout: recordedClaudeWhichTranscript)
        }
        if call.arguments == ["--version"] {
            return claudeCompletion(status: 0, stdout: recordedClaudeVersionTranscript)
        }
        return .couldNotLaunch
    }
    let adapter = ClaudeCodeAdapter(
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [executableURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "/fixture/shims:relative:/usr/bin:/fixture/shims")

    let probe = await adapter.probe()

    #expect(probe.installed)
    #expect(probe.executableURL == executableURL)
    #expect(probe.version == "2.1.218 (Claude Code)")

    let calls = runner.recordedCalls()
    #expect(calls.count == 2)
    #expect(calls[0].executableURL.path == "/usr/bin/which")
    #expect(calls[0].arguments == ["claude"])
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
                "PATH": "/fixture/bin:\(RafuConductorEnvironment.curatedPath)",
                "HOME": "/fixture/home",
                "USER": "fixture-user",
                "LOGNAME": "fixture-user",
            ])

    let invocation = adapter.invocation(
        prompt: "cached",
        model: "fable",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))
    #expect(invocation.executableURL == executableURL)
    #expect(
        invocation.environment["PATH"]
            == "/fixture/bin:\(RafuConductorEnvironment.curatedPath)")
}

@Test("Claude probe falls back to the standard install and keeps installed true without a version")
func claudeProbeFallsBackWhenWhichFails() async {
    let homeDirectory = URL(fileURLWithPath: "/fixture/home")
    let fallbackURL = homeDirectory.appending(path: ".local/bin/claude")
    let runner = ClaudeRecordingProbeRunner { call in
        if call.executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            return claudeCompletion(status: 1)
        }
        return .timedOut
    }
    let adapter = ClaudeCodeAdapter(
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [fallbackURL.path]),
        homeDirectory: homeDirectory,
        userName: "fixture-user",
        hostSearchPath: "")

    let probe = await adapter.probe()

    #expect(probe.installed)
    #expect(probe.executableURL == fallbackURL)
    #expect(probe.version == nil)
}

@MainActor
@Test("Claude support-level discovery and filesystem checks leave MainActor")
func claudeProbeSupportRunsOffMainActor() async {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/claude")
    let runner = ClaudeRecordingProbeRunner { call in
        if call.executableURL == ConductorAdapterProbeSupport.whichExecutableURL {
            return claudeCompletion(status: 0, stdout: recordedClaudeWhichTranscript)
        }
        return claudeCompletion(status: 0, stdout: recordedClaudeVersionTranscript)
    }
    let checker = ClaudeThreadRecordingExecutableChecker(executablePath: executableURL.path)
    let adapter = ClaudeCodeAdapter(
        runner: runner,
        executableChecker: checker,
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    #expect((await adapter.probe()).installed)
    #expect(!checker.wasCalledOnMainThread())
}

@Test("A cancelled Claude discovery stops before fallback and preserves the prior cache")
func claudeCancelledDiscoveryPreservesCache() async {
    let priorExecutableURL = URL(fileURLWithPath: "/fixture/prior/claude")
    let fallbackURL = URL(fileURLWithPath: "/fixture/home/.local/bin/claude")
    let runner = ClaudeRecordingProbeRunner { _ in .cancelled }
    let adapter = ClaudeCodeAdapter(
        executableURL: priorExecutableURL,
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [fallbackURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    let probe = await adapter.probe()
    let invocation = adapter.invocation(
        prompt: "preserve",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))

    #expect(probe.executableURL == priorExecutableURL)
    #expect(invocation.executableURL == priorExecutableURL)
    #expect(runner.recordedCalls().count == 1)
}

@Test("A cancelled Claude auth discovery does not populate the executable cache")
func claudeCancelledAuthDiscoveryDoesNotCacheFallback() async {
    let fallbackURL = URL(fileURLWithPath: "/fixture/home/.local/bin/claude")
    let runner = ClaudeRecordingProbeRunner { _ in .cancelled }
    let adapter = ClaudeCodeAdapter(
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [fallbackURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    #expect(await adapter.authStatus() == .unknown())
    let invocation = adapter.invocation(
        prompt: "fail closed",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))
    #expect(invocation.executableURL.path == "/usr/bin/false")
    #expect(runner.recordedCalls().count == 1)
}

@Test("A stale failed Claude probe cannot clear a newer successful cache")
func claudeConcurrentProbeCacheUsesNewestGeneration() async {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/claude")
    let runner = ClaudeOverlappingProbeRunner(executableURL: executableURL)
    let adapter = ClaudeCodeAdapter(
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [executableURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    let staleProbeTask = Task { await adapter.probe() }
    await runner.waitUntilFirstWhichStarts()
    let newestProbe = await adapter.probe()
    _ = await staleProbeTask.value

    let invocation = adapter.invocation(
        prompt: "newest wins",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))
    #expect(newestProbe.executableURL == executableURL)
    #expect(invocation.executableURL == executableURL)
}

@Test("A newer cancelled Claude probe cannot suppress an older successful commit")
func claudeCancelledGenerationDoesNotSuppressSuccess() async {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/claude")
    let runner = ClaudeSuccessfulThenCancelledProbeRunner(executableURL: executableURL)
    let adapter = ClaudeCodeAdapter(
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [executableURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    let successfulProbeTask = Task { await adapter.probe() }
    await runner.waitUntilFirstWhichStarts()
    _ = await adapter.probe()
    let successfulProbe = await successfulProbeTask.value

    let invocation = adapter.invocation(
        prompt: "success survives",
        model: "",
        autonomy: .readOnly,
        workingDirectory: URL(fileURLWithPath: "/tmp/work"),
        runDirectory: URL(fileURLWithPath: "/tmp/run"),
        handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))
    #expect(successfulProbe.executableURL == executableURL)
    #expect(invocation.executableURL == executableURL)
}

@Test("Claude auth uses status exit metadata only and discards command output")
func claudeAuthUsesExitMetadataOnly() async {
    let executableURL = URL(fileURLWithPath: "/fixture/bin/claude")
    let runner = ClaudeRecordingProbeRunner { _ in
        claudeCompletion(status: 0, stdout: recordedClaudeUnauthenticatedTranscript)
    }
    let adapter = ClaudeCodeAdapter(
        executableURL: executableURL,
        runner: runner,
        executableChecker: ClaudeFixtureExecutableChecker(
            executablePaths: [executableURL.path]),
        homeDirectory: URL(fileURLWithPath: "/fixture/home"),
        userName: "fixture-user",
        hostSearchPath: "")

    #expect(await adapter.authStatus() == .authenticated)
    let calls = runner.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls[0].arguments == ["auth", "status", "--json"])
    #expect(calls[0].outputPolicy == .discard)
    #expect(
        calls[0].environment
            == [
                "PATH": "/fixture/bin:\(RafuConductorEnvironment.curatedPath)",
                "HOME": "/fixture/home",
                "USER": "fixture-user",
                "LOGNAME": "fixture-user",
            ])
}

@Test("Claude auth exit 0, 1, unexpected, timeout, and cancellation classify honestly")
func claudeAuthClassification() {
    #expect(
        ClaudeCodeAdapter.authStatus(
            from: claudeCompletion(status: 0, stdout: recordedClaudeUnauthenticatedTranscript))
            == .authenticated)
    #expect(
        ClaudeCodeAdapter.authStatus(
            from: claudeCompletion(status: 1, stdout: recordedClaudeAuthenticatedTranscript))
            == .notAuthenticated(hint: "run `claude` in a terminal and log in"))
    #expect(ClaudeCodeAdapter.authStatus(from: claudeCompletion(status: 2)) == .unknown())
    #expect(ClaudeCodeAdapter.authStatus(from: .timedOut) == .unknown())
    #expect(ClaudeCodeAdapter.authStatus(from: .cancelled) == .unknown())
}

/// The normally-exiting path used to end in a bare `process.waitUntilExit()`,
/// which takes no deadline and was observed blocking forever — one probe
/// stalling the whole `--no-parallel` suite with no output
/// (`conductor-pty-spawn-and-child-environment.md`, finding 3). That call is
/// gone; these two assert the replacement still reports the child's real exit
/// status, which is the thing a bounded wait could plausibly break.
@Test("A probe child that exits cleanly completes with its zero status")
func conductorProbeRunnerCompletesZeroExit() async {
    let runner = ConductorProbeProcessRunner(
        timeout: .seconds(5), maximumOutputBytes: 1_024)
    let outcome = await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"],
        outputPolicy: .discard)

    guard case .completed(let completion) = outcome else {
        Issue.record("Expected a completed probe, got \(outcome)")
        return
    }
    #expect(completion.terminationStatus == 0)
}

@Test("A probe child that exits nonzero reports that status, not success")
func conductorProbeRunnerReportsNonzeroExit() async {
    let runner = ConductorProbeProcessRunner(
        timeout: .seconds(5), maximumOutputBytes: 1_024)
    let outcome = await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"],
        outputPolicy: .discard)

    guard case .completed(let completion) = outcome else {
        Issue.record("Expected a completed probe, got \(outcome)")
        return
    }
    #expect(completion.terminationStatus != 0)
}

@Test("The real adapter probe runner enforces its timeout and reaps the child")
func conductorProbeRunnerTimesOut() async {
    let runner = ConductorProbeProcessRunner(
        timeout: .milliseconds(40), maximumOutputBytes: 1_024)
    // 30s, not ~2s: the runner polls its deadline every 20ms, so under a
    // starved scheduler (parallel test load) a short-lived child can EXIT
    // before the poller ever wakes, and the outcome becomes "completed"
    // instead of `.timedOut` — an observed 2/6 flake at "2". The child never
    // actually sleeps this long: the timeout path SIGTERMs it immediately.
    let outcome = await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["30"],
        environment: ["PATH": "/usr/bin:/bin"],
        outputPolicy: .discard)

    guard case .timedOut = outcome else {
        Issue.record("Expected the bounded probe to time out")
        return
    }
}

@Test("The real adapter probe runner propagates cancellation and reaps the child")
func conductorProbeRunnerCancels() async {
    let registry = ProcessResourceRegistry()
    let registrationLatch = ClaudeProbeRegistrationLatch()
    let runner = ConductorProbeProcessRunner(
        timeout: .seconds(5),
        maximumOutputBytes: 1_024,
        registry: registry,
        onRegistered: { processIdentifier in
            await registrationLatch.signal(processIdentifier: processIdentifier)
        })
    let task = Task {
        // "30" for the same starvation reason as the timeout test above:
        // the child must outlive any scheduler stall so cancellation, not
        // natural exit, is always what ends it. It is SIGTERMed on cancel.
        await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: ["PATH": "/usr/bin:/bin"],
            outputPolicy: .discard)
    }
    let processIdentifier = await registrationLatch.wait()
    task.cancel()

    let outcome = await task.value
    guard case .cancelled = outcome else {
        Issue.record("Expected the bounded probe to observe cancellation")
        return
    }
    #expect(await registry.sample().isEmpty)
    #expect(kill(processIdentifier, 0) == -1)
    #expect(errno == ESRCH)
}

@Test("The real adapter probe runner rejects captured output over its cap")
func conductorProbeRunnerCapsOutput() async {
    let runner = ConductorProbeProcessRunner(
        timeout: .seconds(1), maximumOutputBytes: 64)
    let outcome = await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"],
        outputPolicy: .capture)

    guard case .outputLimitExceeded = outcome else {
        Issue.record("Expected the bounded probe to reject oversized output")
        return
    }
}
