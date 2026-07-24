import Foundation
import Testing

@testable import RafuApp

// MARK: - ConductorRunPresentation (18)

private func presentationBinding(
    provider: ConductorCLIID = .claudeCode,
    model: String = "fake-fast"
) -> ConductorRunManifest.AgentBinding {
    ConductorRunManifest.AgentBinding(
        provider: provider, model: model, autonomy: .readOnly, adapterVersion: "fake-1.0")
}

@Test("Step-status symbols are shape-distinct and every status carries a non-empty text label")
func stepStatusSymbolsAreShapeDistinctAndLabeled() {
    let statuses: [RunStepStatus] = [
        .pending, .running, .awaitingGate, .completed, .failed("boom"), .aborted,
    ]
    let symbols = statuses.map(ConductorRunPresentation.symbol(for:))

    #expect(Set(symbols).count == symbols.count)
    for status in statuses {
        #expect(!ConductorRunPresentation.label(for: status).isEmpty)
    }
}

@Test("Step rows report a duration once started, and an attempt label only past attempt 1")
func stepRowsReportDurationAndAttemptLabels() {
    let now = Date()
    let manifest = ConductorRunManifest(
        id: "presentation-run",
        workflowName: "Ship a change",
        baseCommit: "0123456789012345678901234567890123456789",
        worktreeBranch: "rafu/run-presentation-run",
        createdAt: now,
        updatedAt: now,
        steps: [
            ConductorRunManifest.Step(
                agentName: "advisor",
                binding: presentationBinding(),
                inputArtifacts: [],
                handoffArtifact: "brief.md",
                gateAfter: false,
                status: .completed,
                startedAt: now.addingTimeInterval(-65),
                finishedAt: now,
                attempt: 1,
                evidencePath: "steps/01-advisor-a1"),
            ConductorRunManifest.Step(
                agentName: "implementor",
                binding: presentationBinding(model: ""),
                inputArtifacts: ["brief.md"],
                handoffArtifact: "patch.md",
                gateAfter: false,
                status: .failed("boom"),
                startedAt: now,
                finishedAt: nil,
                attempt: 2,
                evidencePath: "steps/02-implementor-a2"),
            ConductorRunManifest.Step(
                agentName: "documentor",
                binding: presentationBinding(),
                inputArtifacts: ["patch.md"],
                handoffArtifact: "docs.md",
                gateAfter: false,
                status: .pending,
                startedAt: nil,
                finishedAt: nil),
        ])

    let rows = ConductorRunPresentation.stepRows(for: manifest)

    #expect(rows[0].durationLabel == "1m 5s")
    #expect(rows[0].attemptLabel == nil)
    #expect(rows[0].modelLabel == "fake-fast")
    #expect(
        rows[0].artifactRelativePath
            == ".rafu/runs/presentation-run/steps/01-advisor-a1/handoff/brief.md")

    #expect(rows[1].attemptLabel == "Attempt 2")
    #expect(rows[1].modelLabel == "Adapter default")
    #expect(rows[1].statusLabel == "boom")

    #expect(rows[2].durationLabel == nil)
    #expect(rows[2].attemptLabel == nil)
}

@Test(
    "A run row surfaces the open gate as a badge and needsAttention, and only reports isLive when a live state is supplied and in flight"
)
func runRowSurfacesGateBadgeAndLiveness() {
    let now = Date()
    var manifest = ConductorRunManifest(
        id: "gate-run",
        workflowName: "Ship a change",
        baseCommit: "0123456789012345678901234567890123456789",
        worktreeBranch: "rafu/run-gate-run",
        createdAt: now,
        updatedAt: now,
        steps: [
            ConductorRunManifest.Step(
                agentName: "implementor",
                binding: presentationBinding(),
                inputArtifacts: [],
                handoffArtifact: "patch.md",
                gateAfter: false,
                status: .completed,
                startedAt: now,
                finishedAt: now)
        ])
    manifest.gate = ConductorRunManifest.Gate(kind: .merge, stepIndex: 0)

    let historical = ConductorRunPresentation.runRow(for: manifest)
    #expect(historical.gateBadge == "Merge gate")
    #expect(historical.needsAttention)
    #expect(!historical.isLive)

    let live = ConductorRunPresentation.runRow(for: manifest, liveState: .awaitingMergeGate)
    #expect(live.isLive)

    let terminal = ConductorRunPresentation.runRow(for: manifest, liveState: .completed)
    #expect(!terminal.isLive)
}

