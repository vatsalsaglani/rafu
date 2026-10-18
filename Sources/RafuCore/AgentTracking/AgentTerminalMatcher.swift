import Foundation

/// One Rafu terminal, reduced to what matching needs.
public struct AgentTerminalCandidate: Equatable, Sendable {
    public let id: UUID
    /// The terminal's shell (or directly spawned agent) PID while it runs.
    public let processID: Int32?
    /// The live OSC 7 directory, else the starting directory.
    public let cwd: String?
    /// The agent the terminal runs, when Rafu knows it.
    public let provider: AgentHookProvider?

    public init(id: UUID, processID: Int32?, cwd: String?, provider: AgentHookProvider?) {
        self.id = id
        self.processID = processID
        self.cwd = cwd
        self.provider = provider
    }
}

/// Matches observed agent sessions to Rafu terminals.
///
/// 1. Process tree (strong): the hook helper records its parent PID chain;
///    a session belongs to the terminal whose PID is in that chain.
/// 2. Folder (weak): only for a session with no recorded chain, the newest
///    session of the same provider whose folder equals the terminal's.
///
/// A session with a chain that holds no terminal's PID runs elsewhere
/// (another terminal app or an editor), so the folder rule never claims it.
public enum AgentTerminalMatcher {
    /// The newest live (not ended) session that belongs to `terminal`.
    public static func session(
        for terminal: AgentTerminalCandidate,
        in sessions: [TrackedAgentSession]
    ) -> TrackedAgentSession? {
        let live = sessions.filter { $0.state != .ended }
        if let pid = terminal.processID, pid > 1 {
            let byProcess = live.filter { $0.ancestorProcessIDs.contains(pid) }
            if let newest = newest(byProcess) { return newest }
        }
        guard let cwd = terminal.cwd.map(normalized), !cwd.isEmpty,
            let provider = terminal.provider
        else { return nil }
        return newest(
            live.filter {
                $0.ancestorProcessIDs.isEmpty && $0.provider == provider
                    && normalized($0.cwd) == cwd
            })
    }

    /// Live sessions that no terminal in `terminals` owns and that do not
    /// descend from `appProcessID` (Rafu itself). These run outside Rafu.
    public static func externalSessions(
        _ sessions: [TrackedAgentSession],
        terminals: [AgentTerminalCandidate],
        appProcessID: Int32?
    ) -> [TrackedAgentSession] {
        let owned = Set(terminals.compactMap { session(for: $0, in: sessions)?.id })
        return sessions.filter { row in
            guard row.state != .ended, !owned.contains(row.id) else { return false }
            if let appProcessID, row.ancestorProcessIDs.contains(appProcessID) { return false }
            return true
        }
    }

    static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var result = URL(fileURLWithPath: path).standardizedFileURL.path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func newest(_ rows: [TrackedAgentSession]) -> TrackedAgentSession? {
        rows.max { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.id > rhs.id : lhs.updatedAt < rhs.updatedAt
        }
    }
}
