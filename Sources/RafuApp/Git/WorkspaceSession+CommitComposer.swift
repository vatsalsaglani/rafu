import Foundation

extension WorkspaceSession {
    /// The commit composer's presentation for the current Git state, or nil
    /// with no repository. Read-only: it adds no Git behaviour.
    func commitComposerPresentation(isDescriptionFocused: Bool = false)
        -> GitCommitComposerPresentation?
    {
        guard let snapshot = gitSnapshot else { return nil }
        return GitCommitComposerPresentation(
            .init(
                message: gitCommitMessage,
                stagedCount: snapshot.stagedChanges.count,
                stageableCount: snapshot.unstagedChanges.count + snapshot.conflicts.count,
                branch: snapshot.isDetached ? nil : snapshot.branch,
                isMergeInProgress: gitMergeState != nil,
                isDrafting: isGeneratingAICommitMessage,
                isBusy: isGitBusy,
                isDescriptionFocused: isDescriptionFocused
            ))
    }
}
