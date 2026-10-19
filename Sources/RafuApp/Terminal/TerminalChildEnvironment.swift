import Foundation

/// Scrubs host-session identifiers out of an environment headed for a
/// terminal child process.
///
/// A terminal's shell (and any agent CLI started inside it) begins a new,
/// top-level session. When Rafu itself was launched from inside an agent
/// session — e.g. Rafu Lightning started from a Claude Code terminal — the
/// app process inherits that agent's own session variables. Those describe
/// the process that launched Rafu, not the PTY child being started now, so
/// forwarding them makes the child believe it is a nested/child session of
/// an agent that is not actually its parent (same reasoning as the NO_COLOR
/// removal in `CanvasTerminalBootstrap.prepare`).
nonisolated struct TerminalChildEnvironment {
    /// The keys a running Claude Code session sets for its own children: its
    /// socket, token, entrypoint, exec path, and bridge/session ids. An exact
    /// list, not a `CLAUDE_CODE_` prefix: user configuration also uses that
    /// prefix (for example `CLAUDE_CODE_USE_BEDROCK` set through
    /// `launchctl setenv`) and must reach the child, as must `ANTHROPIC_*`
    /// and `CLAUDE_CONFIG_DIR`.
    static let hostSessionKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
    ]

    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !hostSessionKeys.contains(key) }
    }
}
