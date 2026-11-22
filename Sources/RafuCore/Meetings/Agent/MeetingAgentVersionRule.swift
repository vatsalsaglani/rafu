import Foundation

/// Which CLI versions the hidden meeting agent trusts. Codex shows no tool
/// list in its event stream, so Rafu cannot check its limit at run time:
/// only a version that passed the check of
/// `meeting-hidden-agent-limits.md` is offered. Claude Code is checked at
/// each run by its init event (`ClaudeStreamParser`), not by version.
public enum MeetingAgentVersionRule {
    public static let checkedCodexVersions: Set<String> = ["0.171.0"]

    /// The version number in `codex --version` output, for example
    /// `codex-cli 0.171.0` → `0.171.0`.
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

    public static func isSupportedCodex(version: String?) -> Bool {
        guard let version else { return false }
        return checkedCodexVersions.contains(version)
    }
}
