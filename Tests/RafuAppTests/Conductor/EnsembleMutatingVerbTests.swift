import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Ensemble mutating verbs", .serialized)
struct EnsembleMutatingVerbTests {
    @Test("A live coordinator runs, notes, grants, and aborts end to end")
    func lifecycle() async throws {
        let harness = try MutatingVerbHarness(runIDs: ["run-primary"])
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-primary",
            grant: harness.grant(concurrent: 3, total: 12)
        )
        let artifact = harness.root.appending(path: "fixture.txt").path

        let started = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run",
                workingDirectory: harness.root.path,
                token: token,
                workflow: "ship",
                roleOverrides: [
                    EnsembleRoleOverride(
                        name: "Worker",
                        provider: ConductorCLIID.codex.rawValue,
                        model: "fake-deep"
                    )
                ],
                prompt: "Implement the plan",
                artifacts: [artifact],
                label: "Release work"
            )
        )
        let startResult = try #require(started.runStarted)
        #expect(startResult.runID == "run-primary")
        #expect(startResult.startedBy == "co-primary")
        #expect(startResult.branch == "rafu/run-run-primary")
        #expect(startResult.worktree.hasSuffix("-run-primary"))

        let manifest = try #require(
            harness.session.conductorRuns.first { $0.id == "run-primary" }
        )
        #expect(manifest.startedBy == "co-primary")
        #expect(manifest.label == "Release work")
        #expect(manifest.steps[0].binding.model == "fake-deep")

        let launcher = try #require(harness.launchers.first)
        let process = try #require(launcher.recorded.first?.specification)
        #expect(
            Set(process.environment.keys)
                == ["PATH", "RAFU_HANDOFF", "RAFU_RUN_DIR"]
        )
        #expect(process.environment["RAFU_ENSEMBLE_TOKEN"] == nil)
        #expect(process.arguments.joined(separator: "\n").contains(artifact))
        #expect(!process.arguments.joined(separator: "\n").contains("fixture\n"))

        let tree = await harness.request(
            kind: .ensembleStatus,
            payload: EnsembleRequestPayload(
                verb: "status",
                workingDirectory: harness.root.path,
                tree: true
            )
        )
        let status = try #require(tree.status)
        #expect(status.runs.map(\.runID) == ["run-primary"])
        #expect(status.runs[0].startedBy == "co-primary")

        let noted = await harness.request(
            kind: .ensembleNote,
            payload: EnsembleRequestPayload(
                verb: "note",
                workingDirectory: harness.root.path,
                runIDs: ["run-primary"],
                token: token,
                text: "Inspect the generated patch."
            )
        )
        #expect(noted.mutation?.verb == "noted")
        let notes = try await ConductorEnsembleNoteStore(
            workspaceRoot: harness.root,
            eventCenter: harness.eventCenter
        ).read(runID: "run-primary")
        #expect(notes.map(\.text) == ["Inspect the generated patch."])
        #expect(
            harness.eventCenter.eventsSince(0).contains {
                $0.kind == "note" && $0.runID == "run-primary"
            }
        )

        let granted = await harness.request(
            kind: .ensembleGrant,
            payload: EnsembleRequestPayload(
                verb: "grant",
                workingDirectory: harness.root.path,
                token: token
            )
        )
        #expect(granted.grant?.activeChildRuns == 1)
        #expect(granted.grant?.startedChildRuns == 1)

        let foreignToken = harness.mint(
            coordinatorID: "co-foreign",
            grant: harness.grant(concurrent: 3, total: 12)
        )
        let foreignAbort = await harness.request(
            kind: .ensembleAbort,
            payload: EnsembleRequestPayload(
                verb: "abort",
                workingDirectory: harness.root.path,
                runIDs: ["run-primary"],
                token: foreignToken
            )
        )
        #expect(foreignAbort.failure?.code == 77)

        let aborted = await harness.request(
            kind: .ensembleAbort,
            payload: EnsembleRequestPayload(
                verb: "abort",
                workingDirectory: harness.root.path,
                runIDs: ["run-primary"],
                token: token
            )
        )
        #expect(aborted.mutation?.state == .aborted)

        let controller = try #require(harness.coordinator.controller(runID: "run-primary"))
        await controller.waitForPendingOperation()
        let persisted = try await ConductorRunStore(workspaceRoot: harness.root)
            .load(runID: "run-primary")
        #expect(persisted?.startedBy == "co-primary")
        #expect(persisted?.label == "Release work")
    }

    @Test("Every tokenless mutating verb is refused with 77")
    func tokenlessMutations() async throws {
        let harness = try MutatingVerbHarness(runIDs: ["never-used"])
        defer { harness.cleanUp() }
        let requests: [(LauncherIPCRequestKind, EnsembleRequestPayload)] = [
            (
                .ensembleRun,
                EnsembleRequestPayload(
                    verb: "run",
                    workingDirectory: harness.root.path,
                    workflow: "ship"
                )
            ),
            (
                .ensembleAbort,
                EnsembleRequestPayload(
                    verb: "abort",
                    workingDirectory: harness.root.path,
                    runIDs: ["run-a"]
                )
            ),
            (
                .ensembleNote,
                EnsembleRequestPayload(
                    verb: "note",
                    workingDirectory: harness.root.path,
                    runIDs: ["run-a"],
                    text: "note"
                )
            ),
            (
                .ensembleGrant,
                EnsembleRequestPayload(
                    verb: "grant",
                    workingDirectory: harness.root.path
                )
            ),
        ]

        for (kind, payload) in requests {
            let response = await harness.request(kind: kind, payload: payload)
            #expect(response.failure?.code == 77)
        }
        #expect(harness.launchers.isEmpty)
    }

    @Test("The window cap remains the tighter limit and tree output groups children")
    func windowAndGrantCaps() async throws {
        let harness = try MutatingVerbHarness(
            activeLimit: 3,
            runIDs: ["child-a", "child-b", "child-c", "child-d"]
        )
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-fanout",
            grant: harness.grant(concurrent: 5, total: 8)
        )

        for index in 0..<3 {
            let response = await harness.request(
                kind: .ensembleRun,
                payload: EnsembleRequestPayload(
                    verb: "run",
                    workingDirectory: harness.root.path,
                    token: token,
                    workflow: "ship",
                    label: "Child \(index + 1)"
                )
            )
            #expect(response.runStarted != nil)
        }
        let parked = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run",
                workingDirectory: harness.root.path,
                token: token,
                workflow: "ship"
            )
        )
        #expect(parked.failure?.code == 75)
        #expect(harness.coordinator.activeCount == 3)
        #expect(harness.tokenStore.validate(token)?.startedRunIDs.count == 3)

        let tree = await harness.request(
            kind: .ensembleStatus,
            payload: EnsembleRequestPayload(
                verb: "status",
                workingDirectory: harness.root.path,
                tree: true
            )
        )
        let runs = try #require(tree.status?.runs)
        #expect(Set(runs.map(\.runID)) == ["child-a", "child-b", "child-c"])
        #expect(runs.allSatisfy { $0.startedBy == "co-fanout" })

        for controller in harness.coordinator.controllers {
            controller.abort()
        }
    }

    @Test("A full notes log refuses another append with 75")
    func notesBound() async throws {
        let harness = try MutatingVerbHarness(runIDs: ["run-full"])
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-notes",
            grant: harness.grant(concurrent: 1, total: 1)
        )
        _ = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run",
                workingDirectory: harness.root.path,
                token: token,
                workflow: "ship"
            )
        )
        let notesURL = harness.root.appending(path: ".rafu/runs/run-full/notes.jsonl")
        try Data(
            repeating: 0x20,
            count: ConductorEnsembleNoteStore.maximumFileBytes
        ).write(to: notesURL, options: .atomic)

        let response = await harness.request(
            kind: .ensembleNote,
            payload: EnsembleRequestPayload(
                verb: "note",
                workingDirectory: harness.root.path,
                runIDs: ["run-full"],
                token: token,
                text: "one more"
            )
        )
        #expect(response.failure?.code == 75)
        harness.coordinator.controller(runID: "run-full")?.abort()
    }
}

