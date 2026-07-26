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
    var curatedChoices: [ConductorModelChoice] = []

    let defaultEnabled = true
    let supportsModelDiscovery = false

    func probe() async -> AdapterProbe { probeResult }
    func authStatus() async -> AdapterAuthStatus { authResult }
    func curatedModels() -> [ConductorModelChoice] { curatedChoices }
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

private func readyFixture(
    _ id: ConductorCLIID,
    path: String = "/bin/echo",
    curated: [ConductorModelChoice] = []
) -> EnsembleFixtureAdapter {
    EnsembleFixtureAdapter(
        id: id,
        probeResult: AdapterProbe(
            installed: true, executableURL: URL(fileURLWithPath: path), version: "test-1"),
        authResult: .authenticated,
        curatedChoices: curated)
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
        .appending(path: "rafu-ensemble-canvas-\(UUID().uuidString)", directoryHint: .isDirectory)
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
@Suite("New Ensemble canvas", .serialized)
struct EnsembleStartCanvasTests {

    @Test("Only a ready CLI is enabled; the others carry a stated reason")
    func gatingMatrix() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
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
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
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

    /// The coordinator card names a model, and names it honestly: a field
    /// value that was PREFILLED from Settings is reported as the Settings
    /// default, not as a pick the user made.
    @Test("The coordinator card resolves a real model name, with its source")
    func coordinatorCardNamesItsModel() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ConductorDefaultModelStore(suiteName: suite)
        store.setDefaultModel("gpt-5.6", for: .codex)

        let model = EnsembleStartModel(
            adapters: [
                readyFixture(
                    .codex,
                    curated: [
                        ConductorModelChoice(
                            id: "gpt-5.6", displayName: "GPT-5.6", source: .curated)
                    ])
            ],
            defaultModelStore: store)
        await model.probeCLIs(workspaceRoot: root)

        let inherited = try #require(model.coordinatorModelResolution)
        #expect(inherited.modelID == "gpt-5.6")
        #expect(inherited.label == "GPT-5.6", "the id must display as its catalog name")
        #expect(inherited.source == .settingsDefault)

        // A model Rafu has never heard of is legitimate and must survive.
        model.model = "some-private-model"
        let custom = try #require(model.coordinatorModelResolution)
        #expect(custom.modelID == "some-private-model")
        #expect(custom.source == .explicit)
        #expect(custom.label == "some-private-model")
    }

    /// With nothing set anywhere, the card must say the CLI decides rather
    /// than naming the first curated model — the resolver's safety property,
    /// read through this surface.
    @Test("With no default anywhere, the coordinator card guesses no model")
    func coordinatorCardNamesNoModelWhenUnset() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let model = EnsembleStartModel(
            adapters: [
                readyFixture(
                    .codex,
                    curated: [
                        ConductorModelChoice(
                            id: "gpt-5.6", displayName: "GPT-5.6", source: .curated)
                    ])
            ],
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite),
            discoveredModels: ConductorDiscoveredModelCache(
                store: ConductorDiscoveredModelStore(suiteName: suite)))
        await model.probeCLIs(workspaceRoot: root)

        let resolution = try #require(model.coordinatorModelResolution)
        #expect(!resolution.namesAModel)
        #expect(resolution.modelID == nil)
        #expect(resolution.label != "GPT-5.6")
        // The picker still OFFERS it; resolution simply does not claim it.
        #expect(model.availableModels(for: .codex).map(\.id) == ["gpt-5.6"])
    }

    /// The bug this closes: a user refreshed Cursor's models in Settings, saw
    /// a long list there, then opened this canvas and saw the three curated
    /// entries — same CLI, same machine, same minute, two different answers.
    @Test("The canvas offers the models Settings discovered, without discovering itself")
    func canvasSeesDiscoveredModelsWithoutSpawningAnything() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let cache = ConductorDiscoveredModelCache(
            store: ConductorDiscoveredModelStore(suiteName: suite))
        let curated = ConductorModelChoice(
            id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", source: .curated)
        let adapter = readyFixture(.codex, curated: [curated])

        let model = EnsembleStartModel(
            adapters: [adapter],
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite),
            discoveredModels: cache)
        await model.probeCLIs(workspaceRoot: root)

        // Before any discovery: curated only. Opening the canvas must never
        // have run a CLI to learn more.
        #expect(model.availableModels(for: .codex).map(\.id) == ["gpt-5.6-sol"])

        // Someone else — Settings → Agents → Refresh models — discovers.
        cache.setModels(
            [
                ConductorModelChoice(
                    id: "gpt-5.4", displayName: "GPT-5.4", source: .discovered),
                ConductorModelChoice(
                    id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", source: .discovered),
            ],
            for: .codex)

        // The ALREADY-OPEN canvas now offers the same catalog, curated first
        // and deduplicated by id — the exact `ConductorModelCatalog.merge`
        // contract Settings uses.
        #expect(model.availableModels(for: .codex).map(\.id) == ["gpt-5.6-sol", "gpt-5.4"])
        #expect(model.availableModels(for: .codex).first?.source == .curated)

        // A CLI nobody discovered for is unaffected.
        #expect(model.availableModels(for: .cursor).isEmpty)
    }

    /// A discovered list is catalog metadata, not a credential, and surviving
    /// relaunch is the whole point — otherwise both surfaces silently collapse
    /// back to curated on every launch and the bug returns.
    @Test("A discovered list survives a new cache over the same store")
    func discoveredModelsPersist() {
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ConductorDiscoveredModelStore(suiteName: suite)

        #expect(ConductorDiscoveredModelCache(store: store).models(for: .cursor).isEmpty)

        ConductorDiscoveredModelCache(store: store).setModels(
            [ConductorModelChoice(id: "auto", displayName: "Auto", source: .discovered)],
            for: .cursor)

        let reloaded = ConductorDiscoveredModelCache(store: store)
        #expect(reloaded.models(for: .cursor).map(\.id) == ["auto"])
        #expect(reloaded.models(for: .cursor).first?.source == .discovered)
        // Keyed per CLI: one vendor's catalog can never be read for another.
        #expect(reloaded.models(for: .openCode).isEmpty)
    }

    /// The per-CLI equivalent of the coordinator's cross-vendor reset: a
    /// model chosen for one CLI is stored under that CLI and is therefore
    /// unreadable for another, and de-allowing a CLI drops its pick rather
    /// than resurrecting it later.
    @Test("Each allowed CLI carries its own model; one vendor's never leaks to another")
    func perCLIModelsAreIsolated() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "EnsembleStartCanvasTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ConductorDefaultModelStore(suiteName: suite)
        store.setDefaultModel("claude-settings-default", for: .claudeCode)

        let model = EnsembleStartModel(
            adapters: [readyFixture(.claudeCode), readyFixture(.codex)],
            defaultModelStore: store)
        await model.probeCLIs(workspaceRoot: root)
        #expect(model.allowedProviders == [.claudeCode, .codex])

        // Allowing seeds no pick: the Settings default is inherited and
        // reported as such, never restated as an Ensemble-level choice.
        #expect(model.ensembleModel(for: .claudeCode) == nil)
        #expect(model.modelResolution(for: .claudeCode).source == .settingsDefault)
        #expect(model.modelResolution(for: .codex).source == .cliDecides)

        model.setEnsembleModel("codex-only-model", for: .codex)
        #expect(model.modelResolution(for: .codex).modelID == "codex-only-model")
        #expect(model.modelResolution(for: .codex).source == .ensembleDefault)
        #expect(
            model.modelResolution(for: .claudeCode).modelID == "claude-settings-default",
            "Codex's pick must be unreadable for Claude Code")

        // Only allowed CLIs contribute, and only when they carry a pick.
        #expect(model.providerModelDefaults() == [.codex: "codex-only-model"])

        // De-allowing drops the pick, so re-allowing re-inherits from
        // Settings instead of resurrecting a stale choice.
        model.setAllowed(false, for: .codex)
        #expect(model.providerModelDefaults().isEmpty)
        model.setAllowed(true, for: .codex)
        #expect(model.ensembleModel(for: .codex) == nil)
    }

    /// Whitespace must not survive into a `--model` flag, and a blank pick
    /// must fall through rather than become a model named "".
    @Test("A blank per-CLI model falls through instead of becoming an empty model")
    func blankPerCLIModelFallsThrough() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EnsembleStartModel(adapters: [readyFixture(.codex)])
        await model.probeCLIs(workspaceRoot: root)

        model.setEnsembleModel("   ", for: .codex)
        #expect(model.ensembleModel(for: .codex) == nil)
        #expect(model.providerModelDefaults().isEmpty)

        model.setEnsembleModel("  spaced-model  ", for: .codex)
        #expect(model.providerModelDefaults() == [.codex: "spaced-model"])
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
        session.showEnsembleStart()

        let model = EnsembleStartModel(
            adapters: [readyFixture(.codex)],
            clock: { now },
            launch: { provider, launchModel, goal, grant, name, providerModels, session in
                try await ConductorCoordinatorLauncher(
                    adapters: [readyFixture(.codex)],
                    tokenStore: tokenStore,
                    eventCenter: eventCenter,
                    clock: { now },
                    makeCoordinatorID: { "co-test0001" }
                ).start(
                    provider: provider, model: launchModel, goal: goal, grant: grant, label: name,
                    providerModelDefaults: providerModels,
                    in: session)
            })
        await model.probeCLIs(workspaceRoot: root)
        model.goal = "Coordinate the release"
        model.setEnsembleModel("codex-child-model", for: .codex)

        let started = await model.start(in: session)
        #expect(started)
        #expect(session.conductorCoordinatorSessions.map(\.id) == ["co-test0001"])
        // Per-provider model defaults ride ALONGSIDE the grant on the
        // coordinator record — the grant itself stays a permission contract.
        #expect(
            session.conductorCoordinatorSessions.first?.providerModelDefaults
                == [.codex: "codex-child-model"])
        // The name flows through to the coordinator session, defaulted from
        // the goal's first line because the name field was left blank.
        #expect(session.conductorCoordinatorSessions.first?.label == "Coordinate the release")
        #expect(
            session.conductorCoordinatorSessions.first?.displayTitle == "Coordinate the release")
        #expect(model.postLaunchGoalToPaste == "Coordinate the release")
        // The canvas stays open on the copyable-goal confirmation until Done.
        #expect(session.ensembleStartCanvasVisible)
        #expect(!session.conductorGraphVisible)

        model.finishAndShowGraph(in: session)
        #expect(!session.ensembleStartCanvasVisible)
        #expect(session.conductorGraphVisible)
        #expect(model.postLaunchGoalToPaste == nil)
    }

    @Test("A launch failure keeps the canvas open with an inline error and spawns nothing")
    func launchFailureKeepsCanvas() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        session.showEnsembleStart()

        let model = EnsembleStartModel(
            adapters: [readyFixture(.codex)],
            launch: { _, _, _, _, _, _, _ in
                throw ConductorCoordinatorLaunchError.notAuthenticated(
                    .codex, "run `codex login` in a terminal")
            })
        await model.probeCLIs(workspaceRoot: root)
        model.goal = "Coordinate the release"

        let started = await model.start(in: session)
        #expect(!started)
        #expect(session.ensembleStartCanvasVisible)
        #expect(!session.conductorGraphVisible)
        #expect(model.errorMessage != nil)
        #expect(session.conductorCoordinatorSessions.isEmpty)
        #expect(model.postLaunchGoalToPaste == nil)
    }

    @Test("Door 3's cap guard is exactly session.canStartConductorWorkflowRun")
    func door3GuardMirrorsCap() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession(conductorAdapters: [FakeConductorAdapter(id: .claudeCode)])
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

    @Test("The canvas seams guard on descriptor == nil")
    func canvasSeamsGuardOnDescriptor() throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        #expect(session.descriptor == nil)

        session.showEnsembleStart()
        session.showEnsembleNewRun()
        #expect(!session.ensembleStartCanvasVisible)
        #expect(!session.ensembleNewRunCanvasVisible)

        session.openLocalWorkspace(at: root)
        session.showEnsembleStart()
        #expect(session.ensembleStartCanvasVisible)
        session.showEnsembleNewRun()
        #expect(session.ensembleNewRunCanvasVisible)
    }

    @Test("Creation canvases replace peers and close to the last document")
    func creationCanvasesReplacePeersAndCloseToDocument() throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        session.newUntitledDocument()
        let document = try #require(session.openDocuments.last)

        session.showConductorGraph()
        session.showEnsembleStart()

        #expect(session.ensembleStartCanvasVisible)
        #expect(!session.ensembleNewRunCanvasVisible)
        #expect(!session.conductorGraphVisible)
        #expect(session.conductorRunCanvasID == nil)
        #expect(session.selectedDocumentID == nil)

        session.closeEnsembleStart()
        #expect(!session.ensembleStartCanvasVisible)
        #expect(session.selectedDocumentID == document.id)

        session.showConductorRunDetail("run-1")
        session.showEnsembleNewRun()

        #expect(session.ensembleNewRunCanvasVisible)
        #expect(!session.ensembleStartCanvasVisible)
        #expect(!session.conductorGraphVisible)
        #expect(session.conductorRunCanvasID == nil)
        #expect(session.selectedDocumentID == nil)

        session.closeEnsembleNewRun()
        #expect(!session.ensembleNewRunCanvasVisible)
        #expect(session.selectedDocumentID == document.id)

        session.showEnsembleStart()
        session.showEnsembleNewRun()
        #expect(!session.ensembleStartCanvasVisible)
        #expect(session.ensembleNewRunCanvasVisible)

        session.showConductorGraph()
        #expect(!session.ensembleStartCanvasVisible)
        #expect(!session.ensembleNewRunCanvasVisible)
        #expect(session.conductorGraphVisible)
    }

    @Test("Creation canvas visibility belongs to one workspace window")
    func secondWindowIndependence() throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = WorkspaceSession()
        let second = WorkspaceSession()
        first.openLocalWorkspace(at: root)
        second.openLocalWorkspace(at: root)

        first.showEnsembleStart()
        #expect(first.ensembleStartCanvasVisible)
        #expect(!second.ensembleStartCanvasVisible)
        #expect(!second.ensembleNewRunCanvasVisible)

        second.showEnsembleNewRun()
        #expect(second.ensembleNewRunCanvasVisible)
        first.closeEnsembleStart()
        #expect(!first.ensembleStartCanvasVisible)
        #expect(second.ensembleNewRunCanvasVisible)
    }

    @Test("Revealing a terminal replaces either creation canvas")
    func terminalReplacesCreationCanvases() throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)
        session.newTerminalTab()
        let terminal = try #require(session.terminal.sessions.first)

        session.showEnsembleStart()
        session.revealTerminalSession(terminal.id)
        #expect(!session.ensembleStartCanvasVisible)

        session.showEnsembleNewRun()
        session.revealTerminalSession(terminal.id)
        #expect(!session.ensembleNewRunCanvasVisible)
        #expect(session.terminal.selectedID == terminal.id)
    }

    @Test("Every entry point uses the canvas seams and no Ensemble sheet is presented")
    func entryPointsUseCanvasSeams() throws {
        let root = try repositoryRoot()
        let commands = try source("Sources/RafuApp/App/RafuAppCommands.swift", root: root)
        let palette = try source("Sources/RafuApp/Views/CommandPaletteView.swift", root: root)
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root)
        let presentations = try source(
            "Sources/RafuApp/Views/WorkspaceWindowView.swift", root: root)

        #expect(commands.contains("workspaceSession?.showEnsembleStart()"))
        #expect(commands.contains(".keyboardShortcut(\"e\", modifiers: [.command, .shift])"))
        #expect(palette.contains("session.showEnsembleStart()"))
        #expect(runsPanel.contains("session.showEnsembleStart()"))

        #expect(commands.contains("workspaceSession?.showEnsembleNewRun()"))
        #expect(palette.contains("session.showEnsembleNewRun()"))
        #expect(runsPanel.contains("session.showEnsembleNewRun()"))

        #expect(!presentations.contains("EnsembleStart"))
        #expect(!runsPanel.contains(".sheet("))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "Sources/RafuApp/Views/EnsembleStartSheet.swift").path)
        )
    }

    /// UX2-02 moved the New Ensemble canvas off the centered 600 pt measure
    /// onto a full-width two-column layout, so its half of this contract now
    /// asserts the ABSENCE of the clamp plus the presence of the split. The
    /// New Run canvas is untouched and keeps the original assertion.
    @Test("Creation canvases expose close and Esc; New Ensemble is full width")
    func canvasCloseAndWidthContract() throws {
        let root = try repositoryRoot()
        let startCanvas = try source(
            "Sources/RafuApp/Views/EnsembleStartCanvas.swift", root: root)
        let runCanvas = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root)

        #expect(startCanvas.contains(".onExitCommand(perform: session.closeEnsembleStart)"))
        #expect(!startCanvas.contains(".frame(maxWidth: 600"))
        #expect(startCanvas.contains("controlsWidth(inTotal:"))
        #expect(startCanvas.contains("EnsembleGoalPane(text: $model.goal)"))
        #expect(startCanvas.contains(".accessibilityLabel(\"Close New Ensemble\")"))
        #expect(startCanvas.contains(".help(\"Close New Ensemble\")"))

        #expect(runCanvas.contains(".onExitCommand(perform: session.closeEnsembleNewRun)"))
        #expect(runCanvas.contains(".frame(maxWidth: 600"))
        #expect(runCanvas.contains(".accessibilityLabel(\"Close New Ensemble Run\")"))
        #expect(runCanvas.contains(".help(\"Close New Ensemble Run\")"))
    }

    @Test("The guided door splits 3/12 to 9/12, clamped so neither column collapses")
    func guidedColumnSplit() throws {
        // The fraction is the layout.
        #expect(EnsembleStartCanvas.controlsWidth(inTotal: 1200) == 300)
        #expect(EnsembleStartCanvas.controlsWidth(inTotal: 1600) == 400)
        // Floored: a narrow window still shows a usable icon grid.
        #expect(EnsembleStartCanvas.controlsWidth(inTotal: 800) == 280)
        // Capped: the rail never eats a very wide display.
        #expect(EnsembleStartCanvas.controlsWidth(inTotal: 4000) == 420)
    }

    @Test("The goal is handed to the launcher as plain text, byte for byte")
    func goalStaysPlainTextThroughTheMarkdownPane() async throws {
        let root = try makeEnsembleTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession()
        session.openLocalWorkspace(at: root)

        let markdownGoal = "# Ship 1.2\n\n- [ ] cut the branch\n- [ ] `swift test`\n"
        var observedGoal: String?
        let model = EnsembleStartModel(
            adapters: [readyFixture(.codex)],
            launch: { provider, _, goal, _, _, _, _ in
                observedGoal = goal
                throw ConductorCoordinatorLaunchError.providerUnavailable(provider)
            })
        await model.probeCLIs(workspaceRoot: root)
        model.goal = markdownGoal

        _ = await model.start(in: session)

        // Only outer whitespace is trimmed — every Markdown character the
        // user typed survives, because this string is pasted into a CLI
        // prompt verbatim.
        #expect(observedGoal == markdownGoal.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(observedGoal?.contains("# Ship 1.2") == true)
        #expect(observedGoal?.contains("- [ ] `swift test`") == true)
        // The pane never rewrites the model's own text either.
        #expect(model.goal == markdownGoal)
    }

    @Test("The Ensemble name derives from the first meaningful line, or a timestamp")
    func ensembleNameDerivation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = EnsembleStartModel(adapters: [], clock: { now })

        // Markdown structure is stripped, not shown to the user as a name.
        #expect(EnsembleStartModel.deriveName(from: "# Ship the release") == "Ship the release")
        #expect(EnsembleStartModel.deriveName(from: "- migrate the store") == "migrate the store")
        #expect(
            EnsembleStartModel.deriveName(from: "1. audit the adapters") == "audit the adapters")
        #expect(EnsembleStartModel.deriveName(from: "**bold** plan") == "bold plan")
        // Leading blank / structure-only lines are skipped.
        #expect(EnsembleStartModel.deriveName(from: "\n\n   \nreal goal") == "real goal")
        // Nothing to derive from.
        #expect(EnsembleStartModel.deriveName(from: "   \n\n") == nil)
        // Long first lines are bounded rather than dropped.
        let long = String(repeating: "word ", count: 40)
        let bounded = try #require(EnsembleStartModel.deriveName(from: long))
        #expect(bounded.count <= 61)
        #expect(bounded.hasSuffix("…"))

        // The timestamp fallback is used only when there is no first line,
        // and is stable across calls (formatted once per canvas).
        let fallback = model.suggestedName(for: "")
        #expect(fallback.hasPrefix("Ensemble "))
        #expect(model.suggestedName(for: "") == fallback)

        // A typed name always wins over the suggestion.
        #expect(model.effectiveName(for: "# Ship the release") == "Ship the release")
        model.name = "  Release train  "
        #expect(model.effectiveName(for: "# Ship the release") == "Release train")
        model.name = "   "
        #expect(model.effectiveName(for: "# Ship the release") == "Ship the release")
    }

    @Test("Both CLI pickers are icon grids sourced from ConductorCLIIcons")
    func cliPickersAreIconGrids() throws {
        let root = try repositoryRoot()
        let startCanvas = try source(
            "Sources/RafuApp/Views/EnsembleStartCanvas.swift", root: root)
        let grid = try source("Sources/RafuApp/Views/EnsembleCLIIconGrid.swift", root: root)

        // Two grids: coordinator (single-select) and allowed CLIs
        // (multi-select), not a row list and not a column of switches.
        #expect(startCanvas.components(separatedBy: "EnsembleCLIIconGrid(options:").count - 1 == 2)
        #expect(!startCanvas.contains("Toggle(option.displayName"))
        #expect(!startCanvas.contains("EnsembleCLIPickerRow"))
        #expect(grid.contains("ConductorCLIIcons.icon(for: option.id)"))
        #expect(grid.contains("LazyVGrid"))
        // Selection and unavailability are never color-only.
        #expect(grid.contains("checkmark.circle.fill"))
        #expect(grid.contains("exclamationmark.circle.fill"))
        #expect(grid.contains(".accessibilityLabel(accessibilityText)"))
        #expect(grid.contains(".help(helpText)"))
    }

    @Test("The goal pane is one live-Markdown surface, not an editor/preview split")
    func goalPaneIsSinglePane() throws {
        let root = try repositoryRoot()
        let pane = try source("Sources/RafuApp/Views/EnsembleGoalPane.swift", root: root)

        #expect(pane.contains("TextEditor(text: $text)"))
        #expect(pane.contains("Markdown(text)"))
        #expect(pane.contains(".rafuMarkdownStyling()"))
        // One of the two, chosen by focus — never both at once.
        #expect(pane.contains("if showsEditor {"))
        #expect(!pane.contains("HSplitView"))
        #expect(!pane.contains("NavigationSplitView"))
        // Keyboard and VoiceOver paths back into edit mode.
        #expect(pane.contains(".accessibilityAction(named: \"Edit goal\", beginEditing)"))
        // The header action is one button that flips label with the mode, so
        // both directions must be named for VoiceOver.
        #expect(pane.contains("\"Edit goal as Markdown\""))
        #expect(pane.contains("\"Preview rendered goal\""))
    }

    @Test("Runs header icons have labels, tooltips, and menu/palette equivalents")
    func runsHeaderIconContract() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root)
        let commands = try source("Sources/RafuApp/App/RafuAppCommands.swift", root: root)
        let palette = try source("Sources/RafuApp/Views/CommandPaletteView.swift", root: root)

        #expect(
            runsPanel.components(separatedBy: ".buttonStyle(RafuIconButtonStyle(size: 24))")
                .count - 1 >= 3)
        #expect(runsPanel.contains(".help(\"Show Ensemble Graph\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"Show Ensemble Graph\")"))
        #expect(runsPanel.contains(".help(\"New Ensemble…\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"New Ensemble\")"))
        #expect(runsPanel.contains(".help(\"New Run…\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"New Ensemble Run\")"))

        #expect(commands.contains("workspaceSession?.showConductorGraph()"))
        #expect(palette.contains("session.showConductorGraph()"))
        #expect(commands.contains("workspaceSession?.showEnsembleStart()"))
        #expect(palette.contains("session.showEnsembleStart()"))
        #expect(commands.contains("workspaceSession?.showEnsembleNewRun()"))
        #expect(palette.contains("session.showEnsembleNewRun()"))
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw EnsembleCanvasTestError.repositoryRootNotFound
    }

    private func source(_ path: String, root: URL) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private enum EnsembleCanvasTestError: Error {
        case repositoryRootNotFound
    }
}
