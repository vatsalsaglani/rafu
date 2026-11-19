import Foundation

// Full access for a Codex agent in an Ensemble terminal: Codex runs commands
// with no approval prompt and no sandbox. Off by default. The user turns it on
// with the Settings switch "Allow Full access agents"; every request still
// asks, and the terminal node shows a "Full access" badge. Pure: values,
// policy and argument rewriting only. Decision record: "Full access agents in
// Ensemble terminals". Reference: docs/references/codex-full-access.md.

public nonisolated enum CanvasAgentFullAccess {
    /// `terminal_create` `access` values.
    public static let defaultAccess = "default"
    public static let fullAccess = "full"
    public static let accessValues = [defaultAccess, fullAccess]

    /// The Codex flag the launch line carries (Codex 0.170.0). Rafu's launcher
    /// does not pass it to the terminal UI: `codex --remote … resume <id>`
    /// refuses it ("Permission overrides are not supported when resuming a
    /// remote task"). With the app's grant, the launcher gives the private app
    /// server `serverOverrides` instead.
    public static let codexBypassFlag = "--dangerously-bypass-approvals-and-sandbox"
    /// Codex 0.170.0's short alias of the bypass flag.
    public static let codexBypassAlias = "--yolo"
    /// The Codex sandbox value that removes the sandbox.
    public static let codexSandboxValue = "danger-full-access"
    /// What the bypass flag means, as configuration for `codex app-server`.
    public static let serverOverrides = [
        "-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"danger-full-access\"",
    ]

    /// The launcher's bridge operation: "may this terminal start Codex with
    /// full access now?" The app answers yes once per approved request.
    public static let grantOperation = "full_access"
    /// The one stderr line when the app gives no grant. No token, path or
    /// endpoint.
    public static let noGrantNotice =
        "Rafu: Full access needs the Rafu setting \"Allow Full access agents\" and your approval in the Ensemble. Codex starts with its usual approvals."

    /// The badge words, and what VoiceOver reads.
    public static let badgeText = "Full access"
    public static let accessibilityLabel = "Full access, skips approval prompts"
    public static let badgeSymbol = "exclamationmark.shield"

    /// The Settings switch, by name.
    public static let switchName = "Allow Full access agents"
    public static let switchOffMessage =
        "Full access is off in Rafu. Ask the user to turn on Settings > Ensemble > Allow Full access agents. Rafu never turns it on by itself."
    public static let onlyCodexReason =
        "access is only for agent codex. Other agents start with their own approval prompts."
    public static let commandReason =
        "a command may not give an agent full access. Use terminal_create with agent codex and access full; the user must first turn on Settings > Ensemble > Allow Full access agents."
    public static let textReason =
        "the text may not hold a full-access flag. Use terminal_create with agent codex and access full; the user must first turn on Settings > Ensemble > Allow Full access agents."
    public static let promptReason =
        "a prompt may not start with \"-\": the agent would read it as an option. Start the task with a word."
    /// The approval line for a change to a node that already has full access.
    public static let keepsFullAccessLine =
        "Full access: this Codex conversation keeps full access (no approval prompts, no sandbox)"

    /// The decision for a call that gives full access. Agent control Off
    /// refuses as for every change; with the switch Off, the call is refused
    /// with the switch's name; otherwise the user is asked every time, also
    /// in Allow, and no "Always" grant covers it.
    public static func decide(mode: CanvasAgentControlMode, switchIsOn: Bool)
        -> CanvasAgentDecision
    {
        if mode == .off { return .deny(CanvasAgentPolicy.offMessage) }
        guard switchIsOn else { return .deny(switchOffMessage) }
        return .ask
    }

    /// The words that ask Codex for full access, matched as substrings.
    static let fullAccessMarkers = [codexBypassFlag, codexBypassAlias, codexSandboxValue]

    /// True when agent-given text asks Codex for full access: the bypass
    /// flag, its `--yolo` alias, or the `danger-full-access` sandbox, anywhere
    /// in the text (also inside `sh -c "…"`). A guard, not a boundary: a
    /// `command` can run any program. The boundary is the launcher's grant.
    public static func textRequestsFullAccess(_ text: String) -> Bool {
        fullAccessMarkers.contains { text.contains($0) }
    }

    /// `textRequestsFullAccess` for each element of an agent-given `command`.
    public static func commandRequestsFullAccess(_ argv: [String]) -> Bool {
        argv.contains(where: textRequestsFullAccess)
    }

    /// True when a prompt would read as an option: its first non-space
    /// character is `-`.
    public static func promptLooksLikeOption(_ prompt: String) -> Bool {
        CanvasAgentText.singleLine(prompt, maxBytes: CanvasAgentToolCall.maximumPromptBytes)
            .trimmingCharacters(in: .whitespaces).hasPrefix("-")
    }

    /// Splits the arguments of one `codex` start. The bypass flag and its
    /// `--yolo` alias (before a `--`) leave the terminal UI's arguments;
    /// `server` then holds `serverOverrides`. The launcher uses `server` only
    /// when the app grants this start (`grantOperation`). Other arguments
    /// stay in their order.
    public static func splitCodexArguments(_ arguments: [String])
        -> (terminal: [String], server: [String])
    {
        var terminal: [String] = []
        var found = false
        var afterTerminator = false
        for argument in arguments {
            if !afterTerminator, argument == codexBypassFlag || argument == codexBypassAlias {
                found = true
                continue
            }
            if argument == "--" { afterTerminator = true }
            terminal.append(argument)
        }
        return (terminal, found ? serverOverrides : [])
    }
}
