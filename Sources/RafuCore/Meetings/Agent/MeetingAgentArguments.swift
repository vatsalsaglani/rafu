import Foundation

/// The one place that builds the argument arrays of the hidden meeting
/// agent (the decision record about a meeting agent with no visible
/// terminal, ADR 0046). Each array is a copy of the checked array in
/// `docs/references/meeting-hidden-agent-limits.md`; a test compares them
/// element by element. Change an array only after the check in that note
/// was run again for the new CLI version.
///
/// No array holds a question, a title, a name or transcript text. The
/// Claude Code prompt is a fixed text (`MeetingAgentPrompts`), and the Codex
/// packet goes on standard input (the last argument `-`).
public enum MeetingAgentArguments {
    /// The revision of the arrays below. A ready probe result is kept for
    /// one revision: a change to an array probes each CLI again.
    public static let revision = 2

    /// Claude Code 2.1.330, "Selected (Restricted, safe mode)", with
    /// `--include-partial-messages` after `--verbose` so the answer streams.
    /// The working directory is the frozen meeting copy; standard input is
    /// `/dev/null`.
    public static func claude(prompt: String) -> [String] {
        [
            "-p", prompt, "--model", "haiku", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--no-session-persistence",
            "--tools=Read,Glob,Grep", "--permission-mode", "dontAsk", "--permission-prompts",
            "none", "--strict-mcp-config",
            "--disable-slash-commands", "--no-chrome", "--max-budget-usd", "0.50", "--restricted",
            "--safe-mode",
        ]
    }

    /// Codex 0.171.0, "Codex with the meeting text on standard input",
    /// "Final argument array". `emptyFolder` is `<E>`: a new empty folder
    /// (mode 0700) inside a private run root, also the working directory.
    public static func codex(emptyFolder: URL) -> [String] {
        [
            "exec", "--model", "gpt-6-luna", "--cd", emptyFolder.path, "--skip-git-repo-check",
            "--json", "--ephemeral",
            "--ignore-user-config", "--ignore-rules",
            "-c", "default_permissions=\"meeting\"",
            "-c",
            "permissions.meeting.filesystem={\":minimal\"=\"read\", \":workspace_roots\"={\".\"=\"read\"}, \":slash_tmp\"=\"deny\", \":tmpdir\"=\"deny\", \"/private/var/tmp\"=\"deny\"}",
            "-c", "permissions.meeting.network.enabled=false",
            "--disable=shell_tool",
            "--disable=apps", "--disable=plugins", "--disable=hooks", "--disable=browser_use",
            "--disable=computer_use",
            "--disable=in_app_browser", "--disable=skill_search", "--disable=tool_suggest",
            "--disable=shell_snapshot",
            "--disable=multi_agent", "--disable=image_generation", "--disable=goals",
            "-c", "web_search=\"disabled\"", "-c", "agents.enabled=false",
            "-c", "skills.include_instructions=false", "--disable=view_image",
            "--disable=sleep_tool",
            "-",
        ]
    }

    /// The version probe (`codex --version`). It holds no private text.
    public static let versionProbe = ["--version"]
}
