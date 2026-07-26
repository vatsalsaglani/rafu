import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// C8-04: `propose-merge` is token-scoped, validates ownership and state for
/// EVERY named run before mutating any of them, re-raises the human merge
/// gate, and NEVER applies/commits/merges anything. `mergedAt` + a streamed
/// `merged` event are what completes a coordinator's `await --state merged`.
///
/// `.serialized`: several tests here read `ConductorEnsembleEventCenter
/// .shared` (gate/merge events are hardcoded to it — see `WorkspaceSession
/// .raiseConductorGateAttention` and `ConductorRunController.publish`), so
/// this suite is serialized exactly like `EnsembleMutatingVerbTests` and
/// `EnsembleServerStreamTests`.
@MainActor
@Suite("Propose-merge", .serialized)
struct ProposeMergeTests {
    @Test(
        "Ownership/state matrix: no token, foreign coordinator, unknown run, wrong state, empty runIDs"
    )
    func ownershipAndStateMatrix() async throws {
        let harness = try ProposeMergeHarness(runIDs: ["run-a"])
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-owner", grant: harness.grant(concurrent: 3, total: 12))

        let started = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run", workingDirectory: harness.root.path, token: token, workflow: "ship")
        )
        let runID = try #require(started.runStarted?.runID)

        let noToken = await harness.request(
            kind: .ensembleProposeMerge,
            payload: EnsembleRequestPayload(
                verb: "propose-merge", workingDirectory: harness.root.path, runIDs: [runID])
        )
        #expect(noToken.failure?.code == 77)

        let foreignToken = harness.mint(
            coordinatorID: "co-foreign", grant: harness.grant(concurrent: 3, total: 12))
        let foreign = await harness.request(
            kind: .ensembleProposeMerge,
            payload: EnsembleRequestPayload(
                verb: "propose-merge", workingDirectory: harness.root.path, runIDs: [runID],
                token: foreignToken)
        )
        #expect(foreign.failure?.code == 77)

        let unknown = await harness.request(
            kind: .ensembleProposeMerge,
            payload: EnsembleRequestPayload(
                verb: "propose-merge", workingDirectory: harness.root.path,
                runIDs: ["not-a-run"], token: token)
        )
        #expect(unknown.failure?.code == 65)

        // Still `.running` — never finished the launcher.
        let wrongState = await harness.request(
            kind: .ensembleProposeMerge,
            payload: EnsembleRequestPayload(
                verb: "propose-merge", workingDirectory: harness.root.path, runIDs: [runID],
                token: token)
        )
        #expect(wrongState.failure?.code == 65)
        #expect(wrongState.failure?.message.contains("running") == true)

        let empty = await harness.request(
            kind: .ensembleProposeMerge,
            payload: EnsembleRequestPayload(
                verb: "propose-merge", workingDirectory: harness.root.path, runIDs: [], token: token
            )
        )
        #expect(empty.failure?.code == 64)