@Test(
    "A run row's status is precedence-derived across every step, not just the last one (D3 regression): a 3-step run failed at step 2 shows failed, never the untouched step 3's pending"
)
func runRowStatusUsesPrecedenceNotLastStep() {
    let now = Date()
    let failedMidRun = ConductorRunManifest(
        id: "mid-fail-run",
        workflowName: "Ship a change",
        baseCommit: "0123456789012345678901234567890123456789",
        worktreeBranch: "rafu/run-mid-fail-run",
        createdAt: now,
        updatedAt: now,
        steps: [
            ConductorRunManifest.Step(
                agentName: "advisor",
                binding: presentationBinding(),
                inputArtifacts: [],
                handoffArtifact: "brief.md",
                gateAfter: false,
                status: .completed,
                startedAt: now,
                finishedAt: now),
            ConductorRunManifest.Step(
                agentName: "implementor",
                binding: presentationBinding(),
                inputArtifacts: ["brief.md"],
                handoffArtifact: "patch.md",
                gateAfter: false,
                status: .failed("The agent process exited with status 9."),
                startedAt: now,
                finishedAt: now),
            ConductorRunManifest.Step(
                agentName: "documentor",
                binding: presentationBinding(),
                inputArtifacts: ["patch.md"],
                handoffArtifact: "docs.md",
                gateAfter: false,
                status: .pending,
                startedAt: nil,
                finishedAt: nil),
        ])

    let row = ConductorRunPresentation.runRow(for: failedMidRun)

    #expect(row.status == .failed("The agent process exited with status 9."))
    #expect(row.statusSymbol == "exclamationmark.triangle.fill")
    #expect(row.statusLabel == "The agent process exited with status 9.")
    #expect(row.needsAttention)

    // An abort mid-run must read the same way — never the untouched later
    // step's `.pending`.
    var abortedMidRun = failedMidRun
    abortedMidRun.steps[1].status = .aborted
    let abortedRow = ConductorRunPresentation.runRow(for: abortedMidRun)
    #expect(abortedRow.status == .aborted)
    #expect(abortedRow.statusSymbol == "xmark.circle.fill")
    #expect(abortedRow.needsAttention == false)

    // A run still genuinely mid-flight (step 2 running, step 3 pending) must
    // read as running, never pending.
    var runningMidRun = failedMidRun
    runningMidRun.steps[1].status = .running
    let runningRow = ConductorRunPresentation.runRow(for: runningMidRun)
    #expect(runningRow.status == .running)
    #expect(runningRow.statusSymbol == "circle.fill")
}

// MARK: - WorkspaceSession canvas seams (19, 20)

@MainActor
@Test(
    "showConductorRunDetail opens the canvas, clears the document selection; closeConductorRunDetail restores a document fallback"
)
func showAndCloseConductorRunDetail() throws {
    let session = WorkspaceSession()
    session.newUntitledDocument()
    let document = try #require(session.openDocuments.first)
    session.select(document)
    #expect(session.selectedDocumentID == document.id)

    session.showConductorRunDetail("run-1")

    #expect(session.conductorRunCanvasID == "run-1")
    #expect(session.selectedConductorRunID == "run-1")
    #expect(session.navigatorMode == .runs)
    #expect(session.selectedDocumentID == nil)
    #expect(session.selectedTreePath == nil)

    session.closeConductorRunDetail()

    #expect(session.conductorRunCanvasID == nil)
    #expect(session.selectedDocumentID == document.id)
}

@MainActor
@Test(
    "Revealing a terminal session clears the run-detail canvas but leaves the panel selection alone"
)
func revealTerminalSessionClearsCanvas() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    session.showConductorRunDetail("run-1")
    #expect(session.conductorRunCanvasID == "run-1")

    session.revealTerminalSession(controller.id)

    #expect(session.conductorRunCanvasID == nil)
    #expect(session.selectedConductorRunID == "run-1")
}

// MARK: - Gate attention (21)

