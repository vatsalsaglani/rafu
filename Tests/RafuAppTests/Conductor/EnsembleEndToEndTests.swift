import Foundation
import Testing

@testable import RafuApp
@testable import RafuCore

@MainActor
@Suite("Ensemble headless end to end")
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
        eventCenter: ConductorEnsembleEventCenter
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
        session.conductorRunController.publish(
            endToEndManifest(status: status, evidencePath: evidencePath))
        return EndToEndFixture(root: root, session: session)
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

    var socketURL: URL {
        LauncherIPCSocketPath.resolve(
            baseDirectory: root.appending(path: "runtime", directoryHint: .isDirectory))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
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
