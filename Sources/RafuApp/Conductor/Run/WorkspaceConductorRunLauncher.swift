import Foundation

nonisolated enum WorkspaceConductorRunLauncherError:
    Error, Equatable, LocalizedError, Sendable
{
    case workspaceReleased
    case readOnlyHandoffUnsupported(reason: String)

    var errorDescription: String? {
        switch self {
        case .workspaceReleased:
            "The workspace closed before Rafu could start the Ensemble role."
        case .readOnlyHandoffUnsupported(let reason):
            reason
        }
    }
}

/// Presents one Conductor process through the workspace's existing terminal
/// manager. The terminal controller remains the sole PTY owner, so role
/// badges, attention signals, natural exit, and ProcessResourceRegistry
/// registration all use the same path as an ordinary terminal tab.
@MainActor
final class WorkspaceConductorRunLauncher: ConductorRunProcessLaunching {
    private weak var workspaceSession: WorkspaceSession?
    private let runID: String

    init(workspaceSession: WorkspaceSession, runID: String) {
        self.workspaceSession = workspaceSession
        self.runID = runID
    }

    func launch(
        specification: TerminalProcessSpec,
        onExit: @escaping @MainActor @Sendable (UUID, Int32?) -> Void
    ) throws -> UUID {
        if let reason = specification.environment[
            RafuConductorEnvironment.readOnlyHandoffUnsupportedReason
        ] {
            throw WorkspaceConductorRunLauncherError.readOnlyHandoffUnsupported(reason: reason)
        }
        guard let workspaceSession else {
            throw WorkspaceConductorRunLauncherError.workspaceReleased
        }

        // Opening the run installs the terminal's shared exit/attention
        // handlers before `newSession(spec:)` wires this controller to them.
        workspaceSession.openConductorRun(runID)
        let controller = workspaceSession.terminal.newSession(spec: specification)
        let sharedExitHandler = controller.onExit
        controller.onExit = { sessionID, exitCode in
            sharedExitHandler?(sessionID, exitCode)
            onExit(sessionID, exitCode)
        }
        workspaceSession.revealTerminalSession(controller.id)
        return controller.id
    }

    func terminate(sessionID: UUID) {
        workspaceSession?.closeTerminalSession(sessionID)
    }
}
