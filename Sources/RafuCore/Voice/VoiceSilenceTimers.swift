import Foundation

public nonisolated enum VoiceTimerAction: Equatable, Sendable {
    /// "Shall I keep listening?" after latched silence.
    case checkIn
    /// Mute and stop the microphone tap; the session stays open.
    case pause
    /// Close the session: idle time is billed like talking time.
    case close
}

/// The session's silence and idle clock. Instants are offsets from the session
/// start, injected by the caller; nothing here sleeps or owns a task.
public nonisolated struct VoiceActivityClock: Equatable, Sendable {
    public static let checkInAfter: Duration = .seconds(45)
    public static let pauseAfter: Duration = .seconds(60)
    public static let closeAfter: Duration = .seconds(90)
    /// With an open work order (Phase 2) the session waits for its result.
    public static let closeAfterWithWorkOrders: Duration = .seconds(600)

    public var lastSpeech: Duration
    public var lastServerActivity: Duration
    public var latched = false
    public var openWorkOrders = 0
    public var checkedIn = false
    public var paused = false

    public init(start: Duration = .zero) {
        lastSpeech = start
        lastServerActivity = start
    }

    /// Local speech resets the silence and clears a check-in or pause.
    public mutating func noteSpeech(at instant: Duration) {
        lastSpeech = max(lastSpeech, instant)
        checkedIn = false
        paused = false
    }

    /// Audible reply, a delegation, or a tool call: Rafu is not idle.
    public mutating func noteServerActivity(at instant: Duration) {
        lastServerActivity = max(lastServerActivity, instant)
    }

    public mutating func setLatched(_ value: Bool, at instant: Duration) {
        latched = value
        checkedIn = false
        paused = false
        if value { lastSpeech = max(lastSpeech, instant) }
    }

    private var lastActivity: Duration { max(lastSpeech, lastServerActivity) }

    /// The action due at `now`, if any. The caller records `checkedIn` and
    /// `paused` so each fires once.
    public func nextAction(at now: Duration) -> VoiceTimerAction? {
        let quiet = now - lastActivity
        let closeLimit =
            openWorkOrders > 0 ? Self.closeAfterWithWorkOrders : Self.closeAfter
        if quiet >= closeLimit { return .close }
        guard latched, !paused else { return nil }
        if quiet >= Self.pauseAfter { return .pause }
        if quiet >= Self.checkInAfter, !checkedIn { return .checkIn }
        return nil
    }
}
