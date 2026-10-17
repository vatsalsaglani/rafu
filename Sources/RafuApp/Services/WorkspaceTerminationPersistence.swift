import Foundation

/// The AppKit delegate cannot await a save before returning. Keep one pending
/// reply and return `.terminateLater` there; send its reply after these saves.
@MainActor
final class WorkspaceTerminationPersistence {
    nonisolated private struct Metadata: Equatable {
        let root: URL?
        let layout: EditorLayoutState
        let navigator: WorkspaceNavigatorMode
        let selectedDocumentID: UUID?
        let files: [URL]
        let canvases: Set<CanvasID>
    }
    private static func metadata(_ session: WorkspaceSession) -> Metadata {
        .init(
            root: session.rootURL, layout: session.editorLayout,
            navigator: session.navigatorMode, selectedDocumentID: session.selectedDocumentID,
            files: session.openDocuments.map(\.url), canvases: Set(session.canvas.savedIDs))
    }
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
        sessions: [WorkspaceSession], onSaveFailure: (@MainActor () -> Void)? = nil,
        reply: @escaping @MainActor () -> Void
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
            // Each repeat consumes edits made during an awaited content or
            // metadata write. It is not a timer or a poll. Reply only after a
            // final synchronous check sees stable metadata and no dirty board.
            while true {
                for session in sessions {
                    guard await session.canvas.flushAll() else {
                        self?.task = nil
                        session.revealCanvasSaveFailure()
                        onSaveFailure?()
                        return
                    }
                }
                let before = sessions.map(Self.metadata)
                // A closed window can still own a slow bookmark/save. Drain
                // those tasks before the live windows; the key window stays last.
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
                for session in sessions { session.canvas.refreshResourceSnapshots() }
                if !sessions.contains(where: { $0.canvas.hasPendingWrites }),
                    before == sessions.map(Self.metadata)
                {
                    break
                }
            }
            self?.task = nil
            reply()
        }
        task = save
        return save
    }
}