        harness.coordinator.controller(runID: runID)?.abort()
    }

    @Test("An accepted propose-merge posts a note, re-raises the gate, and never merges")
    func acceptedPathReraisesGate() async throws {
        let harness = try ProposeMergeHarness(runIDs: ["run-merge"])
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-owner", grant: harness.grant(concurrent: 3, total: 12))

        let started = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run", workingDirectory: harness.root.path, token: token, workflow: "ship")
        )
        let runID = try #require(started.runStarted?.runID)
        try await harness.advanceToMergeGate(runID: runID)
        let controller = try #require(harness.coordinator.controller(runID: runID))
        #expect(controller.state == .awaitingMergeGate)

        let sharedCursorBefore = ConductorEnsembleEventCenter.shared.cursor
        let response = await harness.request(
            kind: .ensembleProposeMerge,
            payload: EnsembleRequestPayload(
                verb: "propose-merge", workingDirectory: harness.root.path, runIDs: [runID],
                token: token, text: "Please review the diff.")
        )

        let result = try #require(response.proposeMerge)
        #expect(result.accepted == [runID])
        #expect(result.state == "awaiting_human")

        let notes = try await ConductorEnsembleNoteStore(
            workspaceRoot: harness.root, eventCenter: harness.eventCenter
        ).read(runID: runID)
        #expect(notes.map(\.text) == ["Please review the diff."])

        // The gate event is RE-published (kind "gate", state
        // .awaitingMergeGate) — always through the shared center, since
        // `raiseConductorGateAttention` is hardcoded to it.
        let sharedEvents = ConductorEnsembleEventCenter.shared.eventsSince(sharedCursorBefore)
        #expect(
            sharedEvents.contains {
                $0.runID == runID && $0.kind == "gate" && $0.state == .awaitingMergeGate
            })

        // The FULL raiseConductorGateAttention path ran headlessly without
        // crashing — including the real notification leg (absorbed by the
        // rig's spy, never the real UNUserNotificationCenter) — proving
        // propose-merge's re-raise is genuinely headless-safe, not merely
        // dodging the crash by turning surfaces off.
        await harness.waitForNotification()
        #expect(harness.attentionHUD.shown.count == 1)
        #expect(harness.attentionNotifier.posted.count == 1)
        #expect(
            harness.attentionNotifier.posted.first?.kind
                == .ensembleGate(runID: runID, allowsApprove: false))

        // Never merges: still parked, nothing applied, the worktree is
        // untouched.
        #expect(controller.state == .awaitingMergeGate)
        #expect(!controller.hasAppliedToWorkspace)
        let worktreeURL = try #require(controller.plan?.worktreeURL)
        #expect(FileManager.default.fileExists(atPath: worktreeURL.path))

        controller.abort()
    }

    @Test("applyToWorkspace stamps mergedAt and streams a merged event for the workflow controller")
    func workflowControllerStampsMergedAt() async throws {
        let harness = try ProposeMergeHarness(runIDs: ["run-apply"])
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-owner", grant: harness.grant(concurrent: 3, total: 12))
        let started = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run", workingDirectory: harness.root.path, token: token, workflow: "ship")
        )
        let runID = try #require(started.runStarted?.runID)
        try await harness.advanceToMergeGate(runID: runID)
        let controller = try #require(harness.coordinator.controller(runID: runID))
        #expect(controller.state == .awaitingMergeGate)

        let cursorBefore = ConductorEnsembleEventCenter.shared.cursor
        await controller.applyToWorkspace()

        #expect(controller.mergeGateError == nil)
        #expect(controller.state == .completed)
        #expect(controller.hasAppliedToWorkspace)
        #expect(controller.manifest?.mergedAt != nil)

        let events = ConductorEnsembleEventCenter.shared.eventsSince(cursorBefore)
        #expect(
            events.contains {
                $0.runID == runID && $0.kind == "merged" && $0.state == .merged
            })
    }

    @Test(
        "applyToWorkspace stamps mergedAt and streams a merged event for the C1 single-role controller"
    )
    func runControllerStampsMergedAt() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
        let launcher = ProposeMergeRunLauncher()
        let runID = "propose-merge-c1-apply"
        controller.attach(workspaceRoot: root)
        await controller.start(
            ConductorRunRequest(
                role: ConductorAgentDefinition(
                    name: "implementor",
                    provider: .claudeCode,
                    model: "fake-fast",
                    autonomy: .worktreeWrite,
                    handoffArtifact: "result.md",
                    promptBody: "Implement the requested change."),
                taskPrompt: "Implement.",
                runID: runID),
            launcher: launcher)
        let plan = try #require(controller.activeWorkspacePlan)
        let worktreeURL = try #require(plan.worktreeURL)
        try Data("changed\n".utf8).write(to: worktreeURL.appending(path: "fixture.txt"))
        try Data("fake artifact".utf8).write(
            to: root.appending(path: ".rafu/runs/\(runID)/handoff/result.md"))
        launcher.finish(0)
        await controller.waitForPendingOperation()
        #expect(controller.state == .awaitingMergeGate)

        let cursorBefore = ConductorEnsembleEventCenter.shared.cursor
        await controller.applyToWorkspace()

        #expect(controller.state == .completed)
        #expect(controller.hasAppliedToWorkspace)
        #expect(controller.manifest?.mergedAt != nil)

        let events = ConductorEnsembleEventCenter.shared.eventsSince(cursorBefore)
        #expect(
            events.contains {
                $0.runID == runID && $0.kind == "merged" && $0.state == .merged
            })
    }

    @Test("A subscriber on the event stream receives the merged event applyToWorkspace stamps")
    func subscriberReceivesMergedEventThroughTheStream() async throws {
        let harness = try ProposeMergeHarness(runIDs: ["run-await"])
        defer { harness.cleanUp() }
        let token = harness.mint(
            coordinatorID: "co-owner", grant: harness.grant(concurrent: 3, total: 12))
        let started = await harness.request(
            kind: .ensembleRun,
            payload: EnsembleRequestPayload(
                verb: "run", workingDirectory: harness.root.path, token: token, workflow: "ship")
        )
        let runID = try #require(started.runStarted?.runID)
        try await harness.advanceToMergeGate(runID: runID)
        let controller = try #require(harness.coordinator.controller(runID: runID))

        // This IS the mechanism `rafu ensemble await --state merged` relies
        // on: a live AsyncStream subscriber on the same event center
        // `applyToWorkspace()` publishes through.
        let stream = ConductorEnsembleEventCenter.shared.subscribe()
        var iterator = stream.makeAsyncIterator()

        async let applyTask: Void = controller.applyToWorkspace()

        // BOUNDED deliberately. This subscribes to the shared event center,
        // whose heartbeat keeps yielding, so `iterator.next()` never returns
        // nil: if the merged event regressed, an unbounded loop would spin
        // forever and hang the whole serialized suite rather than failing.
        // The bound is a number of events, not a sleep — no timing assumption.
        var matched: EnsembleEvent?
        var inspected = 0
        let maxEventsToInspect = 64
        while matched == nil, inspected < maxEventsToInspect {
            guard let event = await iterator.next() else { break }
            inspected += 1
            if event.runID == runID, event.kind == "merged" {
                matched = event
            }
        }
        await applyTask
        ConductorEnsembleEventCenter.shared.finishSubscriptionsForTesting()

        let event = try #require(matched)
        #expect(event.state == .merged)
        #expect(controller.manifest?.mergedAt != nil)
    }

    @Test("appliedButCleanupFailed still stamps mergedAt (the merge-back already happened)")
    func appliedButCleanupFailedStillStampsMergedAt() async throws {
        let container = FileManager.default.temporaryDirectory
            .appending(
                path: "rafu-propose-merge-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory
            )
        let root = container.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try initializeWorkflowRepository(at: root)
        defer { try? FileManager.default.removeItem(at: container) }

        // An ignored file in the worktree makes Git's apply-then-clean step
        // fail its final verification (`ConductorMergeGateService.apply`
        // throws `.appliedButCleanupFailed`) even though the tracked change
        // already copied over — the exact scenario A5 exists for.
        try Data("private.txt\n".utf8).write(to: root.appending(path: ".gitignore"))
        try workflowGit(["add", ".gitignore"], at: root)
        try workflowGit(["commit", "-m", "Ignore private file"], at: root)

        let controller = ConductorRunController(adapters: [FakeConductorAdapter(id: .claudeCode)])
        let launcher = ProposeMergeRunLauncher()
        let runID = "propose-merge-cleanup-failed"
        controller.attach(workspaceRoot: root)
        await controller.start(
            ConductorRunRequest(
                role: ConductorAgentDefinition(
                    name: "implementor",
                    provider: .claudeCode,
                    model: "fake-fast",
                    autonomy: .worktreeWrite,
                    handoffArtifact: "result.md",
                    promptBody: "Implement the requested change."),
                taskPrompt: "Implement.",
                runID: runID),
            launcher: launcher)
        let plan = try #require(controller.activeWorkspacePlan)
        let worktreeURL = try #require(plan.worktreeURL)
        try Data("agent\n".utf8).write(to: worktreeURL.appending(path: "fixture.txt"))
        try Data("private work\n".utf8).write(to: worktreeURL.appending(path: "private.txt"))
        try Data("fake artifact".utf8).write(
            to: root.appending(path: ".rafu/runs/\(runID)/handoff/result.md"))
        launcher.finish(0)
        await controller.waitForPendingOperation()
        #expect(controller.state == .awaitingMergeGate)

        await controller.applyToWorkspace()

        #expect(controller.mergeGateError != nil)
        #expect(controller.hasAppliedToWorkspace)
        #expect(controller.state == .completed)
        #expect(controller.manifest?.mergedAt != nil)
    }
}

