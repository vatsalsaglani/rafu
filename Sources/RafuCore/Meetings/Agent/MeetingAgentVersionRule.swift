import Foundation

/// Reads a CLI version. No version is trusted by number: a probe
/// (`MeetingAgentProbing`) checks each CLI binary with fixed text before it
/// is offered, and keeps a ready result for one path, version, modification
/// date and argument revision. Claude Code is also checked at each run by
/// its init event (`ClaudeStreamParser`).
public enum MeetingAgentVersionRule {
    /// The version number in `--version` output, for example
    /// `codex-cli 0.171.0` → `0.171.0` and `2.1.330 (Claude Code)` → `2.1.330`.
    public static func version(fromVersionOutput output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for token in firstLine.split(separator: " ").reversed() {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 3, parts.count <= 4,
                parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
            {
                return String(token)
            }
        }
        return nil
    }
}
