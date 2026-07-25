import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Ensemble request service")
struct EnsembleRequestServiceTests {
    @Test("Status maps a real session manifest and injected live state")
    func statusMapsSessionAndLiveState() throws {
        let root = fileURL("/work/project")
        let session = WorkspaceSession()
        session.conductorRunController.publish(manifest(id: "live"))
        let center = quietEventCenter()
        let service = makeService(
            workspaces: [workspace(root: root, session: session)],
            eventCenter: center,
            liveState: { _, runID in
                runID == "live" ? .awaitingMergeGate : nil
            }
        )

        let result = try statusResult(
            service.handle(statusEnvelope(directory: "/work/project/Sources")))

        #expect(result.runs.count == 1)
        #expect(result.runs[0].runID == "live")
        #expect(result.runs[0].state == .awaitingMergeGate)
        #expect(result.verbVersion == 1)
    }

    @Test("Deepest containing workspace wins, then key-window order breaks ties")
    func workspaceRouting() throws {
        let parent = WorkspaceSession()
        let childFirst = WorkspaceSession()
        let childKey = WorkspaceSession()
        parent.conductorRunController.publish(manifest(id: "parent"))
        childFirst.conductorRunController.publish(manifest(id: "first"))
        childKey.conductorRunController.publish(manifest(id: "key"))

        let service = makeService(
            workspaces: [
                workspace(root: fileURL("/work"), session: parent, order: 0),
                workspace(
                    root: fileURL("/work/project"),
                    session: childFirst,
                    order: 1
                ),
                workspace(
                    root: fileURL("/work/project"),
                    session: childKey,
                    isKey: true,
                    order: 2
                ),
            ],
            eventCenter: quietEventCenter()
        )
        let result = try statusResult(
            service.handle(statusEnvelope(directory: "/work/project/Sources")))
        #expect(result.runs.map(\.runID) == ["key"])
    }

    @Test("Tree mode orders a parent before children using startedBy")
    func treeGrouping() throws {
        let session = WorkspaceSession()
        session.conductorRunController.publish(
            manifest(id: "child", startedBy: "parent"))
        session.conductorRunController.publish(manifest(id: "parent"))
        let service = makeService(
            workspaces: [workspace(root: fileURL("/work"), session: session)],
            eventCenter: quietEventCenter()
        )

        let result = try statusResult(
            service.handle(statusEnvelope(directory: "/work", tree: true)))

        #expect(result.tree)
        #expect(result.runs.map(\.runID) == ["parent", "child"])
        #expect(result.runs[1].startedBy == "parent")
    }