@MainActor
private final class ProposeMergeAttentionSpyNotifier: TerminalAttentionNotifying {
    private(set) var posted: [TerminalAttentionNotification] = []

    func requestAuthorizationIfNeeded() async -> Bool { true }

    func post(_ notification: TerminalAttentionNotification) {
        posted.append(notification)
    }
}

@MainActor
private final class ProposeMergeAttentionSpyHUD: NotchHUDPresenting {
    private(set) var shown: [NotchHUDEvent] = []

    func show(_ event: NotchHUDEvent, theme: RafuTheme) {
        shown.append(event)
    }

    func attentionCleared(for sessionID: UUID) {}
}

@MainActor
private final class ProposeMergeRunLauncher: ConductorRunProcessLaunching {
    let sessionID = UUID()
    private var exitHandler: (@MainActor @Sendable (UUID, Int32?) -> Void)?

    func launch(
        specification _: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        exitHandler = onExit
        return sessionID
    }

    func terminate(sessionID _: UUID) {}

    func finish(_ code: Int32?) {
        exitHandler?(sessionID, code)
    }
}

/// Mirrors `EnsembleMutatingVerbTests.MutatingVerbHarness` — reproduced here
/// rather than shared because that harness is file-private, and this suite
/// additionally needs to drive a run all the way to its merge gate.
@MainActor
private final class ProposeMergeHarness {
    let container: URL
    let root: URL
    let session: WorkspaceSession
    let eventCenter: ConductorEnsembleEventCenter
    let tokenStore: ConductorEnsembleTokenStore
    let coordinator: ConductorConcurrentRunCoordinator
    /// `proposeMerge()` raises gate attention through the real
    /// `WorkspaceSession` seam (`raiseConductorGateAttention`), whose FULL
    /// path — including the notification leg — this rig keeps reachable
    /// and headless-safe: `.both` matches the real app default, and these
    /// spies absorb what would otherwise construct the real, bundle-
    /// requiring `UNUserNotificationCenter` (`SystemTerminalAttentionNotifier`'s
    /// own doc comment: "a raw SwiftPM binary or the `swift test` bundle
    /// has no bundle identity… known to fail or trap").
    let attentionNotifier: ProposeMergeAttentionSpyNotifier
    let attentionHUD: ProposeMergeAttentionSpyHUD
    private let attentionSuiteName: String
    private let definitionLibrary: ConductorDefinitionLibrary
    private var pendingRunIDs: [String]
    private(set) var launchers: [WorkflowFakeLauncher] = []

