import Foundation
import RafuCore

// Owned by the meeting questions and name suggestions package. `MeetingsFeature.registerBuiltInParts()`
// calls this function; the package registers its parts here with
// `register(_:)` and never edits `MeetingsFeature.swift`.
extension MeetingsFeature {
    /// Registers the hidden meeting agent on a Mac that can use Meetings.
    /// Making the runner starts no process; a run starts only when the
    /// interface calls `ask` or `suggestSpeakerNames` on a user action.
    func registerAgentParts(runsRoot: URL = MeetingAgentRunFolders.defaultRunsRoot) {
        guard availability.isAvailable else { return }
        register(
            .agentRunner(
                MeetingAgentRunner(
                    store: { @MainActor [weak self] in self?.store },
                    diagnostics: diagnostics, runsRoot: runsRoot)))

        // Folders left by a crash: run roots and snapshots older than 1 hour.
        let store = store as? MeetingStore
        Task.detached(priority: .utility) {
            MeetingAgentRunFolders.removeStale(in: runsRoot, olderThan: 3_600)
            await store?.removeStaleSnapshots(olderThan: 3_600)
        }
    }
}
