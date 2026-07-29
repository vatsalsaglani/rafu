import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
private final class RunEvidenceFakeLauncher: ConductorRunProcessLaunching {
    let sessionID = UUID()
    private let manifestURL: URL
    private var onExit: (@MainActor @Sendable (UUID, Int32?) -> Void)?
    private(set) var foundManifestAtLaunch = false

    init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    func launch(
        specification: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        let data = try Data(contentsOf: manifestURL)
        _ = try ConductorRunStore.makeDecoder().decode(ConductorRunManifest.self, from: data)
        foundManifestAtLaunch = true
        self.onExit = onExit
        return sessionID
    }

    func terminate(sessionID: UUID) {}

    func finish(exitCode: Int32?) {
        onExit?(sessionID, exitCode)
    }
}

@MainActor
@Suite("Run evidence and Activity")
struct RunEvidenceAndActivityTests {
    @Test("The initial manifest exists before the fake process launches")
    func initialManifestExistsBeforeLaunch() async throws {
        let root = try makeRunEvidenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "initial-manifest-run"
        let store = ConductorRunStore(workspaceRoot: root)
        let launcher = RunEvidenceFakeLauncher(manifestURL: store.manifestURL(for: runID))
        let controller = makeRunEvidenceController(root: root)

        await controller.start(runEvidenceRequest(runID: runID), launcher: launcher)

        #expect(launcher.foundManifestAtLaunch)
        #expect(try await store.load(runID: runID)?.id == runID)
        controller.abort()
        await controller.waitForPendingOperation()
    }

    @Test("A first workflow attempt cannot create evidence before its manifest")
    func firstWorkflowAttemptRequiresManifest() async throws {
        let root = try makeRunEvidenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConductorRunStore(workspaceRoot: root)
        _ = try await store.directory.seed()
        let runID = "workflow-initial-manifest-run"

        await #expect(throws: ConductorRunError.self) {
            try await ConductorRunEvidenceService().prepare(
                directory: store.directory,
                runID: runID,
                layout: .step(index: 0, agentName: "worker", attempt: 1),
                handoffArtifact: "brief.md",
                prompt: "Do not write evidence before the manifest.")
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: store.directory.runDirectoryURL(for: runID).path))
    }

    @Test("A workflow process launches only after its initial manifest persists")
    func workflowInitialManifestExistsBeforeLaunch() async throws {
        let root = try makeRunEvidenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "workflow-launch-manifest-run"
        let store = ConductorRunStore(workspaceRoot: root)
        let publisher = makeRunEvidenceController(root: root)
        let workflow = ConductorWorkflowController(
            runsPublisher: publisher,
            adapters: [FakeConductorAdapter(id: .claudeCode)])
        workflow.attach(workspaceRoot: root)
        let launcher = RunEvidenceFakeLauncher(manifestURL: store.manifestURL(for: runID))

        await workflow.start(workflowRunEvidenceRequest(runID: runID), launcher: launcher)

        #expect(launcher.foundManifestAtLaunch)
        #expect(try await store.load(runID: runID)?.id == runID)
        workflow.abort()
        await publisher.waitForPendingOperation()
    }

    @Test("Manifest-less evidence reloads as explicitly degraded history")
    func manifestlessEvidenceReloadsAsDegradedHistory() async throws {
        let root = try makeRunEvidenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "missing-manifest-run"
        let runDirectory = root.appending(path: ".rafu/runs/\(runID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: runDirectory.appending(path: "handoff", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        try Data("saved prompt".utf8).write(
            to: runDirectory.appending(path: "prompt.md"),
            options: .atomic)

        let controller = makeRunEvidenceController(root: root)
        await controller.reloadRuns()

        let recovered = try #require(controller.runs.first(where: { $0.id == runID }))
        #expect(recovered.workflowName == "Recovered evidence")
        #expect(recovered.steps.isEmpty)
        #expect(recovered.recoveryNote == ConductorRunRecoveryService.manifestlessEvidenceNote)
        #expect(try await ConductorRunStore(workspaceRoot: root).load(runID: runID) == nil)
    }

    @Test("A failed completion publishes a Failed Activity event")
    func failedCompletionPublishesFailedActivityEvent() async throws {
        let root = try makeRunEvidenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "failed-activity-run"
        let center = ConductorEnsembleEventCenter.shared
        let cursor = center.cursor
        let controller = makeRunEvidenceController(root: root)
        let launcher = RunEvidenceFakeLauncher(
            manifestURL: ConductorRunStore(workspaceRoot: root).manifestURL(for: runID))

        await controller.start(runEvidenceRequest(runID: runID), launcher: launcher)
        launcher.finish(exitCode: 17)
        await controller.waitForPendingOperation()

        let event = try #require(
            center.eventsSince(cursor).last(where: { $0.runID == runID })
        )
        #expect(event.state == .failed)
        #expect(
            controller.manifest?.steps[0].status
                == .failed(
                    "The agent process exited with status 17."))
    }

    @Test("Activity presentation identifies each run and gives every state a symbol and text")
    func activityPresentationIdentifiesRunsAndStates() {
        #expect(
            ConductorActivityPresentation.shortRunID(for: "e0e353ce-e456-48b5")
                == "Run e0e353ce")
        for state in EnsembleRunState.allCases {
            #expect(!ConductorActivityPresentation.statusSymbol(for: state).isEmpty)
            #expect(!ConductorActivityPresentation.statusLabel(for: state).isEmpty)
        }
    }
}

@MainActor
private func makeRunEvidenceController(root: URL) -> ConductorRunController {
    let controller = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    controller.attach(workspaceRoot: root)
    return controller
}

private func runEvidenceRequest(runID: String) -> ConductorRunRequest {
    ConductorRunRequest(
        role: runEvidenceRole,
        taskPrompt: "Review the run evidence.",
        runID: runID)
}

private let runEvidenceRole = ConductorAgentDefinition(
    name: "advisor",
    provider: .claudeCode,
    model: "fake-fast",
    autonomy: .readOnly,
    handoffArtifact: "brief.md",
    promptBody: "Assess the requested change.")

private func workflowRunEvidenceRequest(runID: String) -> ConductorWorkflowRunRequest {
    ConductorWorkflowRunRequest(
        workflow: ConductorWorkflowDefinition(
            name: "evidence-workflow",
            steps: [
                ConductorWorkflowDefinition.Step(
                    agentName: runEvidenceRole.name,
                    inputArtifacts: [],
                    gateAfter: false)
            ]),
        roles: [runEvidenceRole],
        taskPrompt: "Review the run evidence.",
        runID: runID)
}

private func makeRunEvidenceRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-run-evidence-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runEvidenceGit(["init", "-b", "main"], at: root)
    try Data("fixture\n".utf8).write(to: root.appending(path: "fixture.txt"))
    for arguments in [
        ["config", "user.email", "tests@rafu.invalid"],
        ["config", "user.name", "Rafu Tests"],
        ["add", "fixture.txt"],
        ["commit", "-m", "Fixture"],
    ] {
        try runEvidenceGit(arguments, at: root)
    }
    return root
}

private func runEvidenceGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RunEvidenceTestError.gitFailed
    }
}

private enum RunEvidenceTestError: Error {
    case gitFailed
}
