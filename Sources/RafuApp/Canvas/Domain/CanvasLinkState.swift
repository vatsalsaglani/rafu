import Foundation

/// Per-link runtime state for Canvas message links (review 7.6). None of it is
/// saved with a board: links restore Paused and message bodies are never kept.

nonisolated enum CanvasLinkDisconnectReason: Equatable, Sendable {
    /// The terminal stopped or exited.
    case sessionEnded
    /// The CLI changed conversation (`/new`, resume, fork).
    case conversationChanged
    /// The private transport to the terminal failed.
    case connectionLost
    /// The terminal runs, but no agent is connected in it.
    case agentNotRunning

    var message: String {
        switch self {
        case .sessionEnded: "This session ended. Start the terminal again to reconnect."
        case .conversationChanged: "The conversation changed. Start a new terminal to link it."
        case .connectionLost: "The connection was lost. Start a new terminal to link it."
        case .agentNotRunning: "Run claude or codex in both terminals to use this link."
        }
    }
}

nonisolated enum CanvasLinkState: Equatable, Sendable {
    case live
    case paused
    case disconnected(CanvasLinkDisconnectReason)
    case failed(String)

    enum Kind: Equatable, Sendable { case live, paused, disconnected, failed }

    var kind: Kind {
        switch self {
        case .live: .live
        case .paused: .paused
        case .disconnected: .disconnected
        case .failed: .failed
        }
    }

    /// State is never carried by colour alone: every state has a word and a glyph.
    var word: String {
        switch self {
        case .live: "Live"
        case .paused: "Paused"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        }
    }

    var glyph: String {
        switch self {
        case .live: "⇄"
        case .paused: "‖"
        case .disconnected: "⊘"
        case .failed: "△"
        }
    }

    var badgeText: String { "\(glyph) \(word)" }

    /// The hover text that explains a Disconnected or Failed state.
    var reason: String? {
        switch self {
        case .disconnected(let reason): reason.message
        case .failed(let reason): reason
        case .live, .paused: nil
        }
    }
}

/// What the bridge knows about one terminal end of a message link.
nonisolated enum CanvasLinkEndpointStatus: Equatable, Sendable {
    /// No live capability: the terminal is stopped, exited, removed or never started.
    case missing
    /// A capability exists, but no agent is registered (or its heartbeat is stale).
    case notConnected
    case connected
    case suspended(CanvasLinkDisconnectReason)
}

nonisolated enum CanvasLinkStateMapper {
    /// Paused wins, because a paused link carries no messages whatever its
    /// terminals do (and restored links start there). Then the terminal
    /// conditions, then a recorded refusal.
    static func resolve(
        isEnabled: Bool, from: CanvasLinkEndpointStatus, to: CanvasLinkEndpointStatus,
        failure: String?
    ) -> CanvasLinkState {
        guard isEnabled else { return .paused }
        for status in [from, to] {
            if case .suspended(let reason) = status { return .disconnected(reason) }
        }
        if from == .missing || to == .missing { return .disconnected(.sessionEnded) }
        if from == .notConnected || to == .notConnected {
            return .disconnected(.agentNotRunning)
        }
        if let failure { return .failed(failure) }
        return .live
    }
}

