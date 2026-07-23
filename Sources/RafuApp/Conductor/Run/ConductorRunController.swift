import Foundation
import Observation

/// Where a run stands from the UI's point of view. Pure and `nonisolated`
/// so the panel, the run-detail canvas, and the (future) notch companion can
/// all derive from it without touching the controller.
nonisolated enum ConductorRunState: Equatable, Sendable {
    /// No run has been started in this window.
    case idle
    case preparingWorktree
    case running(stepIndex: Int)
    /// Stopped at a user gate; the next step waits for explicit approval.
    case awaitingGate(stepIndex: Int)
    case completed
    case failed(String)
    case aborted
}

/// The run engine's window-level seam — STUB. C1 owns the real
/// implementation (`docs/plans/phases/conductor/C1-single-role-runs.md`):
/// worktree lifecycle, PTY execution through `TerminalProcessSpec`, handoff
/// capture, and the diff gate.
///
/// C0 lands ONLY the type, its observable state, and the persistence seam so
/// C1 adds files under `Conductor/Run/` without editing anything shared.
/// There is deliberately no `start()` here: nothing may execute until C1
/// implements the whole user-initiated, visible run (ADR 0018).
@Observable
@MainActor
final class ConductorRunController {
    private(set) var state: ConductorRunState = .idle
    /// The manifest of the run this controller is showing, once one exists.
    private(set) var manifest: ConductorRunManifest?

    /// Where run evidence is read from and written to. `nil` until a
    /// workspace with a root is attached.
    @ObservationIgnored
    private(set) var store: ConductorRunStore?

    /// The adapters this controller may use. Injectable so C1's tests can
    /// substitute `FakeConductorAdapter` for a provider without touching the
    /// shared registry.
    @ObservationIgnored
    let adapters: [any ConductorCLIAdapter]

    init(adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all) {
        self.adapters = adapters
    }

    func adapter(for id: ConductorCLIID) -> (any ConductorCLIAdapter)? {
        adapters.first { $0.id == id }
    }

    /// Points the controller at a workspace. Deliberately does NOT seed
    /// `.rafu/` — Rafu must not write into a user's repository merely
    /// because a folder opened (see `RafuDotDirectory.seed()`); C1 seeds
    /// from the run-start path.
    func attach(workspaceRoot: URL?) {
        store = workspaceRoot.map { ConductorRunStore(workspaceRoot: $0) }
    }

    /// Loads a persisted run for display. Reading evidence is safe and
    /// user-initiated; it starts nothing.
    func showRun(id: String) async throws {
        guard let store else { return }
        manifest = try await store.load(runID: id)
    }
}
