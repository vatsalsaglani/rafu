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
    /// Short human-readable name for this Ensemble, supplied by the New
    /// Ensemble canvas's name field. Additive with a default so every
    /// existing construction site — and the synthesized memberwise init —
    /// keeps compiling; `nil` falls back to `goal` wherever a coordinator is
    /// titled. It is the coordinator-side twin of
    /// `ConductorRunManifest.label`/`ConductorWorkflowRunRequest.label`, not
    /// a parallel naming mechanism.
    var label: String? = nil

    /// This Ensemble's per-provider model preference: "if a child run binds a
    /// role to Codex and that role names no model of its own, use this one".
    /// Keyed by CLI, so one vendor's model string can never be read for
    /// another vendor's CLI — the structural equivalent of the coordinator
    /// field's unconditional reset on provider switch.
    ///
    /// **Deliberately NOT part of `ConductorEnsembleGrant`.** The grant
    /// crosses into RafuCore and is enforced as a *permission* boundary
    /// (ADR 0018 and its consent amendment): `allowedProviders` answers "may
    /// the coordinator reach this vendor at all", and a violation is exit 77.
    /// A model is a launch *preference* — declining it changes which model
    /// runs, never whether the run is authorized. Putting it in the grant
    /// would conflate the two and widen a security-reviewed contract for a
    /// display feature, so it rides alongside the grant on the Rafu-side
    /// coordinator record instead. Nothing here is transmitted to the CLI;
    /// the child process still receives only the opaque token.
    var providerModelDefaults: [ConductorCLIID: String] = [:]

    /// What to show the user for this coordinator: its name when it has one,
    /// otherwise the goal text the graph has always shown.
    var displayTitle: String {
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return goal
        }
        return label
    }
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
        label: String? = nil,
        providerModelDefaults: [ConductorCLIID: String] = [:],
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
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinatorSession = ConductorCoordinatorSession(
            id: coordinatorID,
            provider: provider,
            model: trimmedModel?.isEmpty == false ? trimmedModel : nil,
            goal: goal,
            terminalSessionID: terminalController.id,
            startedAt: clock(),
            endedAt: nil,
            label: trimmedLabel?.isEmpty == false ? trimmedLabel : nil,
            // Trimmed and empty-dropped here so "" — the established
            // not-set value — never reaches the resolver as a model named
            // "" and is never handed to a CLI as `--model ''`.
            providerModelDefaults: providerModelDefaults.compactMapValues {
                ConductorModelResolution.normalized($0)
            }
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
