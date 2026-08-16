import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Ensemble coordinator launch", .serialized)
struct EnsembleCoordinatorLaunchTests {
    @Test("Launch registers and reveals a token-bearing interactive terminal")
    func launchAndRevoke() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "rafu-coordinator-launch-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eventCenter = ConductorEnsembleEventCenter(
            sleep: { _ in throw CancellationError() }
        )
        let tokenStore = ConductorEnsembleTokenStore(
            randomBytes: { count in
                Array((0..<count).map { UInt8(($0 + 29) % 251) })
            },
            clock: { now }
        )
        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        let launcher = ConductorCoordinatorLauncher(
            adapters: [AuthenticatedCoordinatorAdapter(id: .codex)],
            tokenStore: tokenStore,
            eventCenter: eventCenter,
            clock: { now },
            makeCoordinatorID: { "co-test0001" }
        )

        let coordinator = try await launcher.start(
            provider: .codex,
            model: "test-model",
            goal: "Coordinate the release",
            grant: ConductorEnsembleGrant(
                maxConcurrentChildRuns: 2,
                maxTotalChildRuns: 4,
                allowedProviders: [.codex]
            ),
            in: session
        )

        #expect(coordinator.id == "co-test0001")
        #expect(coordinator.goal == "Coordinate the release")
        #expect(session.conductorCoordinatorSessions.map(\.id) == ["co-test0001"])
        let terminalID = try #require(coordinator.terminalSessionID)
        #expect(session.terminal.selectedID == terminalID)
        let groupID = try #require(session.terminal.terminalGroupAndPane(containing: terminalID)?.0)
        #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: groupID)) != nil)
        let group = try #require(session.terminal.terminalGroup(groupID))
        #expect(group.panes.count == 1)
        #expect(group.panes[0].runtimeKind == .ensembleCoordinator)

        let terminal = try #require(
            session.terminal.sessions.first { $0.id == terminalID }
        )
        let spec = try #require(terminal.processSpec)
        #expect(spec.executableURL == URL(fileURLWithPath: "/bin/echo"))
        #expect(spec.arguments == ["--model", "test-model"])
        #expect(!spec.arguments.contains(coordinator.goal))
        #expect(spec.currentDirectoryPath == root.standardizedFileURL.path)
        #expect(Set(spec.environment.keys) == ["PATH", "RAFU_ENSEMBLE_TOKEN"])
        #expect(spec.environment["PATH"] == RafuConductorEnvironment.curatedPath)
        #expect(spec.outputLogURL == nil)
        #expect(spec.roleBadge == "Coordinator")
        #expect(spec.resourceAttribution == "coordinator • Codex")

        let token = try #require(spec.environment["RAFU_ENSEMBLE_TOKEN"])
        #expect(tokenStore.validate(token)?.coordinatorID == "co-test0001")

        terminal.processDidTerminate(exitCode: 0)
        terminal.processDidTerminate(exitCode: 0)

        #expect(session.conductorCoordinatorSessions[0].endedAt != nil)
        #expect(tokenStore.validate(token) == nil)
        #expect(
            eventCenter.eventsSince(0).filter {
                $0.runID == "co-test0001" && $0.state == .completed
            }.count == 1)
        #expect(
            eventCenter.eventsSince(0).contains {
                $0.runID == "co-test0001"
                    && $0.kind == "state"
                    && $0.state == .completed
            }
        )

        let postExit = await ConductorEnsembleRequestService(
            dependencies: .init(
                workspaces: {
                    [
                        .init(
                            rootURL: root,
                            session: session,
                            isKeyWindow: true,
                            registrationOrder: 0
                        )
                    ]
                },
                liveState: { _, _ in nil },
                tokenStore: tokenStore,
                eventCenter: eventCenter
            )
        ).handleAsync(
            LauncherIPCEnvelope(
                kind: .ensembleRun,
                ensemble: EnsembleRequestPayload(
                    verb: "run",
                    workingDirectory: root.path,
                    token: token,
                    workflow: "ship"
                )
            )
        )
        guard case .ensemble(.failure(let code, let message)) = postExit else {
            Issue.record("Expected a revoked-capability failure")
            return
        }
        #expect(code == 77)
        #expect(!message.contains(token))
    }

    @Test("Worker children retain the exact three-key environment")
    func workerEnvironmentInvariant() {
        let runDirectory = URL(fileURLWithPath: "/work/.rafu/runs/run-a")
        let handoffDirectory = runDirectory.appending(path: "handoff")
        let environment = RafuConductorEnvironment.childEnvironment(
            runDirectory: runDirectory,
            handoffDirectory: handoffDirectory
        )

        #expect(
            Set(environment.keys)
                == ["PATH", "RAFU_HANDOFF", "RAFU_RUN_DIR"]
        )
        #expect(environment["RAFU_ENSEMBLE_TOKEN"] == nil)
    }

    @Test("Capacity rejection occurs before coordinator token mint")
    func capacityRejectionPreflightsBeforeMint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        let spec = TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: root.path, environment: ["PATH": "/usr/bin"], roleBadge: "role")
        for _ in 0..<6 {
            _ = try session.insertClassifiedTerminalSession(
                spec: spec, kind: .ensembleRole, lifecycle: {})
        }
        var mintCalls = 0
        let tokenStore = ConductorEnsembleTokenStore(randomBytes: { count in
            mintCalls += 1
            return Array(repeating: 1, count: count)
        })
        let launcher = ConductorCoordinatorLauncher(
            adapters: [AuthenticatedCoordinatorAdapter(id: .codex)], tokenStore: tokenStore,
            makeCoordinatorID: { "co-capacity" })

        await #expect(
            throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 6, requested: 1)
        ) {
            try await launcher.start(
                provider: .codex, model: nil, goal: "no capacity",
                grant: ConductorEnsembleGrant(allowedProviders: [.codex]), in: session)
        }
        #expect(mintCalls == 0)
        #expect(session.terminal.sessions.count == 6)
        #expect(session.conductorCoordinatorSessions.isEmpty)
    }

    @Test("Coordinator insertion failure revokes its minted token and releases capacity")
    func insertionFailureRollsBackMintedToken() async throws {
        enum InjectedFailure: Error { case construction }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        session.terminal.terminalGroupControllerFactory = { _, _ in
            throw InjectedFailure.construction
        }
        var mintedToken: String?
        let tokenStore = ConductorEnsembleTokenStore(randomBytes: { count in
            let bytes = Array(repeating: UInt8(9), count: count)
            mintedToken = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return bytes
        })
        let launcher = ConductorCoordinatorLauncher(
            adapters: [AuthenticatedCoordinatorAdapter(id: .codex)], tokenStore: tokenStore,
            makeCoordinatorID: { "co-rollback" })

        await #expect(throws: InjectedFailure.self) {
            try await launcher.start(
                provider: .codex, model: nil, goal: "rollback",
                grant: ConductorEnsembleGrant(allowedProviders: [.codex]), in: session)
        }
        #expect(tokenStore.validate(mintedToken) == nil)
        #expect(session.terminal.sessions.isEmpty)
        #expect(session.terminal.terminalGroups.isEmpty)
        #expect(session.conductorCoordinatorSessions.isEmpty)
        let reservation = try session.reserveTerminalLiveSessionCapacity(6)
        try session.cancelTerminalLiveSessionCapacity(reservation)
    }
}

nonisolated private struct AuthenticatedCoordinatorAdapter: ConductorCLIAdapter {
    let id: ConductorCLIID
    let defaultEnabled = true
    let supportsModelDiscovery = false

    func probe() async -> AdapterProbe {
        AdapterProbe(
            installed: true,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            version: "test-1"
        )
    }

    func authStatus() async -> AdapterAuthStatus {
        .authenticated
    }

    func curatedModels() -> [ConductorModelChoice] {
        []
    }

    func discoverModels() async -> [ConductorModelChoice]? {
        nil
    }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        AdapterInvocation(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [prompt],
            environment: RafuConductorEnvironment.childEnvironment(
                runDirectory: runDirectory,
                handoffDirectory: handoffDirectory
            )
        )
    }
}
