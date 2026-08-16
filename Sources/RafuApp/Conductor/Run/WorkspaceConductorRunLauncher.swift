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

        // Capacity must fail before opening a run, so a rejected role never
        // publishes a partial running selection.
        let reservation = try workspaceSession.reserveTerminalLiveSessionCapacity(1)
        var insertedID: UUID?
        do {
            // Opening the run installs the terminal's shared exit/attention
            // handlers before classified insertion wires the controller to them.
            workspaceSession.openConductorRun(runID)
            var sessionID: UUID?
            let session = try workspaceSession.insertClassifiedTerminalSession(
                spec: specification,
                kind: .ensembleRole,
                lifecycle: { [weak workspaceSession] in
                    guard
                        let workspaceSession,
                        let sessionID,
                        let controller = workspaceSession.terminal.sessions.first(where: {
                            $0.id == sessionID
                        })
                    else { return }
                    let exitCode: Int32?
                    if case .exited(let code) = controller.status {
                        exitCode = code
                    } else {
                        exitCode = nil
                    }
                    onExit(sessionID, exitCode)
                },
                reservation: reservation)
            insertedID = session
            sessionID = session
            try workspaceSession.consumeTerminalLiveSessionCapacity(reservation)
            return session
        } catch {
            if let insertedID {
                workspaceSession.ownerHandledTerminalLifecycleClose(insertedID)
            }
            try? workspaceSession.cancelTerminalLiveSessionCapacity(reservation)
            throw error
        }
    }

    func terminate(sessionID: UUID) {
        workspaceSession?.ownerHandledTerminalLifecycleClose(sessionID)
    }
}
