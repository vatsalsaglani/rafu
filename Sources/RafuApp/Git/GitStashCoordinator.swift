import Foundation

/// Loads the cheap stash summary outside `GitInspectorView`'s body while the
/// G0 contract keeps `WorkspaceSession.refreshGit()` frozen for lane fan-out.
@MainActor
enum GitStashCoordinator {
    static func refresh(session: WorkspaceSession) async {
        guard let rootURL = session.rootURL, !session.isGitBusy else { return }
        do {
            let stashes = try await GitService().stashList(at: rootURL)
            guard session.rootURL == rootURL else { return }
            session.gitStashes = stashes
        } catch is CancellationError {
            return
        } catch {
            guard session.rootURL == rootURL else { return }
            session.reportGitError(error)
        }
    }
}
