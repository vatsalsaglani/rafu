import Foundation
import Testing

@testable import RafuApp

/// Fixture adapter with a fully scripted probe/auth result, local to this
/// file (mirrors `AgentTerminalTests.swift`'s own `AgentTerminalFixtureAdapter`
/// — each test file keeps its own rather than widening another phase's
/// private fixture).
nonisolated private struct EnsembleFixtureAdapter: ConductorCLIAdapter {
    let id: ConductorCLIID
    let probeResult: AdapterProbe
    let authResult: AdapterAuthStatus

    let defaultEnabled = true
    let supportsModelDiscovery = false

    func probe() async -> AdapterProbe { probeResult }
    func authStatus() async -> AdapterAuthStatus { authResult }
    func curatedModels() -> [ConductorModelChoice] { [] }
    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        AdapterInvocation(
            executableURL: probeResult.executableURL ?? URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            environment: [:])
    }
}

private func readyFixture(_ id: ConductorCLIID, path: String = "/bin/echo")
    -> EnsembleFixtureAdapter
{
    EnsembleFixtureAdapter(
        id: id,
        probeResult: AdapterProbe(
            installed: true, executableURL: URL(fileURLWithPath: path), version: "test-1"),
        authResult: .authenticated)
}

private func notInstalledFixture(_ id: ConductorCLIID) -> EnsembleFixtureAdapter {
    EnsembleFixtureAdapter(id: id, probeResult: .notInstalled, authResult: .unknown())
}

private func notAuthenticatedFixture(
    _ id: ConductorCLIID, hint: String = "not logged in — run `codex login` in a terminal"
) -> EnsembleFixtureAdapter {
    EnsembleFixtureAdapter(
        id: id,
        probeResult: AdapterProbe(
            installed: true, executableURL: URL(fileURLWithPath: "/usr/local/bin/\(id.rawValue)"),
            version: "test"),
        authResult: .notAuthenticated(hint: hint))
}

private func makeEnsembleTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-ensemble-sheet-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A single-step, all-readOnly workflow request — enough to occupy a
/// concurrent-run slot without a mutating worktree. Local to this file
/// (mirrors `ConcurrentRunOwnershipTests.swift`'s own `ownershipRequest`).
private func ensembleCapRequest(runID: String) -> ConductorWorkflowRunRequest {
    ConductorWorkflowRunRequest(
        workflow: workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
        roles: [workflowRole(name: "worker", handoffArtifact: "result.md", autonomy: .readOnly)],
        taskPrompt: "Perform the task.",
        runID: runID)
}

@MainActor
@Suite("New Ensemble sheet", .serialized)
struct EnsembleStartSheetTests {

    @Test("Only a ready CLI is enabled; the others carry a stated reason")
    func gatingMatrix() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartSheetTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let model = EnsembleStartModel(
            adapters: [
                readyFixture(.claudeCode),
                notInstalledFixture(.codex),
                notAuthenticatedFixture(.openCode, hint: "run `opencode login` in a terminal"),
            ],
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        await model.probeCLIs(workspaceRoot: root)

        #expect(model.isEnabled(.claudeCode))
        #expect(model.disableReason(.claudeCode) == nil)

        #expect(!model.isEnabled(.codex))
        #expect(model.disableReason(.codex)?.contains("Not installed") == true)

        #expect(!model.isEnabled(.openCode))
        #expect(model.disableReason(.openCode) == "run `opencode login` in a terminal")
    }

    @Test("The grant defaults its allowed set to the ready CLIs")
    func grantDefaultsToReadyCLIs() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EnsembleStartModel(
            adapters: [readyFixture(.claudeCode), notInstalledFixture(.codex)])

        await model.probeCLIs(workspaceRoot: root)