@MainActor
private final class MutatingVerbHarness {
    let container: URL
    let root: URL
    let session: WorkspaceSession
    let eventCenter: ConductorEnsembleEventCenter
    let tokenStore: ConductorEnsembleTokenStore
    let coordinator: ConductorConcurrentRunCoordinator
    private let definitionLibrary: ConductorDefinitionLibrary
    private var pendingRunIDs: [String]
    private(set) var launchers: [WorkflowFakeLauncher] = []

    init(
        activeLimit: Int = 3,
        runIDs: [String]
    ) throws {
        container = FileManager.default.temporaryDirectory
            .appending(
                path: "rafu-ensemble-mutating-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        root = container.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try initializeWorkflowRepository(at: root)
        try Self.writeDefinitions(to: root)

        session = WorkspaceSession()
        eventCenter = ConductorEnsembleEventCenter(
            sleep: { _ in throw CancellationError() }
        )
        let byteSource = TestTokenByteSource()
        tokenStore = ConductorEnsembleTokenStore(
            randomBytes: { count in byteSource.next(count: count) }
        )
        let adapter = FakeConductorAdapter(id: .codex)
        session.conductorRunController.attach(workspaceRoot: root)
        coordinator = ConductorConcurrentRunCoordinator(
            runsPublisher: session.conductorRunController,
            adapters: [adapter],
            activeLimit: activeLimit
        )
        coordinator.attach(workspaceRoot: root)
        definitionLibrary = ConductorDefinitionLibrary(
            adapters: [adapter],
            enableStore: ConductorEnableStore(
                suiteName: "EnsembleMutatingVerbTests-\(UUID().uuidString)"
            )
        )
        pendingRunIDs = runIDs
    }

    func cleanUp() {
        for controller in coordinator.controllers where controller.isInFlight {
            controller.abort()
        }
        try? FileManager.default.removeItem(at: container)
    }

    func mint(
        coordinatorID: String,
        grant: ConductorEnsembleGrant
    ) -> String {
        tokenStore.mint(coordinatorID: coordinatorID, grant: grant)
    }

    func grant(
        concurrent: Int,
        total: Int
    ) -> ConductorEnsembleGrant {
        ConductorEnsembleGrant(
            maxConcurrentChildRuns: concurrent,
            maxTotalChildRuns: total,
            allowedProviders: [.codex]
        )
    }

    func request(
        kind: LauncherIPCRequestKind,
        payload: EnsembleRequestPayload
    ) async -> TestEnsembleResponse {
        let response = await service().handleAsync(
            LauncherIPCEnvelope(kind: kind, ensemble: payload)
        )
        guard case .ensemble(let ensemble) = response else {
            return TestEnsembleResponse(
                payload: .failure(code: 69, message: "unexpected response")
            )
        }
        return TestEnsembleResponse(payload: ensemble)
    }

    private func service() -> ConductorEnsembleRequestService {
        ConductorEnsembleRequestService(
            dependencies: .init(
                workspaces: {
                    [
                        .init(
                            rootURL: self.root,
                            session: self.session,
                            isKeyWindow: true,
                            registrationOrder: 0
                        )
                    ]
                },
                liveState: { _, runID in
                    self.coordinator.controller(runID: runID)?.state
                },
                workflowController: { _, runID in
                    self.coordinator.controller(runID: runID)
                },
                startRun: { _, request in
                    let launcher = WorkflowFakeLauncher()
                    self.launchers.append(launcher)
                    return try await self.coordinator.start(
                        request,
                        launcher: launcher
                    )
                },
                definitionLibrary: definitionLibrary,
                userLibraryRoot: {
                    self.container.appending(
                        path: "empty-user-library",
                        directoryHint: .isDirectory
                    )
                },
                tokenStore: tokenStore,
                eventCenter: eventCenter,
                makeRunID: {
                    precondition(!self.pendingRunIDs.isEmpty)
                    return self.pendingRunIDs.removeFirst()
                }
            )
        )
    }

    private static func writeDefinitions(to root: URL) throws {
        let dot = RafuDotDirectory(workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: dot.agentsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dot.workflowsURL,
            withIntermediateDirectories: true
        )
        try Data(
            """
            ---
            name: Worker
            provider: codex
            model: fake-fast
            autonomy: worktreeWrite
            handoffArtifact: report.md
            ---
            Follow the requested workflow.
            """.utf8
        ).write(to: dot.agentsURL.appending(path: "worker.md"), options: .atomic)
        try Data(
            """
            ---
            name: Ship
            steps:
              - Worker
            ---
            """.utf8
        ).write(to: dot.workflowsURL.appending(path: "ship.md"), options: .atomic)
    }
}

@MainActor
private final class TestTokenByteSource {
    private var generation: UInt8 = 0

    func next(count: Int) -> [UInt8] {
        generation &+= 1
        return (0..<count).map { UInt8($0 % 251) &+ generation }
    }
}

private struct TestEnsembleResponse {
    let payload: EnsembleResponsePayload

    var runStarted: EnsembleRunStartResult? {
        guard case .runStarted(let value) = payload else { return nil }
        return value
    }

    var status: EnsembleStatusResult? {
        guard case .status(let value) = payload else { return nil }
        return value
    }

    var mutation: EnsembleMutationResult? {
        guard case .mutation(let value) = payload else { return nil }
        return value
    }

    var grant: EnsembleGrantResult? {
        guard case .grant(let value) = payload else { return nil }
        return value
    }

    var failure: (code: Int32, message: String)? {
        guard case .failure(let code, let message) = payload else { return nil }
        return (code, message)
    }
}