    @Test("Artifact resolves the manifest evidence and handoff path absolutely")
    func artifactResolution() throws {
        let session = WorkspaceSession()
        session.conductorRunController.publish(
            manifest(id: "run-a", evidencePath: "steps/01-worker-a2"))
        let service = makeService(
            workspaces: [workspace(root: fileURL("/work"), session: session)],
            eventCenter: quietEventCenter()
        )
        let envelope = LauncherIPCEnvelope(
            kind: .ensembleArtifact,
            ensemble: EnsembleRequestPayload(
                verb: "artifact",
                workingDirectory: "/work",
                runIDs: ["run-a"],
                stepIndex: 0
            )
        )

        guard case .ensemble(.artifact(let result)) = service.handle(envelope) else {
            Issue.record("Expected an artifact result")
            return
        }
        #expect(result.stepIndex == 0)
        #expect(
            result.artifacts
                == ["/work/.rafu/runs/run-a/steps/01-worker-a2/handoff/report.md"]
        )
    }

    @Test("Missing run or step is data error 65")
    func missingArtifact() {
        let session = WorkspaceSession()
        session.conductorRunController.publish(manifest(id: "run-a"))
        let service = makeService(
            workspaces: [workspace(root: fileURL("/work"), session: session)],
            eventCenter: quietEventCenter()
        )
        let envelope = LauncherIPCEnvelope(
            kind: .ensembleArtifact,
            ensemble: EnsembleRequestPayload(
                verb: "artifact",
                workingDirectory: "/work",
                runIDs: ["run-a"],
                stepIndex: 9
            )
        )

        guard case .ensemble(.failure(let code, _)) = service.handle(envelope) else {
            Issue.record("Expected a typed failure")
            return
        }
        #expect(code == 65)
    }

    @Test("An unmatched workspace is unavailable 69")
    func unmatchedWorkspace() {
        let service = makeService(workspaces: [], eventCenter: quietEventCenter())
        guard
            case .ensemble(.failure(let code, let message)) =
                service.handle(statusEnvelope(directory: "/not/open"))
        else {
            Issue.record("Expected a typed failure")
            return
        }
        #expect(code == 69)
        #expect(message == "workspace not open in Rafu")
    }

    @Test("Status includes only events newer than --since")
    func eventsSinceCursor() throws {
        let session = WorkspaceSession()
        let center = quietEventCenter()
        center.publish(event(runID: "old"))
        center.publish(event(runID: "new"))
        let service = makeService(
            workspaces: [workspace(root: fileURL("/work"), session: session)],
            eventCenter: center
        )

        let result = try statusResult(
            service.handle(statusEnvelope(directory: "/work", sinceCursor: 1)))
        #expect(result.events.map(\.runID) == ["new"])
        #expect(result.cursor == 2)
    }

    @Test("Merged has highest precedence")
    func mergedPrecedence() {
        var value = manifest(id: "run", statuses: [.interrupted])
        value.mergedAt = Date()
        #expect(
            ConductorEnsembleRequestService.runState(
                manifest: value,
                liveState: .failed(
                    step: 0, reason: "failure")) == .merged
        )
    }

    @Test("Interrupted precedes failed")
    func interruptedPrecedence() {
        let value = manifest(id: "run", statuses: [.interrupted, .failed("failure")])
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .interrupted
        )
    }

    @Test("Failed precedes aborted")
    func failedPrecedence() {
        let value = manifest(id: "run", statuses: [.failed("failure"), .aborted])
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .failed
        )
    }

    @Test("Aborted precedes gates")
    func abortedPrecedence() {
        var value = manifest(id: "run", statuses: [.aborted, .awaitingGate])
        value.gate = .init(kind: .step, stepIndex: 1)
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .aborted
        )
    }

    @Test("Merge and step gates map distinctly")
    func gateMapping() {
        var value = manifest(id: "run")
        value.gate = .init(kind: .merge, stepIndex: 0)
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .awaitingMergeGate
        )
        value.gate = .init(kind: .step, stepIndex: 0)
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .awaitingGate
        )
    }

    @Test("Running precedes pending")
    func runningPrecedence() {
        let value = manifest(id: "run", statuses: [.running, .pending])
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .running
        )
    }

    @Test("Pending precedes completed")
    func pendingPrecedence() {
        let value = manifest(id: "run", statuses: [.completed, .pending])
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: nil)
                == .pending
        )
    }

    @Test("Only a fully completed run maps to completed")
    func completedState() {
        let value = manifest(id: "run", statuses: [.completed])
        #expect(
            ConductorEnsembleRequestService.runState(manifest: value, liveState: .completed)
                == .completed
        )
    }

    private func makeService(
        workspaces: [ConductorEnsembleRequestService.WorkspaceSnapshot],
        eventCenter: ConductorEnsembleEventCenter,
        liveState: @escaping (WorkspaceSession, String) -> ConductorWorkflowState? = {
            _, _ in nil
        }
    ) -> ConductorEnsembleRequestService {
        ConductorEnsembleRequestService(
            dependencies: .init(
                workspaces: { workspaces },
                liveState: liveState,
                eventCenter: eventCenter
            ))
    }

    private func workspace(
        root: URL,
        session: WorkspaceSession,
        isKey: Bool = false,
        order: Int = 0
    ) -> ConductorEnsembleRequestService.WorkspaceSnapshot {
        .init(
            rootURL: root,
            session: session,
            isKeyWindow: isKey,
            registrationOrder: order
        )
    }

    private func statusEnvelope(
        directory: String,
        tree: Bool = false,
        sinceCursor: UInt64? = nil
    ) -> LauncherIPCEnvelope {
        LauncherIPCEnvelope(
            kind: .ensembleStatus,
            ensemble: EnsembleRequestPayload(
                verb: "status",
                workingDirectory: directory,
                sinceCursor: sinceCursor,
                tree: tree
            )
        )
    }

    private func statusResult(_ response: LauncherIPCResponse) throws
        -> EnsembleStatusResult
    {
        guard case .ensemble(.status(let result)) = response else {
            throw StatusResultError.unexpectedResponse
        }
        return result
    }

    private func quietEventCenter() -> ConductorEnsembleEventCenter {
        ConductorEnsembleEventCenter(sleep: { _ in throw CancellationError() })
    }

    private func event(runID: String) -> EnsembleEvent {
        EnsembleEvent(
            cursor: 0,
            at: Date(timeIntervalSince1970: 1),
            runID: runID,
            kind: "state",
            state: .running
        )
    }

    private enum StatusResultError: Error {
        case unexpectedResponse
    }
}

private func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
}

private func manifest(
    id: String,
    statuses: [RunStepStatus] = [.pending],
    startedBy: String? = nil,
    evidencePath: String? = nil
) -> ConductorRunManifest {
    let binding = ConductorRunManifest.AgentBinding(
        provider: .codex,
        model: "gpt-5.6",
        autonomy: .worktreeWrite,
        adapterVersion: "1"
    )
    let steps = statuses.enumerated().map { index, status in
        ConductorRunManifest.Step(
            agentName: "worker-\(index)",
            binding: binding,
            inputArtifacts: [],
            handoffArtifact: "report.md",
            gateAfter: false,
            status: status,
            startedAt: nil,
            finishedAt: nil,
            attempt: 1,
            evidencePath: evidencePath
        )
    }
    return ConductorRunManifest(
        id: id,
        workflowName: "Workflow",
        baseCommit: "abc",
        worktreeBranch: "rafu/run-\(id)",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        steps: steps,
        startedBy: startedBy
    )
}
