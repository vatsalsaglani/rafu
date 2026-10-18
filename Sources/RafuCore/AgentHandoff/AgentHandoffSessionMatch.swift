import Foundation

extension AgentHistoryIndex {
    /// The newest session of `provider` that ran in one of `folders`. Used by
    /// the Ensemble "Hand off" action: a terminal card names a folder and an
    /// agent, and History holds the sessions. The match is by normalized
    /// path equality, so a session in a subfolder does not match.
    public func newestSession(
        provider: AgentHistoryProvider, inFolders folders: [String]
    ) -> AgentHistorySessionSummary? {
        let wanted = Set(folders.map(AgentHistoryPath.normalized).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        return sessions.first { session in
            guard session.provider == provider, let path = session.projectPath else {
                return false
            }
            return wanted.contains(AgentHistoryPath.normalized(path))
        }
    }
}
