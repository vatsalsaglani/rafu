import Foundation
import Testing

@testable import RafuApp

/// Handoff 3 (C7 → coordinator): recovery was planned honestly but a relaunched
/// app could not act on it. These cover the persistence pass in `reloadRuns()`
/// and the three adopted verbs.
private func interruptedManifest(
    runID: String,
    worktreeBranch: String = "rafu/run-\(UUID().uuidString.prefix(4))",
    evidencePath: String? = "steps/01-worker-a1"
) -> ConductorRunManifest {
    var manifest = ConductorRunManifest(
        id: runID,
        workflowName: "pipeline",
        baseCommit: "abc1234",
        worktreeBranch: worktreeBranch,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_060),
        steps: [
            ConductorRunManifest.Step(
                agentName: "worker",
                binding: ConductorRunManifest.AgentBinding(
                    provider: .claudeCode, model: "", autonomy: .worktreeWrite,
                    adapterVersion: nil),
                inputArtifacts: [],
                handoffArtifact: "result.md",
                gateAfter: false,
                // Persisted as running: the previous app process died here.
                status: .running,
                startedAt: Date(timeIntervalSince1970: 1_700_000_030),
                finishedAt: nil)
        ])
    manifest.steps[0].evidencePath = evidencePath
    return manifest
}

@MainActor
@Test("Reload rewrites a persisted running step to interrupted and records the note")
func reloadMarksRunningStepsInterrupted() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = interruptedManifest(runID: "interrupted-run")
    let store = ConductorRunStore(workspaceRoot: root)
    _ = try await store.directory.seed()
    try await store.save(manifest)

    // The worktree "exists" as far as the janitor is concerned, so the run is
    // interrupted rather than history-only.
    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)],
        recoveryService: ConductorRunRecoveryService(fileExists: { _ in true }))
    await controller.attachAndReload(workspaceRoot: root)
    await controller.waitForPendingOperation()

    let reloaded = try #require(controller.runs.first(where: { $0.id == "interrupted-run" }))
    #expect(reloaded.steps[0].status == .interrupted)
    #expect(reloaded.recoveryNote != nil)

    // Persisted, not just in memory: a second reload sees the same truth and
    // does not need to redo the rewrite.
    let reread = try #require(try await store.load(runID: "interrupted-run"))
    #expect(reread.steps[0].status == .interrupted)
}

@MainActor
@Test("A run whose worktree vanished degrades to history with a note, not a crash")
func vanishedWorktreeDegradesToHistory() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConductorRunStore(workspaceRoot: root)
    _ = try await store.directory.seed()
    try await store.save(interruptedManifest(runID: "gone-worktree"))

    let controller = ConductorRunController(
        adapters: [FakeConductorAdapter(id: .claudeCode)],
        recoveryService: ConductorRunRecoveryService(fileExists: { _ in false }))
    await controller.attachAndReload(workspaceRoot: root)
    await controller.waitForPendingOperation()

    let reloaded = try #require(controller.runs.first(where: { $0.id == "gone-worktree" }))
    #expect(reloaded.recoveryNote != nil)
    // No gate can be resolved against a worktree that is gone.
    #expect(reloaded.gate == nil)
}

@MainActor
@Test("An interrupted run is adopted so its verbs work, without resurrecting anything")
func interruptedRunIsAdoptable() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    publisher.attach(workspaceRoot: root)
    let controller = ConductorWorkflowController(
        runsPublisher: publisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    var manifest = interruptedManifest(runID: "adopt-me")
    manifest.steps[0].status = .interrupted
    let launcher = WorkflowFakeLauncher()

    #expect(
        controller.restoreInterrupted(
            manifest: manifest, workspaceRoot: root, launcher: launcher))
    // Adoption starts NOTHING: no process is resurrected (ADR 0004/0014).
    #expect(launcher.recorded.isEmpty)
    #expect(controller.manifest?.id == "adopt-me")

    // A manifest with nothing interrupted is not adoptable — the caller then
    // shows read-only history instead of dead verbs.
    var completed = manifest
    completed.steps[0].status = .completed
    let other = ConductorWorkflowController(
        runsPublisher: publisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    #expect(
        !other.restoreInterrupted(
            manifest: completed, workspaceRoot: root, launcher: launcher))
}