        #expect(Set(model.makeGrant(windowCap: 3).allowedProviders) == [.claudeCode])
    }

    @Test("The wall-clock deadline choice maps to the injected clock")
    func grantDeadlineMapping() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = EnsembleStartModel(adapters: [], clock: { now })

        model.deadlineChoice = .none
        #expect(model.makeGrant(windowCap: 3).deadline == nil)

        model.deadlineChoice = .oneHour
        #expect(model.makeGrant(windowCap: 3).deadline == now.addingTimeInterval(3600))

        model.deadlineChoice = .fourHours
        #expect(model.makeGrant(windowCap: 3).deadline == now.addingTimeInterval(4 * 3600))

        model.deadlineChoice = .eightHours
        #expect(model.makeGrant(windowCap: 3).deadline == now.addingTimeInterval(8 * 3600))
    }

    @Test("Concurrency clamps to the window cap; the total cap is untouched")
    func grantConcurrentCapClamp() throws {
        let model = EnsembleStartModel(adapters: [])
        model.maxConcurrent = 3
        model.maxTotal = 12

        let grant = model.makeGrant(windowCap: 2)
        #expect(grant.maxConcurrentChildRuns == 2)
        #expect(grant.maxTotalChildRuns == 12)
    }

    @Test("Door 1's primary action requires a non-empty, non-whitespace goal")
    func guidedPrimaryRequiresGoal() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EnsembleStartModel(adapters: [readyFixture(.claudeCode)])
        await model.probeCLIs(workspaceRoot: root)

        model.goal = ""
        #expect(!model.canStartGuided)

        model.goal = "   \n  "
        #expect(!model.canStartGuided)

        model.goal = "Ship the release"
        #expect(model.canStartGuided)
    }

    @Test("Door 1's primary action requires a non-empty allowed-CLI set")
    func guidedPrimaryRequiresAllowedProvider() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EnsembleStartModel(adapters: [readyFixture(.claudeCode)])
        await model.probeCLIs(workspaceRoot: root)
        model.goal = "Ship the release"

        #expect(model.canStartGuided)

        model.allowedProviders.removeAll()
        #expect(!model.canStartGuided)

        model.allowedProviders.insert(.claudeCode)
        #expect(model.canStartGuided)
    }

    @Test("Switching the selected provider resets the model field to ITS default")
    func selectProviderResetsModelAcrossVendors() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartSheetTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaultModelStore = ConductorDefaultModelStore(suiteName: suite)
        defaultModelStore.setDefaultModel("claude-model", for: .claudeCode)
        defaultModelStore.setDefaultModel("codex-model", for: .codex)

        let model = EnsembleStartModel(
            adapters: [readyFixture(.claudeCode), readyFixture(.codex)],
            defaultModelStore: defaultModelStore)
        await model.probeCLIs(workspaceRoot: root)

        // Auto-selected to the first ready provider with its own default.
        #expect(model.selectedProvider == .claudeCode)
        #expect(model.model == "claude-model")

        // Simulate the user hand-editing the model field before switching.
        model.model = "hand-typed-claude-override"

        model.selectProvider(.codex)
        #expect(model.selectedProvider == .codex)
        #expect(model.model == "codex-model")
        #expect(model.model != "hand-typed-claude-override")

        model.selectProvider(.claudeCode)
        #expect(model.model == "claude-model")
    }

    @Test("A successful launch registers the coordinator; Done routes to the graph")
    func launchSuccessRegistersAndRoutes() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenStore = ConductorEnsembleTokenStore(
            randomBytes: { count in Array((0..<count).map { UInt8(($0 + 7) % 251) }) },
            clock: { now })
        let eventCenter = ConductorEnsembleEventCenter(
            sleep: { _ in throw CancellationError() })

        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        session.ensembleStartSheetPresented = true

        let model = EnsembleStartModel(
            adapters: [readyFixture(.codex)],
            clock: { now },
            launch: { provider, launchModel, goal, grant, session in
                try await ConductorCoordinatorLauncher(
                    adapters: [readyFixture(.codex)],
                    tokenStore: tokenStore,
                    eventCenter: eventCenter,
                    clock: { now },
                    makeCoordinatorID: { "co-test0001" }
                ).start(
                    provider: provider, model: launchModel, goal: goal, grant: grant, in: session)
            })
        await model.probeCLIs(workspaceRoot: root)
        model.goal = "Coordinate the release"

        let started = await model.start(in: session)
        #expect(started)
        #expect(session.conductorCoordinatorSessions.map(\.id) == ["co-test0001"])
        #expect(model.postLaunchGoalToPaste == "Coordinate the release")
        // The sheet stays open on the copyable-goal confirmation until Done.
        #expect(session.ensembleStartSheetPresented)
        #expect(!session.conductorGraphVisible)

        model.finishAndShowGraph(in: session)
        #expect(!session.ensembleStartSheetPresented)
        #expect(session.conductorGraphVisible)
        #expect(model.postLaunchGoalToPaste == nil)
    }

    @Test("A launch failure keeps the sheet open with an inline error and spawns nothing")
    func launchFailureKeepsSheet() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        session.ensembleStartSheetPresented = true

        let model = EnsembleStartModel(
            adapters: [readyFixture(.codex)],
            launch: { _, _, _, _, _ in
                throw ConductorCoordinatorLaunchError.notAuthenticated(
                    .codex, "run `codex login` in a terminal")
            })
        await model.probeCLIs(workspaceRoot: root)
        model.goal = "Coordinate the release"

        let started = await model.start(in: session)
        #expect(!started)
        #expect(session.ensembleStartSheetPresented)
        #expect(!session.conductorGraphVisible)
        #expect(model.errorMessage != nil)
        #expect(session.conductorCoordinatorSessions.isEmpty)
        #expect(model.postLaunchGoalToPaste == nil)
    }

    @Test("Door 3's cap guard is exactly session.canStartConductorWorkflowRun")
    func door3GuardMirrorsCap() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        session.conductorRunController.attach(workspaceRoot: root)
        session.conductorConcurrentRuns.attach(workspaceRoot: root)

        #expect(session.canStartConductorWorkflowRun)

        for index in 1...session.conductorConcurrentRuns.activeLimit {
            _ = try await session.conductorConcurrentRuns.start(
                ensembleCapRequest(runID: "ensemble-cap-\(index)"),
                launcher: WorkflowFakeLauncher())
        }
        #expect(!session.canStartConductorWorkflowRun)

        for controller in session.conductorConcurrentRuns.controllers {
            controller.abort()
        }
    }

    @Test("Door 2 reuses instantiation: a clean dir writes the file; a conflict pends confirmation")
    func door2ReusesInstantiation() async throws {
        // Clean destination: instantiation writes the workflow file directly.
        let cleanRoot = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: cleanRoot) }
        let cleanModel = ConductorWorkflowLibraryModel()
        await cleanModel.load(workspaceRoot: cleanRoot)
        await cleanModel.instantiate(templateID: "review-only", scope: .repository)
        #expect(cleanModel.pendingReplacement == nil)
        #expect(cleanModel.errorMessage == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: cleanRoot.appending(path: ".rafu/workflows/review-only.md").path))

        // Pre-seeded conflict: instantiation pends confirmation and writes
        // nothing until `replaceConfirmed: true`.
        let conflictRoot = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: conflictRoot) }
        let agentsDirectory = conflictRoot.appending(
            path: ".rafu/agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: agentsDirectory, withIntermediateDirectories: true)
        let reviewerURL = agentsDirectory.appending(path: "reviewer.md")
        try Data("custom content".utf8).write(to: reviewerURL)

        let conflictModel = ConductorWorkflowLibraryModel()
        await conflictModel.load(workspaceRoot: conflictRoot)
        await conflictModel.instantiate(templateID: "review-only", scope: .repository)
        #expect(conflictModel.pendingReplacement?.conflicts == ["agents/reviewer.md"])
        #expect(
            !FileManager.default.fileExists(
                atPath: conflictRoot.appending(path: ".rafu/workflows/review-only.md").path))
        #expect(try String(contentsOf: reviewerURL, encoding: .utf8) == "custom content")

        await conflictModel.instantiate(
            templateID: "review-only", scope: .repository, replaceConfirmed: true)
        #expect(conflictModel.pendingReplacement == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: conflictRoot.appending(path: ".rafu/workflows/review-only.md").path))
        #expect(try String(contentsOf: reviewerURL, encoding: .utf8) != "custom content")
    }

    @Test("The command seam guards on descriptor == nil")
    func commandGuardsOnDescriptor() throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        #expect(session.descriptor == nil)

        session.presentEnsembleStartSheet()
        #expect(!session.ensembleStartSheetPresented)

        session.openLocalWorkspace(at: root)
        session.presentEnsembleStartSheet()
        #expect(session.ensembleStartSheetPresented)
    }
}
