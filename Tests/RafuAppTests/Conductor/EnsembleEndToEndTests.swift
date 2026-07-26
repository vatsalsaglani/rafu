import Foundation
import Testing

@testable import RafuApp
@testable import RafuCore

// `.serialized`: each test binds a real Unix-domain socket and drives a
// real `LauncherIPCServer` actor plus a `Task.detached` client doing
// blocking POSIX socket I/O. Four such flows racing in parallel (C8-04
// added the fourth, `proposeMergeEndToEnd`) were observed to starve the
// cooperative thread pool under load and miss the 2-second one-shot
// timeout — reproduced by running all four together (fails) versus any
// three (passes) versus each alone (passes). Serializing costs a little
// wall time and removes the contention entirely, matching the same
// precedent `EnsembleMutatingVerbTests`/`EnsembleServerStreamTests`/
// `EnsembleCoordinatorLaunchTests` already establish for this exact class
// of problem.
@MainActor
@Suite("Ensemble headless end to end", .serialized)
struct EnsembleEndToEndTests {
    @Test("Status crosses the real CLI, UID-authenticated server, and request service")
    func statusEndToEnd() async throws {
        let fixture = try makeFixture(status: .running)
        defer { fixture.remove() }

        let result = try await runOneShot(
            try EnsembleArgumentParser().parse(["status"]),
            fixture: fixture
        )

        #expect(result.exitCode == .ok)
        #expect(result.standardOutput == "run-a running Workflow")
        #expect(result.standardError.isEmpty)
    }

