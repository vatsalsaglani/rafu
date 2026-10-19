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
    /// Exact keys removed regardless of prefix.
    private static let exactKeys: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"]
    /// Every key starting with this prefix describes the launching Claude
    /// Code session (its socket, token, entrypoint, exec path, bridge/
    /// session ids) and is removed. Ordinary user configuration such as
    /// `ANTHROPIC_*` or `CLAUDE_CONFIG_DIR` does NOT use this prefix and is
    /// kept.
    private static let removedPrefix = "CLAUDE_CODE_"

    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !exactKeys.contains(key) && !key.hasPrefix(removedPrefix)
        }
    }
}
