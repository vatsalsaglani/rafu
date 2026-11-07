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
    private static let confirmHint = "Entertoconfirm"
    private static let channelsLabel = "Channels:"
    private static let selectedOption = "❯ 1. I am using this for local development"

    /// True only when `lines` show the complete dialog for Rafu's own channel
    /// with option 1 selected. Every part must be present:
    ///
    /// - the "Loading development channels" title;
    /// - the `--dangerously-load-development-channels` flag name;
    /// - one `Channels:` line whose only entry is exactly `server:rafu`;
    /// - "I am using this for local development" as the selected option (`❯ 1.`);
    /// - the "Enter to confirm" hint.
    ///
    /// Wrapped rows are joined before the title, flag, and hint are searched, so a
    /// dialog wrapped at 60 or 80 columns still matches. The `Channels:` line and
    /// the option line must start their row, so output that merely quotes them
    /// does not match. Any code fence in view means the text is a quotation.
    public static func matches(_ lines: [String]) -> Bool {
        let rows = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !rows.contains(where: { $0.hasPrefix("```") || $0.hasPrefix("~~~") }) else {
            return false
        }
        let flat = rows.joined().filter { !$0.isWhitespace }
        guard flat.contains(title), flat.contains(flag), flat.contains(confirmHint) else {
            return false
        }
        guard rows.filter({ normalized($0) == normalized(selectedOption) }).count == 1,
            channels(in: rows) == [channelEntry]
        else { return false }
        return true
    }

    /// The entries of the single `Channels:` line, joined across the rows that
    /// wrap it. `nil` when there is no such line or more than one. Entries split
    /// on commas and whitespace, so a second entry never hides in a long line.
    private static func channels(in rows: [String]) -> [String]? {
        let starts = rows.indices.filter { rows[$0].hasPrefix(channelsLabel) }
        guard starts.count == 1, let start = starts.first else { return nil }
        var text = String(rows[start].dropFirst(channelsLabel.count))
        var next = start + 1
        // The list ends at the first blank row; a wrapped list continues until then.
        while next < rows.count, !rows[next].isEmpty {
            text += " " + rows[next]
            next += 1
        }
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
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

    /// The watch ends this long after the launch.
    public static let window: TimeInterval = 30
    /// After the Return, the dialog may stay this long before Rafu gives up.
    public static let confirmGrace: TimeInterval = 2
    /// At most four samples per second.
    public static let sampleInterval: TimeInterval = 0.25

    private let startedAt: TimeInterval
    private var sentAt: TimeInterval?
    private var finished = false

    public init(startedAt: TimeInterval) { self.startedAt = startedAt }

    public var isFinished: Bool { finished }
    /// True once `.sendReturn` was answered. There is no second Return.
    public var hasSentReturn: Bool { sentAt != nil }

    /// `lines` is `nil` when the terminal has no view to read. `eligible` is the
    /// current `CanvasChannelPrompt.mayConfirm` result; it is ignored once the
    /// Return is sent, because that cannot be taken back.
    public mutating func advance(now: TimeInterval, lines: [String]?, eligible: Bool) -> Action {
        guard !finished else { return .stop }
        let visible = lines.map(CanvasChannelPrompt.matches) ?? false
        if let sentAt {
            if lines != nil, !visible { return finish(.confirmed) }
            if now - sentAt >= Self.confirmGrace {
                return finish(visible ? .couldNotConfirm : .stop)
            }
            return .wait
        }
        guard eligible, now - startedAt < Self.window else { return finish(.stop) }
        guard visible else { return .wait }
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
