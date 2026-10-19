import Foundation
import RafuCore

/// One Ensemble terminal card's agent status, folded from its matched hook
/// session, the terminal's own liveness, and whether its last reply has
/// been looked at. Free of SwiftUI: colour and glyph live in the view
/// (`AgentActivityGlyph`, `AgentStatusPill`).
nonisolated enum AgentCardStatus: Equatable, Sendable {
    /// What the agent waits on the person for.
    enum Attention: Equatable, Sendable {
        case approval
        case input
    }

    case working
    case needsYou(Attention)
    case failed
    case doneUnread
    case done
    case inactive
    case stopped

    /// A finished (or stale working) session this long without an update
    /// reads as inactive, not done or working.
    static let inactiveInterval: TimeInterval = 30 * 60

    /// Pane statuses a card can be "Stopped" in, once it ran an agent: the
    /// agent's own process ended, or it was never started this session.
    private static let stoppedPaneStatuses: Set<TerminalPaneStatus> = [.stopped, .exited, .idle]

    /// Resolves the one status a canvas terminal card shows, or `nil` to
    /// keep today's plain terminal-state text ("Running", "Not running",
    /// "Exited", "Unavailable") — an ordinary shell with no matched session,
    /// or a pane whose live status does not map to anything here.
    ///
    /// Precedence: stopped, failed, needsYou, working, inactive, doneUnread,
    /// done. Pure and independent of any store or controller, so it stays
    /// testable without either.
    static func resolve(
        session: TrackedAgentSession?,
        terminalStatus: TerminalSessionStatus,
        paneStatus: TerminalPaneStatus,
        ranAgent: Bool,
        isReplyAcknowledged: Bool,
        now: Date
    ) -> AgentCardStatus? {
        let hasLiveSession: Bool
        switch terminalStatus {
        case .idle, .exited: hasLiveSession = false
        case .running, .bell: hasLiveSession = true
        }
        guard hasLiveSession, let session, session.state != .ended else {
            guard ranAgent, stoppedPaneStatuses.contains(paneStatus) else { return nil }
            return .stopped
        }

        if session.state == .needsInput, session.lastEventName == "StopFailure" {
            return .failed
        }
        if session.state == .waitingForPermission { return .needsYou(.approval) }
        if session.state == .needsInput { return .needsYou(.input) }
        if session.state == .working, !session.isStale(at: now) { return .working }

        let elapsed = now.timeIntervalSince(session.updatedAt)
        let isIdleTooLong =
            session.state == .finished || (session.state == .working && session.isStale(at: now))
        if isIdleTooLong, elapsed >= inactiveInterval { return .inactive }

        guard session.state == .finished else { return nil }
        if session.replyEventID != nil, !isReplyAcknowledged { return .doneUnread }
        return .done
    }

    /// The header/list word: "Working", "Needs approval", "Needs input",
    /// "Failed", "Done" (unread or read alike), "Inactive", "Stopped".
    var word: String {
        switch self {
        case .working: "Working"
        case .needsYou(.approval): "Needs approval"
        case .needsYou(.input): "Needs input"
        case .failed: "Failed"
        case .doneUnread, .done: "Done"
        case .inactive: "Inactive"
        case .stopped: "Stopped"
        }
    }

    /// The SF Symbol name, or `nil` for `.working`: that one draws the
    /// custom spinning 3/4 arc (`AgentActivityGlyph`) instead.
    var symbolName: String? {
        switch self {
        case .working: nil
        case .needsYou: "exclamationmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .doneUnread: "checkmark.circle.fill"
        case .done: "checkmark"
        case .inactive: "moon.fill"
        case .stopped: "stop.circle"
        }
    }

    /// Whether the card's title reads bold: only a done reply nobody has
    /// looked at yet.
    var readsTitleBold: Bool { self == .doneUnread }

    /// The spoken accessibility value. `elapsed` is the time since the
    /// status's underlying session or pane last changed; statuses that are
    /// not time-relevant (`needsYou`, `failed`, `stopped`) ignore it.
    func accessibilityValue(elapsed: TimeInterval) -> String {
        switch self {
        case .working: return "Working, \(Self.spokenDuration(elapsed))"
        case .needsYou(.approval): return "Needs approval"
        case .needsYou(.input): return "Needs input"
        case .failed: return "Failed"
        case .doneUnread: return "Done, unread, \(Self.spokenDuration(elapsed)) ago"
        case .done: return "Done, \(Self.spokenDuration(elapsed)) ago"
        case .inactive: return "Inactive, \(Self.spokenDuration(elapsed)) ago"
        case .stopped: return "Stopped"
        }
    }

    /// "1 minute", "4 minutes", "2 hours", "3 days" — the full-word duration
    /// an accessibility value reads, distinct from `AgentCardElapsed.label`'s
    /// compact "1m"/"4m"/"2h"/"3d" used in visible text.
    private static func spokenDuration(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded()))
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        if minutes >= 1 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "moments"
    }
}

/// The compact relative-time label an agent card's header and list row show
/// beside its status word: "now", "1m"…"59m", "1h"…"23h", "2d"… `now` is
/// always the caller's injected clock, never read live, so this stays a
/// pure formatter (no ticker of its own — `AgentActivityStore.now` already
/// ticks every 30 s while sessions exist).
nonisolated enum AgentCardElapsed {
    static func label(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }
}