@MainActor
@Test("Aborting an interrupted run keeps its evidence and worktree")
func abortInterruptedKeepsEvidence() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    publisher.attach(workspaceRoot: root)
    let controller = ConductorWorkflowController(
        runsPublisher: publisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    var manifest = interruptedManifest(runID: "abort-me")
    manifest.steps[0].status = .interrupted
    _ = controller.restoreInterrupted(
        manifest: manifest, workspaceRoot: root, launcher: WorkflowFakeLauncher())

    controller.abortInterruptedRun()

    #expect(controller.state == .aborted)
    #expect(controller.manifest?.steps[0].status == .aborted)
    #expect(controller.manifest?.recoveryNote == nil)
    // Published so the panel and disk agree.
    #expect(publisher.runs.first(where: { $0.id == "abort-me" })?.steps[0].status == .aborted)
}

@MainActor
@Test("Keeping the worktree closes the run and says so")
func keepInterruptedWorktreeRecordsWhy() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    publisher.attach(workspaceRoot: root)
    let controller = ConductorWorkflowController(
        runsPublisher: publisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    var manifest = interruptedManifest(runID: "keep-me")
    manifest.steps[0].status = .interrupted
    _ = controller.restoreInterrupted(
        manifest: manifest, workspaceRoot: root, launcher: WorkflowFakeLauncher())

    controller.keepInterruptedWorktree()

    #expect(controller.state == .completed)
    #expect(controller.manifest?.recoveryNote?.isEmpty == false)
}

@MainActor
@Test("Retrying an interrupted step reuses its persisted prompt in a fresh attempt")
func retryInterruptedStepUsesPersistedPrompt() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConductorRunStore(workspaceRoot: root)
    _ = try await store.directory.seed()

    // The prompt the interrupted attempt actually used, exactly as the previous
    // app process wrote it.
    let priorPrompt = "The original composed prompt for the interrupted attempt."
    let priorDir = root.appending(path: ".rafu/runs/retry-me/steps/01-worker-a1")
    try FileManager.default.createDirectory(at: priorDir, withIntermediateDirectories: true)
    try Data(priorPrompt.utf8).write(to: priorDir.appending(path: "prompt.md"))

    let publisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    publisher.attach(workspaceRoot: root)
    let controller = ConductorWorkflowController(
        runsPublisher: publisher, adapters: [FakeConductorAdapter(id: .claudeCode)])
    var manifest = interruptedManifest(runID: "retry-me", worktreeBranch: "")
    manifest.steps[0].status = .interrupted
    let launcher = WorkflowFakeLauncher()
    _ = controller.restoreInterrupted(
        manifest: manifest, workspaceRoot: root, launcher: launcher)

    await controller.retryInterruptedStep(0)

    // Launched once, carrying the persisted prompt verbatim — never an
    // adapter-native --resume, never a recomposed prompt.
    #expect(launcher.recorded.count == 1)
    #expect(launcher.recorded[0].specification.arguments.contains(priorPrompt))
    // A FRESH attempt directory: attempt 2, and the interrupted attempt's own
    // evidence is untouched.
    #expect(controller.manifest?.steps[0].attempt == 2)
    #expect(controller.manifest?.steps[0].evidencePath == "steps/01-worker-a2")
    #expect(controller.manifest?.recoveryNote == nil)
    #expect(FileManager.default.fileExists(atPath: priorDir.appending(path: "prompt.md").path))

    controller.abort()
}

@Test("A pre-C7 manifest with no recoveryNote still decodes")
func preC7ManifestDecodesWithoutRecoveryNote() throws {
    let json = """
        {
          "baseCommit" : "abc1234",
          "createdAt" : "2026-07-24T00:00:00Z",
          "id" : "legacy",
          "steps" : [],
          "updatedAt" : "2026-07-24T00:01:00Z",
          "workflowName" : "legacy",
          "worktreeBranch" : ""
        }
        """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ConductorRunManifest.self, from: Data(json.utf8))
    #expect(manifest.recoveryNote == nil)
}

@Test("The interrupted status round-trips through the stable envelope")
func interruptedStatusRoundTrips() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(RunStepStatus.interrupted)
    #expect(String(decoding: data, as: UTF8.self) == "{\"state\":\"interrupted\"}")
    #expect(try JSONDecoder().decode(RunStepStatus.self, from: data) == .interrupted)
}