    init(runIDs: [String]) throws {
        container = FileManager.default.temporaryDirectory
            .appending(
                path: "rafu-propose-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = container.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try initializeWorkflowRepository(at: root)
        try Self.writeDefinitions(to: root)

        session = WorkspaceSession()
        attentionSuiteName = "ProposeMergeTests.\(UUID().uuidString)"
        let surfaceStore = TerminalAttentionSurfaceStore(suiteName: attentionSuiteName)
        surfaceStore.setSurface(.both)
        session.terminalAttentionSurfaceStore = surfaceStore
        attentionNotifier = ProposeMergeAttentionSpyNotifier()
        session.attentionNotifier = attentionNotifier
        attentionHUD = ProposeMergeAttentionSpyHUD()
        session.attentionHUD = attentionHUD
        session.hudThemeProvider = { RafuThemeCatalog.indigo }
        eventCenter = ConductorEnsembleEventCenter(sleep: { _ in throw CancellationError() })
        let byteSource = ProposeMergeTokenByteSource()
        tokenStore = ConductorEnsembleTokenStore(
            randomBytes: { count in byteSource.next(count: count) })
        let adapter = FakeConductorAdapter(id: .codex)
        session.conductorRunController.attach(workspaceRoot: root)
        coordinator = ConductorConcurrentRunCoordinator(
            runsPublisher: session.conductorRunController,
            adapters: [adapter],
            activeLimit: 3)
        coordinator.attach(workspaceRoot: root)
        definitionLibrary = ConductorDefinitionLibrary(
            adapters: [adapter],
            enableStore: ConductorEnableStore(
                suiteName: "ProposeMergeTests-\(UUID().uuidString)"))
        pendingRunIDs = runIDs
    }

    func cleanUp() {
        for controller in coordinator.controllers where controller.isInFlight {
            controller.abort()
        }
        UserDefaults(suiteName: attentionSuiteName)?.removePersistentDomain(
            forName: attentionSuiteName)
        try? FileManager.default.removeItem(at: container)
    }

    /// Polls briefly for the fire-and-forget notification Task
    /// `raiseConductorGateAttention` starts internally — mirrors
    /// `WorkflowPresentationTests`' own idiom for the same race.
    func waitForNotification(count: Int = 1) async {
        for _ in 0..<20_000 {
            if attentionNotifier.posted.count >= count { break }
            await Task.yield()
        }
    }

    func mint(coordinatorID: String, grant: ConductorEnsembleGrant) -> String {
        tokenStore.mint(coordinatorID: coordinatorID, grant: grant)
    }

    func grant(concurrent: Int, total: Int) -> ConductorEnsembleGrant {
        ConductorEnsembleGrant(
            maxConcurrentChildRuns: concurrent,
            maxTotalChildRuns: total,
            allowedProviders: [.codex])
    }

    /// Finishes the run's single worktree-write step (writing its handoff
    /// artifact first) and awaits until the controller parks at the merge
    /// gate.
    func advanceToMergeGate(runID: String) async throws {
        let launcher = try #require(launchers.last)
        try writeHandoff(
            root: root, runID: runID, relativePath: "steps/01-worker-a1/handoff/report.md")
        launcher.finish(0, exitCode: 0)
        let controller = try #require(coordinator.controller(runID: runID))
        await controller.waitForPendingOperation()
    }

    func request(
        kind: LauncherIPCRequestKind,
        payload: EnsembleRequestPayload
    ) async -> TestProposeMergeResponse {
        let response = await service().handleAsync(
            LauncherIPCEnvelope(kind: kind, ensemble: payload))
        guard case .ensemble(let ensemble) = response else {
            return TestProposeMergeResponse(
                payload: .failure(code: 69, message: "unexpected response"))
        }
        return TestProposeMergeResponse(payload: ensemble)
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
                            registrationOrder: 0)
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
                    return try await self.coordinator.start(request, launcher: launcher)
                },
                definitionLibrary: definitionLibrary,
                userLibraryRoot: {
                    self.container.appending(
                        path: "empty-user-library", directoryHint: .isDirectory)
                },
                tokenStore: tokenStore,
                eventCenter: eventCenter,
                makeRunID: {
                    precondition(!self.pendingRunIDs.isEmpty)
                    return self.pendingRunIDs.removeFirst()
                }
            ))
    }

    private static func writeDefinitions(to root: URL) throws {
        let dot = RafuDotDirectory(workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: dot.agentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dot.workflowsURL, withIntermediateDirectories: true)
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
        // COMMITTED, not left untracked: `ConductorMergeGateService
        // .requireSafeTarget` refuses `applyToWorkspace()` the moment the
        // main workspace root carries ANY change beyond the auto-generated
        // `.rafu/.gitignore` — an untracked `.rafu/agents|workflows/*.md`
        // trips `targetWorkspaceChanged` exactly like a real uncommitted
        // edit would. `EnsembleMutatingVerbTests`' otherwise-identical
        // fixture never hit this because none of its tests call
        // `applyToWorkspace()`; every test in this file that does needs the
        // definitions already part of `baseCommit`, matching how a real
        // repository's `.rafu/` files are actually checked in.
        try workflowGit(["add", ".rafu"], at: root)
        try workflowGit(["commit", "-m", "Ensemble definitions"], at: root)
    }
}

@MainActor
private final class ProposeMergeTokenByteSource {
    private var generation: UInt8 = 0

    func next(count: Int) -> [UInt8] {
        generation &+= 1
        return (0..<count).map { UInt8($0 % 251) &+ generation }
    }
}

private struct TestProposeMergeResponse {
    let payload: EnsembleResponsePayload

    var runStarted: EnsembleRunStartResult? {
        guard case .runStarted(let value) = payload else { return nil }
        return value
    }

    var proposeMerge: EnsembleProposeMergeResult? {
        guard case .proposeMerge(let value) = payload else { return nil }
        return value
    }

    var failure: (code: Int32, message: String)? {
        guard case .failure(let code, let message) = payload else { return nil }
        return (code, message)
    }
}