nonisolated struct CanvasLinkSummary: Equatable, Sendable {
    var live = 0
    var paused = 0
    var disconnected = 0
    var failed = 0

    init(states: [CanvasLinkState]) {
        for state in states {
            switch state.kind {
            case .live: live += 1
            case .paused: paused += 1
            case .disconnected: disconnected += 1
            case .failed: failed += 1
            }
        }
    }

    var total: Int { live + paused + disconnected + failed }

    /// "⇄ 1 live · 0 paused"; disconnected and failed counts appear only when present.
    var text: String {
        var parts = ["⇄ \(live) live", "\(paused) paused"]
        if disconnected > 0 { parts.append("\(disconnected) disconnected") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum CanvasLinkDirection: Equatable, Sendable {
    /// From the connection's `from` card to its `to` card.
    case forward
    case reverse
}

/// A lightweight event published when a message is accepted on a link. It
/// carries the connection and direction only, never the message body.
nonisolated struct CanvasLinkMessageEvent: Equatable, Sendable {
    let connectionID: UUID
    let direction: CanvasLinkDirection
    let date: Date
}

nonisolated struct CanvasBurstPolicy: Equatable, Sendable {
    /// More than `limit` messages inside `window` seconds show only a count.
    var limit: Int
    var window: TimeInterval
    /// How long one dot travels; a new message during that time adds no second dot.
    var travel: TimeInterval
    /// The count resets after this long without a message.
    var resetAfter: TimeInterval = 600
}

/// Per-link message activity: badge count, burst coalescing and the one
/// travelling dot. A pure value type; the bridge owns one per link.
nonisolated struct CanvasLinkActivity: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case travel(CanvasLinkDirection)
        case countOnly
    }

    private(set) var count = 0
    /// Increments on every accepted message; Reduce Motion pulses on it.
    private(set) var serial = 0
    private(set) var lastMessageAt: Date?
    private(set) var dotStartedAt: Date?
    private(set) var dotDirection: CanvasLinkDirection = .forward
    private var recent: [Date] = []

    init() {}

    @discardableResult
    mutating func record(
        direction: CanvasLinkDirection, at now: Date, policy: CanvasBurstPolicy
    ) -> Outcome {
        if let last = lastMessageAt, now.timeIntervalSince(last) > policy.resetAfter {
            count = 0
            recent = []
        }
        recent.removeAll { now.timeIntervalSince($0) > policy.window }
        recent.append(now)
        count += 1
        serial += 1
        lastMessageAt = now
        let isBurst = recent.count > policy.limit
        if isBurst || isDotActive(at: now, travel: policy.travel) { return .countOnly }
        dotStartedAt = now
        dotDirection = direction
        return .travel(direction)
    }

    func isDotActive(at now: Date, travel: TimeInterval) -> Bool {
        guard let started = dotStartedAt else { return false }
        let elapsed = now.timeIntervalSince(started)
        return elapsed >= 0 && elapsed < travel
    }

    /// 0...1 progress of the running dot, or nil when no dot runs.
    func dotProgress(at now: Date, travel: TimeInterval) -> Double? {
        guard isDotActive(at: now, travel: travel), let started = dotStartedAt, travel > 0 else {
            return nil
        }
        return now.timeIntervalSince(started) / travel
    }

    /// The count shown in the badge; 0 once ten minutes pass without a message.
    func visibleCount(at now: Date, resetAfter: TimeInterval) -> Int {
        guard let last = lastMessageAt, now.timeIntervalSince(last) <= resetAfter else { return 0 }
        return count
    }
}

/// Text for badges, tooltips and VoiceOver, kept pure so it can be tested.
nonisolated enum CanvasLinkText {
    /// "⇄ Live", "⇄ Live · 3", "⇄ Live · 3 · review".
    static func badge(state: CanvasLinkState, count: Int, label: String?) -> String {
        var text = state.badgeText
        if count > 0 { text += " · \(count)" }
        if let label, !label.isEmpty { text += " · \(label)" }
        return text
    }

    /// "claude — api ⇄ codex — tests · Live · 3 messages in 10 min".
    static func tooltip(
        from: String, to: String, isMessageLink: Bool, state: CanvasLinkState?, count: Int,
        label: String?
    ) -> String {
        guard isMessageLink, let state else {
            let suffix = (label?.isEmpty == false) ? " · \(label ?? "")" : ""
            return "\(from) → \(to)\(suffix)"
        }
        var text = "\(from) ⇄ \(to) · \(state.word)"
        if count > 0 { text += " · \(count) \(count == 1 ? "message" : "messages") in 10 min" }
        if let reason = state.reason { text += "\n\(reason)" }
        return text
    }

    /// "Message link from A to B, Live, label L".
    static func accessibilityLabel(
        from: String, to: String, isMessageLink: Bool, state: CanvasLinkState?, label: String?
    ) -> String {
        var text = isMessageLink ? "Message link" : "Relationship"
        text += " from \(from) to \(to)"
        if isMessageLink, let state { text += ", \(state.word)" }
        if let label, !label.isEmpty { text += ", label \(label)" }
        return text
    }

    /// The VoiceOver announcement for a state change: "Link to codex — tests paused".
    static func announcement(target: String, state: CanvasLinkState) -> String {
        "Link to \(target) \(state.word.lowercased())"
    }
}