    @Test("Artifact crosses the real CLI, UID-authenticated server, and request service")
    func artifactEndToEnd() async throws {
        let fixture = try makeFixture(
            status: .completed,
            evidencePath: "steps/01-worker-a2"
        )
        defer { fixture.remove() }

        let result = try await runOneShot(
            try EnsembleArgumentParser().parse(["artifact", "run-a", "0"]),
            fixture: fixture
        )

        #expect(result.exitCode == .ok)
        #expect(
            result.standardOutput
                == fixture.root
                .appending(path: ".rafu/runs/run-a/steps/01-worker-a2/handoff/report.md")
                .standardizedFileURL.path
        )
        #expect(result.standardError.isEmpty)
    }

    @Test("Await subscribes, snapshots, then consumes a pushed server event")
    func awaitEndToEnd() async throws {
        let fixture = try makeFixture(status: .running)
        defer { fixture.remove() }
        let center = quietEventCenter()
        let service = requestService(fixture: fixture, eventCenter: center)
        let hook = AwaitSnapshotHook(service: service, eventCenter: center)
        let server = LauncherIPCServer(
            socketURL: fixture.socketURL,
            handler: { envelope in
                if envelope.kind == .handshake {
                    return .accepted(
                        workspaceMatched: false,
                        windowFocused: false,
                        waitSupported: false
                    )
                }
                return hook.handle(envelope)
            },
            subscriptionHandler: { envelope in
                guard envelope.kind == .ensembleSubscribe,
                    envelope.ensemble?.verb == "await"
                else { return nil }
                return center.subscribe()
            },
            subscriptionCursor: { center.cursor }
        )
        try await server.startListening()
        let runner = EnsembleCommandRunner(
            client: EnsembleCLIClient(socketURL: fixture.socketURL))
        let workingDirectory = fixture.root.path
        let invocation = try EnsembleArgumentParser().parse([
            "await", "run-a", "--state", "completed", "--timeout", "30",
        ])

        let result = await Task.detached(name: "Ensemble end-to-end CLI") {
            runner.run(invocation, workingDirectory: workingDirectory)
        }.value
        center.finishSubscriptionsForTesting()
        await server.stopListening()

        #expect(result.exitCode == .ok)
        #expect(result.standardOutput == "run-a completed")
        #expect(result.standardError.isEmpty)
        #expect(hook.didPublishAfterSnapshot)
    }

    @Test("propose-merge crosses the real CLI, UID-authenticated server, and request service")
    func proposeMergeEndToEnd() async throws {
        let fixture = try makeFixture(status: .completed)
        defer { fixture.remove() }
        var manifest = try #require(fixture.session.conductorRuns.first)
        manifest.gate = ConductorRunManifest.Gate(kind: .merge, stepIndex: 0)
        manifest.startedBy = "co-e2e"
        fixture.session.conductorRunController.publish(manifest)

        let tokenStore = ConductorEnsembleTokenStore(
            randomBytes: { count in [UInt8](repeating: 7, count: count) })
        let token = tokenStore.mint(
            coordinatorID: "co-e2e",
            grant: ConductorEnsembleGrant(allowedProviders: [.codex]))

        let center = quietEventCenter()
        let service = requestService(fixture: fixture, eventCenter: center, tokenStore: tokenStore)
        let server = LauncherIPCServer(
            socketURL: fixture.socketURL,
            handler: { envelope in
                if envelope.kind == .handshake {
                    return .accepted(
                        workspaceMatched: false,
                        windowFocused: false,
                        waitSupported: false
                    )
                }
                return await service.handleAsync(envelope)
            }
        )
        try await server.startListening()
        let runner = EnsembleCommandRunner(
            client: EnsembleCLIClient(socketURL: fixture.socketURL),
            tokenProvider: { token }
        )
        let workingDirectory = fixture.root.path
        let invocation = try EnsembleArgumentParser().parse([
            "propose-merge", "run-a", "--message", "Please review the diff.",
        ])

        let result = await Task.detached(name: "Ensemble end-to-end CLI") {
            runner.run(invocation, workingDirectory: workingDirectory)
        }.value
        await server.stopListening()

        #expect(result.exitCode == .ok)
        #expect(result.standardOutput == "run-a proposed awaiting_human")
        #expect(result.standardError.isEmpty)
        #expect(!result.standardOutput.contains(token))

        // The FULL real-socket round trip re-raised gate attention through
        // WorkspaceSession's real notification leg without crashing —
        // proving propose-merge is headless-safe end to end, not merely
        // avoiding the crash by disabling surfaces.
        await fixture.waitForNotification()
        #expect(fixture.attentionHUD.shown.count == 1)
        #expect(fixture.attentionNotifier.posted.count == 1)
        #expect(
            fixture.attentionNotifier.posted.first?.kind
                == .ensembleGate(runID: "run-a", allowsApprove: false))
    }

    private func runOneShot(
        _ invocation: EnsembleInvocation,
        fixture: EndToEndFixture
    ) async throws -> EnsembleCommandResult {
        let center = quietEventCenter()
        let service = requestService(fixture: fixture, eventCenter: center)
        let server = LauncherIPCServer(
            socketURL: fixture.socketURL,
            handler: { envelope in
                if envelope.kind == .handshake {
                    return .accepted(
                        workspaceMatched: false,
                        windowFocused: false,
                        waitSupported: false
                    )
                }
                return service.handle(envelope)
            }
        )
        try await server.startListening()
        let runner = EnsembleCommandRunner(
            client: EnsembleCLIClient(socketURL: fixture.socketURL))
        let workingDirectory = fixture.root.path

        let result = await Task.detached(name: "Ensemble end-to-end CLI") {
            runner.run(invocation, workingDirectory: workingDirectory)
        }.value
        await server.stopListening()
        return result
    }

    private func requestService(
        fixture: EndToEndFixture,
        eventCenter: ConductorEnsembleEventCenter,
        tokenStore: ConductorEnsembleTokenStore = .shared
    ) -> ConductorEnsembleRequestService {
        ConductorEnsembleRequestService(
            dependencies: .init(
                workspaces: {
                    [
                        .init(
                            rootURL: fixture.root,
                            session: fixture.session,
                            isKeyWindow: true,
                            registrationOrder: 0
                        )
                    ]
                },
                liveState: { _, _ in nil },
                tokenStore: tokenStore,
                eventCenter: eventCenter
            ))
    }

    private func quietEventCenter() -> ConductorEnsembleEventCenter {
        ConductorEnsembleEventCenter(sleep: { _ in throw CancellationError() })
    }

    private func makeFixture(
        status: RunStepStatus,
        evidencePath: String? = nil
    ) throws -> EndToEndFixture {
        let root = URL(
            fileURLWithPath: "/tmp/rafu-ensemble-e2e-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let session = WorkspaceSession()
        let attentionSuiteName = "EnsembleEndToEndTests.\(UUID().uuidString)"
        let surfaceStore = TerminalAttentionSurfaceStore(suiteName: attentionSuiteName)
        surfaceStore.setSurface(.both)
        session.terminalAttentionSurfaceStore = surfaceStore
        let attentionNotifier = EndToEndAttentionSpyNotifier()
        session.attentionNotifier = attentionNotifier
        let attentionHUD = EndToEndAttentionSpyHUD()
        session.attentionHUD = attentionHUD
        session.hudThemeProvider = { RafuThemeCatalog.indigo }
        session.conductorRunController.publish(
            endToEndManifest(status: status, evidencePath: evidencePath))
        return EndToEndFixture(
            root: root,
            session: session,
            attentionNotifier: attentionNotifier,
            attentionHUD: attentionHUD,
            attentionSuiteName: attentionSuiteName)
    }
}

