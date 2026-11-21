import Foundation
import RafuCore

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
///
/// The same holds for Rafu's own terminal state. Rafu can be started from another
/// Rafu terminal, so the app can inherit that terminal's wrapper folder in `PATH`
/// and its `RAFU_CANVAS_*` keys. A new Ensemble terminal gets fresh ones, so the
/// scrub drops the inherited ones. A wrapper folder left in `PATH` made the
/// launcher start the other terminal's wrapper in a loop.
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

    /// Key prefix of the per-terminal Ensemble bridge state. The bootstrap sets fresh values.
    private static let ensembleKeyPrefix = "RAFU_CANVAS_"

    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        var result = environment.filter { key, _ in
            !hostSessionKeys.contains(key) && !key.hasPrefix(ensembleKeyPrefix)
                && key != "MCP_PROTOCOL_NEGOTIATION"
        }
        if let path = result["PATH"] {
            result["PATH"] = path.split(separator: ":", omittingEmptySubsequences: false)
                .filter { entry in
                    let name = entry.split(separator: "/").last.map(String.init) ?? ""
                    return !name.hasPrefix(CanvasBridgeLaunch.wrapperDirectoryPrefix)
                }
                .joined(separator: ":")
        }
        return result
    }
}
