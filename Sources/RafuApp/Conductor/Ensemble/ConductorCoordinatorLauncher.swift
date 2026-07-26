import Foundation
import RafuCore

nonisolated struct ConductorCoordinatorSession: Identifiable, Sendable {
    let id: String
    let provider: ConductorCLIID
    let model: String?
    let goal: String
    let terminalSessionID: UUID?
    let startedAt: Date
    var endedAt: Date?
}

nonisolated enum ConductorCoordinatorLaunchError: Error, Equatable, LocalizedError, Sendable {
    case workspaceUnavailable
    case providerUnavailable(ConductorCLIID)
    case notAuthenticated(ConductorCLIID, String)

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "Open a local workspace before starting an Ensemble coordinator."
        case .providerUnavailable(let provider):
            "\(provider.displayName) is not installed or could not be resolved."
        case .notAuthenticated(let provider, let hint):
            "\(provider.displayName) is not authenticated. \(hint)"
        }
    }
}

@MainActor
struct ConductorCoordinatorLauncher {
    typealias Clock = @MainActor () -> Date
    typealias CoordinatorID = @MainActor () -> String

    private let adapters: [any ConductorCLIAdapter]
    private let tokenStore: ConductorEnsembleTokenStore
    private let eventCenter: ConductorEnsembleEventCenter
    private let roleLaunchService: ConductorRoleLaunchService
    private let clock: Clock
    private let makeCoordinatorID: CoordinatorID

    init(
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        tokenStore: ConductorEnsembleTokenStore = .shared,
        eventCenter: ConductorEnsembleEventCenter = .shared,
        roleLaunchService: ConductorRoleLaunchService = ConductorRoleLaunchService(),
        clock: @escaping Clock = Date.init,
        makeCoordinatorID: @escaping CoordinatorID = {
            let suffix = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(8)
            return "co-" + String(suffix)
        }
    ) {
        self.adapters = adapters
        self.tokenStore = tokenStore
        self.eventCenter = eventCenter
        self.roleLaunchService = roleLaunchService
        self.clock = clock
        self.makeCoordinatorID = makeCoordinatorID
    }

    func start(
        provider: ConductorCLIID,
        model: String?,
        goal: String,
        grant: ConductorEnsembleGrant,
        in session: WorkspaceSession
    ) async throws -> ConductorCoordinatorSession {
        guard let workspaceRoot = session.rootURL else {
            throw ConductorCoordinatorLaunchError.workspaceUnavailable
        }
        guard let adapter = adapters.first(where: { $0.id == provider }) else {
            throw ConductorCoordinatorLaunchError.providerUnavailable(provider)
        }

        let resolved: ConductorResolvedAdapter
        do {
            resolved = try await roleLaunchService.resolve(adapter)
        } catch {
            throw ConductorCoordinatorLaunchError.providerUnavailable(provider)
        }
        try Task.checkCancellation()
        switch await adapter.authStatus() {
        case .authenticated, .unknown:
            break
        case .notAuthenticated(let hint):
            throw ConductorCoordinatorLaunchError.notAuthenticated(provider, hint)
        }
        try Task.checkCancellation()

        let coordinatorID = makeCoordinatorID()
        let token = tokenStore.mint(coordinatorID: coordinatorID, grant: grant)
        let shape = AgentTerminalLaunchShape.forCLI(provider)
        let processSpec = TerminalProcessSpec(
            executableURL: resolved.executableURL,
            arguments: shape.arguments(model: model),
            currentDirectoryPath: workspaceRoot.standardizedFileURL.path,
            environment: [
                RafuConductorEnvironment.path: RafuConductorEnvironment.curatedPath,
                "RAFU_ENSEMBLE_TOKEN": token,
            ],
            roleBadge: "Coordinator",
            outputLogURL: nil,
            resourceAttribution: "coordinator • \(provider.displayName)"
        )

        let terminalController = session.terminal.newSession(spec: processSpec)
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinatorSession = ConductorCoordinatorSession(
            id: coordinatorID,
            provider: provider,
            model: trimmedModel?.isEmpty == false ? trimmedModel : nil,
            goal: goal,
            terminalSessionID: terminalController.id,
            startedAt: clock(),
            endedAt: nil
        )
        session.registerCoordinatorSession(coordinatorSession) {
            tokenStore.revoke(coordinatorID: coordinatorID)
            eventCenter.publish(
                EnsembleEvent(
                    cursor: 0,
                    at: clock(),
                    runID: coordinatorID,
                    kind: "state",
                    state: .completed,
                    startedBy: coordinatorID
                ))
        }

        let sharedExitHandler = terminalController.onExit
        terminalController.onExit = { [weak session] terminalID, exitCode in
            sharedExitHandler?(terminalID, exitCode)
            session?.coordinatorSessionDidEnd(coordinatorID)
        }
        session.revealTerminalSession(terminalController.id)
        return coordinatorSession
    }
}
