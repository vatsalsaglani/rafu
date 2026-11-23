import Foundation
import RafuCore

// Owned by the meeting questions and name suggestions package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    /// Registers the hidden meeting agent on a Mac that can use Meetings.
    /// Making the runner starts no process; a run starts only when the
    /// interface calls `ask` or `suggestSpeakerNames` on a user action.
    func registerAgentParts(
        runsRoot: URL = MeetingAgentRunFolders.defaultRunsRoot,
        snapshotRoot: URL = MeetingAgentRunFolders.defaultSnapshotRoot
    ) {
        guard availability.isAvailable else { return }
        let session = session
        register(
            .agentRunner(
                MeetingAgentRunner(
                    store: { @MainActor [weak self] in self?.store },
                    diagnostics: diagnostics, runsRoot: runsRoot,
                    activity: { @MainActor [weak session] meeting, activity, isRunning in
                        session?.noteAgentRun(activity, of: meeting, isRunning: isRunning)
                    })))

        // Both roots carry the app variant in their name, so these
        // folders belong to this variant only, and no run of it lives
        // across a launch: remove each one now (a crash left them), and at
        // quit after the processes ended.
        Task.detached(priority: .utility) {
            MeetingAgentRunFolders.removeAll(in: runsRoot)
            MeetingAgentRunFolders.removeAll(in: snapshotRoot)
        }
        let registry = MeetingAgentProcessRegistry.shared
        registry.addQuitCleanup {
            MeetingAgentRunFolders.removeAll(in: runsRoot)
            MeetingAgentRunFolders.removeAll(in: snapshotRoot)
        }
        registry.observeQuit()
    }
}
