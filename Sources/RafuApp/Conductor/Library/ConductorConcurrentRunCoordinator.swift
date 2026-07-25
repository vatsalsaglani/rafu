import Foundation
import Observation

nonisolated enum ConductorConcurrentRunError: Error, Equatable, LocalizedError, Sendable {
    case activeLimitReached(limit: Int)
    case runAlreadyExists(String)
    case worktreeAlreadyClaimed
    case workspaceChanged

    var errorDescription: String? {
        switch self {
        case .activeLimitReached(let limit):
            "This window already has \(limit) active Ensemble runs. Finish or abort one before starting another."
        case .runAlreadyExists:
            "A run with this identifier already exists in this window."
        case .worktreeAlreadyClaimed:
            "Another active Ensemble run already owns this worktree."
        case .workspaceChanged:
            "The workspace changed while the Ensemble run was starting."
        }
    }
}

/// One window's bounded collection of C5 controllers. Registering the
/// controller before the first suspension makes a run ID an actor-isolated
/// reservation; C1's run-ID-derived worktree path then guarantees distinct
/// mutating requests receive distinct worktrees.
@Observable
@MainActor
final class ConductorConcurrentRunCoordinator {
    let activeLimit: Int
    private(set) var controllersByRunID: [String: ConductorWorkflowController] = [:]

    @ObservationIgnored
    private let runsPublisher: ConductorRunController

    @ObservationIgnored
    private let adapters: [any ConductorCLIAdapter]

    @ObservationIgnored
    private var workspaceRoot: URL?

    @ObservationIgnored
    private var attachmentGeneration = UUID()

    init(
        runsPublisher: ConductorRunController,
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        activeLimit: Int = 3
    ) {
        precondition(activeLimit > 0)
        self.runsPublisher = runsPublisher
        self.adapters = adapters
        self.activeLimit = activeLimit
    }

    var controllers: [ConductorWorkflowController] {
        controllersByRunID.keys.sorted().compactMap { controllersByRunID[$0] }
    }

    var activeControllers: [ConductorWorkflowController] {
        controllers.filter(\.isInFlight)
    }

    var activeCount: Int { activeControllers.count }

    func attach(workspaceRoot: URL?) {
        let standardized = workspaceRoot?.standardizedFileURL
        guard standardized != self.workspaceRoot else { return }
        for controller in controllers {
            if controller.isInFlight {
                controller.abort()
            }
        }
        controllersByRunID = [:]
        self.workspaceRoot = standardized
        attachmentGeneration = UUID()
    }

    @discardableResult
    func start(
        _ request: ConductorWorkflowRunRequest,
        launcher: any ConductorRunProcessLaunching
    ) async throws -> ConductorWorkflowController {
        guard controllersByRunID[request.runID] == nil else {
            throw ConductorConcurrentRunError.runAlreadyExists(request.runID)
        }
        guard activeCount < activeLimit else {
            throw ConductorConcurrentRunError.activeLimitReached(limit: activeLimit)
        }
        let generation = attachmentGeneration

        let controller = ConductorWorkflowController(
            runsPublisher: runsPublisher,
            adapters: adapters)
        controller.attach(workspaceRoot: workspaceRoot)
        controllersByRunID[request.runID] = controller

        await controller.start(request, launcher: launcher)
        guard
            attachmentGeneration == generation,
            controllersByRunID[request.runID] === controller
        else {
            controller.abort()
            throw ConductorConcurrentRunError.workspaceChanged
        }
        try verifyUniqueWorktree(for: controller, runID: request.runID)
        return controller
    }

    func controller(runID: String) -> ConductorWorkflowController? {
        controllersByRunID[runID]
    }

    func removeFinishedRuns() {
        controllersByRunID = controllersByRunID.filter { _, controller in
            switch controller.state {
            case .completed, .aborted:
                false
            case .idle, .preparing, .runningStep, .awaitingArtifact, .awaitingGate,
                .awaitingMergeGate, .failed:
                true
            }
        }
    }

    private func verifyUniqueWorktree(
        for controller: ConductorWorkflowController,
        runID: String
    ) throws {
        guard let worktree = controller.plan?.worktreeURL?.standardizedFileURL else { return }
        let hasCollision = controllersByRunID.contains { otherRunID, otherController in
            otherRunID != runID
                && otherController.plan?.worktreeURL?.standardizedFileURL == worktree
        }
        guard !hasCollision else {
            controller.abort()
            controllersByRunID.removeValue(forKey: runID)
            throw ConductorConcurrentRunError.worktreeAlreadyClaimed
        }
    }
}