@MainActor
private final class AwaitSnapshotHook {
    private let service: ConductorEnsembleRequestService
    private let eventCenter: ConductorEnsembleEventCenter
    private(set) var didPublishAfterSnapshot = false

    init(
        service: ConductorEnsembleRequestService,
        eventCenter: ConductorEnsembleEventCenter
    ) {
        self.service = service
        self.eventCenter = eventCenter
    }

    func handle(_ envelope: LauncherIPCEnvelope) -> LauncherIPCResponse {
        let response = service.handle(envelope)
        if envelope.kind == .ensembleStatus, !didPublishAfterSnapshot {
            didPublishAfterSnapshot = true
            eventCenter.publish(
                EnsembleEvent(
                    cursor: 0,
                    at: Date(timeIntervalSince1970: 3),
                    runID: "run-a",
                    kind: "state",
                    state: .completed
                ))
        }
        return response
    }
}

@MainActor
private struct EndToEndFixture {
    let root: URL
    let session: WorkspaceSession
    let attentionNotifier: EndToEndAttentionSpyNotifier
    let attentionHUD: EndToEndAttentionSpyHUD
    let attentionSuiteName: String

    var socketURL: URL {
        LauncherIPCSocketPath.resolve(
            baseDirectory: root.appending(path: "runtime", directoryHint: .isDirectory))
    }

    /// Polls briefly for the fire-and-forget notification Task
    /// `raiseConductorGateAttention` starts internally.
    func waitForNotification(count: Int = 1) async {
        for _ in 0..<20_000 {
            if attentionNotifier.posted.count >= count { break }
            await Task.yield()
        }
    }

    func remove() {
        UserDefaults(suiteName: attentionSuiteName)?.removePersistentDomain(
            forName: attentionSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

/// `propose-merge` raises gate attention through the real `WorkspaceSession`
/// seam; this rig keeps that FULL path (HUD + notification) reachable and
/// headless-safe, mirroring `WorkflowPresentationTests.installGateAttentionRig`
/// — `.both` matches the real app default, and these spies absorb what would
/// otherwise construct the real, bundle-requiring `UNUserNotificationCenter`.
@MainActor
private final class EndToEndAttentionSpyNotifier: TerminalAttentionNotifying {
    private(set) var posted: [TerminalAttentionNotification] = []

    func requestAuthorizationIfNeeded() async -> Bool { true }

    func post(_ notification: TerminalAttentionNotification) {
        posted.append(notification)
    }
}

@MainActor
private final class EndToEndAttentionSpyHUD: NotchHUDPresenting {
    private(set) var shown: [NotchHUDEvent] = []

    func show(_ event: NotchHUDEvent, theme: RafuTheme) {
        shown.append(event)
    }

    func attentionCleared(for sessionID: UUID) {}
}

private func endToEndManifest(
    status: RunStepStatus,
    evidencePath: String?
) -> ConductorRunManifest {
    let binding = ConductorRunManifest.AgentBinding(
        provider: .codex,
        model: "gpt-5.6",
        autonomy: .readOnly,
        adapterVersion: "1"
    )
    return ConductorRunManifest(
        id: "run-a",
        workflowName: "Workflow",
        baseCommit: "abc",
        worktreeBranch: "rafu/run-run-a",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        steps: [
            .init(
                agentName: "worker",
                binding: binding,
                inputArtifacts: [],
                handoffArtifact: "report.md",
                gateAfter: false,
                status: status,
                startedAt: nil,
                finishedAt: nil,
                attempt: 2,
                evidencePath: evidencePath
            )
        ]
    )
}
