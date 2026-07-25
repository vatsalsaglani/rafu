import Foundation
import Testing

@testable import RafuApp

/// Handoff 2 (C7 → coordinator): usage deltas were computed and tested but
/// never persisted or shown. These cover the wiring — snapshot before launch,
/// record on every terminal outcome, into the manifest, out to the row models.
@MainActor
private func meteredController(
    root: URL,
    start: [UsageSnapshot],
    end: [UsageSnapshot]
) -> (runsPublisher: ConductorRunController, controller: ConductorWorkflowController) {
    let runsPublisher = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
    runsPublisher.attach(workspaceRoot: root)
    // First read returns the pre-launch baseline, every later read the post-run
    // values, so one step produces exactly one honest delta.
    let readCount = Counter()
    let meter = ConductorRunUsageMeter(readSnapshots: { _ in
        await readCount.increment() == 1 ? start : end
    })
    let controller = ConductorWorkflowController(
        runsPublisher: runsPublisher,
        adapters: [FakeConductorAdapter(id: .claudeCode)],
        usageMeter: meter)
    controller.attach(workspaceRoot: root)
    return (runsPublisher, controller)
}

private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

private func singleStepRequest(runID: String) -> ConductorWorkflowRunRequest {
    ConductorWorkflowRunRequest(
        workflow: workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)]),
        roles: [workflowRole(name: "worker", handoffArtifact: "result.md")],
        taskPrompt: "Do the work.",
        runID: runID)
}

@MainActor
@Test("A completed step's usage delta is recorded in the manifest and published")
func completedStepPersistsUsageDelta() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (runsPublisher, controller) = meteredController(
        root: root,
        start: ConductorUsageFixtures.start,
        end: ConductorUsageFixtures.end)
    let launcher = WorkflowFakeLauncher()

    await controller.start(singleStepRequest(runID: "usage-ok"), launcher: launcher)
    try writeHandoff(
        root: root, runID: "usage-ok", relativePath: "steps/01-worker-a1/handoff/result.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    let usage = controller.manifest?.steps.first?.usage
    #expect(usage != nil)
    #expect(usage?.attempt == 1)
    // Codex moved 12.4% -> 13.6%; the delta is recorded per provider/window.
    let codex = usage?.providers.first(where: { $0.providerID == .codex })
    #expect(codex?.windows.contains(where: { $0.label == "5h" }) == true)

    // Published, not just held in memory: the run list carries it too.
    let published = runsPublisher.runs.first(where: { $0.id == "usage-ok" })
    #expect(published?.steps.first?.usage == usage)

    // And it reaches the view layer as text, never as a bare number.
    let rows = ConductorRunPresentation.stepRows(for: try #require(controller.manifest))
    #expect(!rows[0].usageLines.isEmpty)
}

@MainActor
@Test("A failed step still records what it consumed")
func failedStepStillRecordsUsage() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = meteredController(
        root: root,
        start: ConductorUsageFixtures.start,
        end: ConductorUsageFixtures.end)
    let launcher = WorkflowFakeLauncher()

    await controller.start(singleStepRequest(runID: "usage-fail"), launcher: launcher)
    // Nonzero exit: the step failed, but the child still burned quota — hiding
    // that would be the dishonest reading C7 exists to prevent.
    launcher.finish(0, exitCode: 3)
    await controller.waitForPendingOperation()

    guard case .failed = controller.state else {
        Issue.record("Expected the run to park as failed")
        return
    }
    #expect(controller.manifest?.steps.first?.usage != nil)
}

@MainActor
@Test("A provider with no resolvable windows records nothing, never a zero")
func unmeterableProviderRecordsNothing() async throws {
    let root = try makeWorkflowTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, controller) = meteredController(
        root: root,
        start: ConductorUsageFixtures.noDataStart,
        end: ConductorUsageFixtures.noDataEnd)
    let launcher = WorkflowFakeLauncher()

    await controller.start(singleStepRequest(runID: "usage-none"), launcher: launcher)
    try writeHandoff(
        root: root, runID: "usage-none", relativePath: "steps/01-worker-a1/handoff/result.md")
    launcher.finish(0, exitCode: 0)
    await controller.waitForPendingOperation()

    // A cost line is not a window delta: nothing is recorded, and the row
    // shows no usage text at all.
    #expect(controller.manifest?.steps.first?.usage == nil)
    let rows = ConductorRunPresentation.stepRows(for: try #require(controller.manifest))
    #expect(rows[0].usageLines.isEmpty)
    #expect(ConductorRunPresentation.runUsageLines(for: try #require(controller.manifest)).isEmpty)
}

@Test("Run totals aggregate every step that recorded usage")
func runTotalsAggregateAcrossSteps() throws {
    let record = try #require(
        ConductorRunUsageMeter.record(
            from: ConductorUsageFixtures.snapshot(
                date: ConductorUsageFixtures.startDate, values: ConductorUsageFixtures.start),
            to: ConductorUsageFixtures.snapshot(
                date: ConductorUsageFixtures.endDate, values: ConductorUsageFixtures.end),
            attempt: 1))

    var manifest = ConductorRunManifest(
        id: "totals",
        workflowName: "pipeline",
        baseCommit: "abc1234",
        worktreeBranch: "",
        createdAt: ConductorUsageFixtures.startDate,
        updatedAt: ConductorUsageFixtures.endDate,
        steps: [
            ConductorRunManifest.Step(
                agentName: "one",
                binding: ConductorRunManifest.AgentBinding(
                    provider: .claudeCode, model: "", autonomy: .readOnly, adapterVersion: nil),
                inputArtifacts: [],
                handoffArtifact: "a.md",
                gateAfter: false,
                status: .completed,
                startedAt: nil,
                finishedAt: nil),
            ConductorRunManifest.Step(
                agentName: "two",
                binding: ConductorRunManifest.AgentBinding(
                    provider: .claudeCode, model: "", autonomy: .readOnly, adapterVersion: nil),
                inputArtifacts: [],
                handoffArtifact: "b.md",
                gateAfter: false,
                status: .completed,
                startedAt: nil,
                finishedAt: nil),
        ])
    manifest.steps[0].usage = record
    manifest.steps[1].usage = record

    // Two identical steps: the total is the sum, not one step's reading.
    let totals = ConductorRunUsagePresentation.runTotals(from: [record, record])
    let single = ConductorRunUsagePresentation.runTotals(from: [record])
    #expect(totals != single)
    #expect(!ConductorRunPresentation.runUsageLines(for: manifest).isEmpty)
}

@Test("A pre-C7 manifest with no usage keys still decodes")
func preC7ManifestDecodesWithoutUsage() throws {
    let json = """
        {
          "baseCommit" : "abc1234",
          "createdAt" : "2026-07-24T00:00:00Z",
          "id" : "legacy-run",
          "steps" : [
            {
              "agentName" : "worker",
              "binding" : { "autonomy" : "readOnly", "model" : "", "provider" : "claudeCode" },
              "gateAfter" : false,
              "handoffArtifact" : "result.md",
              "inputArtifacts" : [],
              "status" : { "state" : "completed" }
            }
          ],
          "updatedAt" : "2026-07-24T00:01:00Z",
          "workflowName" : "legacy",
          "worktreeBranch" : ""
        }
        """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ConductorRunManifest.self, from: Data(json.utf8))
    #expect(manifest.steps[0].usage == nil)
    #expect(ConductorRunPresentation.runUsageLines(for: manifest).isEmpty)
}
