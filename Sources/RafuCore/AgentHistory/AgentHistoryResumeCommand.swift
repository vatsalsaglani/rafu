import Foundation

/// The command that resumes a session in its own CLI. It is built as an
/// argument array and turned into one shell line with POSIX single quoting,
/// so no value from a transcript is ever interpreted by the shell.
public enum AgentHistoryResumeCommand {
    /// `claude --resume <id>` or `codex resume <id>`. `nil` when the session
    /// id holds anything except letters, digits, `-`, `_`, and `.` — such an
    /// id did not come from the CLI, and Rafu does not type it.
    public static func arguments(for key: AgentHistorySessionKey) -> [String]? {
        guard isSafeSessionID(key.sessionID) else { return nil }
        switch key.provider {
        case .claudeCode:
            return ["claude", "--resume", key.sessionID]
        case .codex:
            return ["codex", "resume", key.sessionID]
        }
    }

    /// `arguments(for:)` plus model, effort and mode flags, so History
    /// "Resume" and `agent_configure` build the same argument vector. `nil`
    /// when the session id is not safe or a value fails its allowlist
    /// (`CanvasAgentConfigurePlan.validate`). Claude: `--model`, `--effort`,
    /// `--permission-mode`. Codex: `-c model="…"`,
    /// `-c model_reasoning_effort="…"`, `-c sandbox_mode="…"` after
    /// `resume <id>`.
    public static func arguments(
        for key: AgentHistorySessionKey, model: String?, effort: String?, mode: String?
    ) -> [String]? {
        guard var arguments = arguments(for: key) else { return nil }
        let agent = CanvasAgentConfigureAgent(historyProvider: key.provider)
        let request = CanvasAgentConfigureRequest(model: model, effort: effort, mode: mode)
        if !request.isEmpty {
            do {
                try CanvasAgentConfigurePlan.validate(request, agent: agent)
            } catch {
                return nil
            }
        }
        arguments += agent.flags(model: model, effort: effort, resume: true)
        arguments += agent.modeFlags(mode)
        return arguments
    }

    /// One shell line for `arguments`, without a trailing newline.
    public static func shellLine(_ arguments: [String]) -> String {
        arguments.map(quoted).joined(separator: " ")
    }

    /// POSIX single quoting. Plain words stay as they are; everything else is
    /// wrapped in `'…'`, with each `'` written as `'\''`.
    public static func quoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let plain = argument.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": true
            case "-", "_", ".", "/", ":", "=", "@", "%", "+", ",": true
            default: false
            }
        }
        if plain { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isSafeSessionID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix("-") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": true
            default: false
            }
        }
    }
}
