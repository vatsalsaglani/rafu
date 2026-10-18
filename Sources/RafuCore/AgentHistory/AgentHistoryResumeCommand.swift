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
