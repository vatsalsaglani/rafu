import Foundation

/// Claude Code's "Loading development channels" dialog for Rafu's own channel.
///
/// Rafu starts Claude with `--dangerously-load-development-channels=server:rafu`,
/// and Claude asks the user to confirm on every start. This type holds the
/// narrow rules for answering that one dialog and no other (ADR 0026,
/// `docs/references/canvas-live-sessions.md`). It is pure: it reads lines and
/// never touches a terminal.
public nonisolated enum CanvasChannelPrompt {
    /// The `operation` of the bridge request that the Claude launcher sends
    /// before it replaces itself with Claude.
    public static let launchOperation = "launch"

    /// The only channel entry the matcher accepts.
    public static let channelEntry = "server:rafu"

    public static let confirmedNotice =
        "Rafu confirmed the development-channel prompt for server:rafu."
    public static let unconfirmedNotice =
        "Rafu could not confirm the channel prompt; answer it in the terminal."

    private static let title = "Loadingdevelopmentchannels"
    private static let flag = "--dangerously-load-development-channels"
    private static let channelsLabel = "Channels:"
    private static let selectedOption = "❯ 1. I am using this for local development"
    private static let exitOption = "2. Exit"
    /// Folder-trust dialog parts. Used only to extend the watch window, never to answer.
    private static let trustTitle = "Quicksafetycheck"
    private static let trustOption = "Yes,Itrustthisfolder"
    /// The first word of every segment of the dialog's key-hint footer.
    private static let hintKeys: Set<String> = [
        "Enter", "Return", "Esc", "Escape", "Tab", "↑/↓", "↑↓", "↑", "↓",
    ]

    /// True only when `lines` show the complete dialog for Rafu's own channel
    /// with option 1 selected. Every part must be present:
    ///
    /// - the "Loading development channels" title;
    /// - the `--dangerously-load-development-channels` flag name;
    /// - one `Channels:` line whose only entry is exactly `server:rafu`;
    /// - "I am using this for local development" as the selected option (`❯ 1.`),
    ///   followed by the "2. Exit" option.
    ///
    /// The dialog must also be the tail of the sample. After the selected option
    /// only blank rows, the "2. Exit" row, and then at most the dialog's key-hint
    /// footer (`Enter to confirm · Esc to cancel`, or any row made only of
    /// `<Key> to <action>` parts) may follow. The dialog sits at the bottom of
    /// the screen, so anything shown below it (a tool-permission prompt, an
    /// agent's text) gives no match. The footer wording is Claude Code's, not
    /// Rafu's, and Claude Code builds it from its active key bindings, so the
    /// footer is not required to say "Enter to confirm".
    ///
    /// Wrapped rows are joined before the title and flag are searched, so a
    /// dialog wrapped at 60 or 80 columns still matches. The `Channels:` line and
    /// the option line must start their row, so output that merely quotes them
    /// does not match. Any code fence in view means the text is a quotation.
    public static func matches(_ lines: [String]) -> Bool {
        let rows = lines.map(cleaned)
        guard !hasFence(rows) else { return false }
        let flat = rows.joined().filter { !$0.isWhitespace }
        guard flat.contains(title), flat.contains(flag) else { return false }
        let selected = rows.indices.filter {
            normalized(rows[$0]) == normalized(selectedOption)
        }
        guard selected.count == 1, let selectedRow = selected.first,
            channels(in: rows) == [channelEntry],
            isDialogTail(rows[(selectedRow + 1)...])
        else { return false }
        return true
    }

    /// True when `lines` show Claude Code's folder-trust dialog. The watch uses
    /// this only to keep waiting while the user answers it; Rafu never answers it.
    public static func isFolderTrust(_ lines: [String]) -> Bool {
        let rows = lines.map(cleaned)
        guard !hasFence(rows) else { return false }
        let flat = rows.joined().filter { !$0.isWhitespace }
        return flat.contains(trustTitle) && flat.contains(trustOption)
    }

    /// A terminal cell that was never written reads as NUL (`"\0"`), not a
    /// space. Claude Code 2.1.323 moves the cursor between words (`ESC[nG`)
    /// instead of printing spaces, so every gap in its dialog is NUL cells.
    /// They count as spaces here; the row is then trimmed.
    private static func cleaned(_ line: String) -> String {
        String(line.map { $0 == "\u{0}" ? " " : $0 })
            .trimmingCharacters(in: .whitespaces)
    }

    private static func hasFence(_ rows: [String]) -> Bool {
        rows.contains { $0.hasPrefix("```") || $0.hasPrefix("~~~") }
    }

    /// Rows after the selected option: `2. Exit`, then at most a key-hint footer.
    private static func isDialogTail(_ rest: ArraySlice<String>) -> Bool {
        let content = rest.filter { !$0.isEmpty }.map(normalized)
        guard content.first == exitOption else { return false }
        // The footer is one row. Rows after it are other output, not the dialog.
        let footer = content.dropFirst()
        return footer.isEmpty || (footer.count == 1 && isKeyHint(footer[footer.startIndex]))
    }

    /// `Enter to confirm · Esc to cancel` and its relatives: short segments split
    /// on `·`, each starting with a key name and saying what it does.
    private static func isKeyHint(_ text: String) -> Bool {
        guard text.count <= 120 else { return false }
        let segments = text.split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !segments.isEmpty else { return false }
        for segment in segments {
            let words = segment.split(separator: " ")
            guard (2...4).contains(words.count), let key = words.first,
                hintKeys.contains(String(key))
            else { return false }
        }
        return segments.contains { $0.hasPrefix("Enter") || $0.hasPrefix("Esc") }
    }

    /// The entries of the single `Channels:` line, joined across the rows that
    /// wrap it. `nil` when there is no such line or more than one. Entries split
    /// on commas and whitespace, so a second entry never hides in a long line.
    private static func channels(in rows: [String]) -> [String]? {
        let starts = rows.indices.filter { rows[$0].hasPrefix(channelsLabel) }
        guard starts.count == 1, let start = starts.first else { return nil }
        var text = String(rows[start].dropFirst(channelsLabel.count))
        var next = start + 1
        // The list ends at the first blank row or the first option row; a
        // wrapped list continues until then.
        while next < rows.count, !rows[next].isEmpty, !isOptionRow(rows[next]) {
            text += " " + rows[next]
            next += 1
        }
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// `❯ 1. …`, `  2. …`: a select row, selected or not.
    private static func isOptionRow(_ row: String) -> Bool {
        if row.hasPrefix("❯") { return true }
        let digits = row.prefix { $0.isNumber }
        return !digits.isEmpty && row.dropFirst(digits.count).hasPrefix(".")
    }

    /// The option row is compared with runs of spaces collapsed, so the dialog's
    /// own spacing does not matter. The text must still be the whole row.
    private static func normalized(_ row: String) -> String {
        row.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Everything that must hold before Rafu may answer the prompt.
    /// - `launchedByRafu`: Rafu's own launcher started this Claude with the
    ///   Rafu channel flag (a launch record, never an inference from output).
    public static func mayConfirm(
        mode: CanvasAgentControlMode, settingOn: Bool, launchedByRafu: Bool
    ) -> Bool {
        mode == .allow && settingOn && launchedByRafu
    }

    /// The request the Claude launcher sends, or `nil` when it must not send one:
    /// only a Claude start that gets Rafu's channel flag counts, and only when the
    /// launcher has the terminal's private token.
    public static func launchRequest(
        provider: String, arguments: [String], environment: [String: String]
    ) -> CanvasBridgeRequest? {
        guard provider == "claude",
            CanvasBridgeLaunch.shouldAttach(provider: provider, arguments: arguments),
            let token = environment["RAFU_CANVAS_TOKEN"], !token.isEmpty
        else { return nil }
        return CanvasBridgeRequest(token: token, operation: launchOperation, provider: provider)
    }
}

/// One bounded watch for the dialog after one launch. It sees samples of the
/// terminal's visible rows and answers what to do. It holds no clock, no
/// terminal, and no timer: the owner samples at `sampleInterval` and stops at
/// the first `.stop`, so nothing runs once the watch ends.
public nonisolated struct CanvasChannelPromptWatch: Sendable {
    public enum Action: Equatable, Sendable {
        /// Sample again.
        case wait
        /// Send exactly one Return to the terminal. Never returned twice.
        case sendReturn
        /// The dialog is gone after the Return.
        case confirmed
        /// The dialog is still visible after `confirmGrace`.
        case couldNotConfirm
        /// The watch is over; sample no more.
        case stop
    }

    /// The watch ends this long after the launch. A slow Claude start can take
    /// more than 30 s.
    public static let window: TimeInterval = 60
    /// While Claude's folder-trust dialog is on screen, the window restarts at
    /// every sample, so the user has `window` seconds after answering it. The
    /// whole watch still never lasts longer than this after the launch.
    public static let maxWindow: TimeInterval = 600
    /// After the Return, the dialog may stay this long before Rafu gives up.
    public static let confirmGrace: TimeInterval = 2
    /// At most four samples per second while the gates hold.
    public static let sampleInterval: TimeInterval = 0.25
    /// While a gate is closed the owner reads nothing; it only looks again, at
    /// this slower pace, in case the user switches the board to Allow.
    public static let idleInterval: TimeInterval = 1

    private let startedAt: TimeInterval
    private var deadline: TimeInterval
    private var sentAt: TimeInterval?
    private var finished = false

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        deadline = startedAt + Self.window
    }

    public var isFinished: Bool { finished }
    /// True once `.sendReturn` was answered. There is no second Return.
    public var hasSentReturn: Bool { sentAt != nil }

    /// `lines` is `nil` when the terminal has no view to read. `eligible` is the
    /// current `CanvasChannelPrompt.mayConfirm` result; it is ignored once the
    /// Return is sent, because that cannot be taken back. While `eligible` is
    /// false the watch waits and ignores `lines`: Allow may come later in the
    /// window (the user switches the board after the start).
    public mutating func advance(now: TimeInterval, lines: [String]?, eligible: Bool) -> Action {
        guard !finished else { return .stop }
        if let sentAt {
            let visible = lines.map(CanvasChannelPrompt.matches) ?? false
            if lines != nil, !visible { return finish(.confirmed) }
            if now - sentAt >= Self.confirmGrace {
                return finish(visible ? .couldNotConfirm : .stop)
            }
            return .wait
        }
        guard now < deadline else { return finish(.stop) }
        guard eligible, let lines else { return .wait }
        if CanvasChannelPrompt.isFolderTrust(lines) {
            // The user is answering Claude's own dialog; keep waiting for ours.
            deadline = min(startedAt + Self.maxWindow, max(deadline, now + Self.window))
            return .wait
        }
        guard CanvasChannelPrompt.matches(lines) else { return .wait }
        sentAt = now
        return .sendReturn
    }

    /// The terminal refused the Return. There is no second attempt.
    public mutating func returnFailed() -> Action { finish(.couldNotConfirm) }

    private mutating func finish(_ action: Action) -> Action {
        finished = true
        return action
    }
}
