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
            launch: { _, _, _, _, _ in
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

    @Test("Creation canvases expose close and Esc at a readable width")
    func canvasCloseAndWidthContract() throws {
        let root = try repositoryRoot()
        let startCanvas = try source(
            "Sources/RafuApp/Views/EnsembleStartCanvas.swift", root: root)
        let runCanvas = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root)

        #expect(startCanvas.contains(".onExitCommand(perform: session.closeEnsembleStart)"))
        #expect(startCanvas.contains(".frame(maxWidth: 600"))
        #expect(startCanvas.contains(".accessibilityLabel(\"Close New Ensemble\")"))
        #expect(startCanvas.contains(".help(\"Close New Ensemble\")"))

        #expect(runCanvas.contains(".onExitCommand(perform: session.closeEnsembleNewRun)"))
        #expect(runCanvas.contains(".frame(maxWidth: 600"))
        #expect(runCanvas.contains(".accessibilityLabel(\"Close New Ensemble Run\")"))
        #expect(runCanvas.contains(".help(\"Close New Ensemble Run\")"))
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