@MainActor
private final class GateAttentionSpyNotifier: TerminalAttentionNotifying {
    private(set) var posted: [TerminalAttentionNotification] = []

    func requestAuthorizationIfNeeded() async -> Bool { true }

    func post(_ notification: TerminalAttentionNotification) {
        posted.append(notification)
    }
}

@MainActor
private final class GateAttentionSpyHUD: NotchHUDPresenting {
    private(set) var shown: [NotchHUDEvent] = []

    func show(_ event: NotchHUDEvent, theme: RafuTheme) {
        shown.append(event)
    }

    func attentionCleared(for sessionID: UUID) {}
}

/// Mirrors `TerminalAttentionTests.installAttentionRig` (a hermetic,
/// suite-backed surface store + spy notifier/HUD + fixed theme provider) for
/// `raiseConductorGateAttention(runName:stepName:)`.
@MainActor
private func installGateAttentionRig(
    on session: WorkspaceSession,
    surface: TerminalAttentionSurface
) -> (notifier: GateAttentionSpyNotifier, hud: GateAttentionSpyHUD, suiteName: String) {
    let suiteName = "WorkflowPresentationTests.\(UUID().uuidString)"
    let store = TerminalAttentionSurfaceStore(suiteName: suiteName)
    store.setSurface(surface)
    session.terminalAttentionSurfaceStore = store
    let notifier = GateAttentionSpyNotifier()
    session.attentionNotifier = notifier
    let hud = GateAttentionSpyHUD()
    session.attentionHUD = hud
    session.hudThemeProvider = { RafuThemeCatalog.indigo }
    return (notifier, hud, suiteName)
}

@MainActor
@Test(
    "Gate attention posts exactly one bounded notification carrying the step name, never captured output or artifact content"
)
func gateAttentionPostsExactlyOneBoundedNotification() async throws {
    let session = WorkspaceSession()
    let rig = installGateAttentionRig(on: session, surface: .both)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.raiseConductorGateAttention(runName: "Ship a change", stepName: "Implementor")

    for _ in 0..<20_000 {
        if rig.notifier.posted.count >= 1 { break }
        await Task.yield()
    }

    #expect(rig.notifier.posted.count == 1)
    let posted = try #require(rig.notifier.posted.first)
    #expect(posted.title == "Ship a change")
    #expect(posted.body.contains("Implementor"))
    #expect(!posted.body.contains("SECRET-ARTIFACT-CONTENT"))

    #expect(rig.hud.shown.count == 1)
    #expect(rig.hud.shown.first?.title == "Ship a change")
    #expect(rig.hud.shown.first?.snippet.contains("Implementor") == true)

    // D6: runName/stepName come from user-authored frontmatter (capped at
    // 1 MiB per FILE, not per field) — an enormous step name must still
    // yield a bounded HUD snippet and notification body, never the raw
    // 5000-byte string verbatim.
    let hugeStepName = String(repeating: "x", count: 5_000)
    session.raiseConductorGateAttention(runName: "Ship a change", stepName: hugeStepName)
    for _ in 0..<20_000 {
        if rig.notifier.posted.count >= 2 { break }
        await Task.yield()
    }
    #expect(rig.notifier.posted.count == 2)
    let boundedPosted = try #require(rig.notifier.posted.last)
    #expect(boundedPosted.body.utf8.count < hugeStepName.utf8.count)
    #expect(boundedPosted.body.utf8.count < 300)
    #expect(rig.hud.shown.count == 2)
    let boundedShown = try #require(rig.hud.shown.last)
    #expect(boundedShown.snippet.utf8.count < hugeStepName.utf8.count)
    #expect(boundedShown.snippet.utf8.count < 300)
}

@MainActor
@Test("Gate attention surfaces nothing when the attention preference is .none")
func gateAttentionSurfacesNothingWhenPreferenceOff() async throws {
    let session = WorkspaceSession()
    let rig = installGateAttentionRig(on: session, surface: .none)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.raiseConductorGateAttention(runName: "Ship a change", stepName: "Implementor")

    for _ in 0..<500 {
        await Task.yield()
    }

    #expect(rig.notifier.posted.isEmpty)
    #expect(rig.hud.shown.isEmpty)
}
