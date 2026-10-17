import Foundation

/// The AppKit delegate cannot await a save before returning. Keep one pending
/// reply and return `.terminateLater` there; send its reply after these saves.
@MainActor
final class WorkspaceTerminationPersistence {
    private var task: Task<Void, Never>?
    private let closeSaveTracker: WorkspaceCloseSaveTracker

    init(closeSaveTracker: WorkspaceCloseSaveTracker = .shared) {
        self.closeSaveTracker = closeSaveTracker
    }

    /// Sessions arrive in registry priority order (key window first). The
    /// shared restoration preference holds one workspace, so save in reverse
    /// order and finish with the highest-priority workspace. Do not close tabs,
    /// write document contents, or tear down processes while saving metadata.
    @discardableResult
    func request(
        sessions: [WorkspaceSession], reply: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        if let task { return task }
        // Enter before creating the task, so a close during any following
        // await cannot start another write after the final live save.
        closeSaveTracker.beginQuit()
        let save = Task(name: "Flush restoration before app quit") {
            [weak self, closeSaveTracker] in
            // Keep the barrier through AppKit's synchronous reply. If the
            // callback returns without quitting, normal close saves resume.
            defer { closeSaveTracker.endQuit() }
            // A closed window can still own a slow bookmark/save on another
            // actor. Drain those tasks before writing the live windows.
            await closeSaveTracker.drain()
            for session in sessions.dropFirst().reversed() {
                await closeSaveTracker.drain()
                await session.flushWorkspaceState()?.value
            }
            if let prioritySession = sessions.first {
                await closeSaveTracker.drainBeforeFinalSave {
                    await prioritySession.flushWorkspaceState()?.value
                }
            }
            self?.task = nil
            reply()
        }
        task = save
        return save
    }
}
