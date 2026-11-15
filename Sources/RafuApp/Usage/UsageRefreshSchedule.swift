import Foundation
import RafuCore

/// When usage is read. Pure and `Sendable`: the caller passes every `Date`,
/// so a test drives it with a fake clock and no sleeping.
///
/// Three things ask for a read:
/// - an agent turn ended (a `Stop`-class hook event). The read waits
///   `coalesce` seconds, so a parent `Stop` plus several `SubagentStop`
///   events make one read, and never starts sooner than `minimumInterval`
///   after the previous read;
/// - a surface opened (`requestedOnOpen`): reads only when the data is older
///   than `openStaleness`;
/// - nothing happened for a while (the fallback, `Cadence.interval`).
///
/// One read runs at a time. A turn end during a read asks for one follow-up
/// read. A manual refresh bypasses the interval limits but joins a read that
/// already runs. A failed read backs off the automatic reads by
/// `fallbackInterval × failures` (failures capped at `maximumFailures`).
///
/// The usage endpoints keep their own 429 and Keychain gates
/// (`UsageHTTPClient`, ADR 0027); this schedule only decides when to ask.
nonisolated struct UsageRefreshSchedule: Equatable, Sendable {
    /// Wait after the first turn end, so one burst of hook events is one read.
    static let coalesce: TimeInterval = 15
    /// The shortest gap between two automatic read starts.
    static let minimumInterval: TimeInterval = 60
    /// A surface that opens reads only when the last good read is older.
    static let openStaleness: TimeInterval = 60
    /// The fallback cadence while a status item or a resting panel shows usage.
    static let fallbackInterval: TimeInterval = 300
    /// The fallback cadence while the notch panel is pinned open.
    static let pinnedInterval: TimeInterval = 180
    /// A failure count never grows past this.
    static let maximumFailures = 3
    /// A turn-end event older than this is history (a spool replayed at
    /// launch), not news.
    static let maximumEventAge: TimeInterval = 60

    /// How often the fallback reads, by what is on screen.
    enum Cadence: Equatable, Sendable {
        /// Nothing shows usage: no automatic read at all.
        case none
        /// A status item or a resting panel shows usage.
        case resting
        /// The notch panel is pinned open.
        case pinned

        /// The cadence for what is on screen. The status item always counts
        /// as a resting surface; a pinned panel reads faster only when no
        /// status item is the one showing usage.
        static func resolve(hasStatusItem: Bool, hasPanel: Bool, isPinned: Bool) -> Cadence {
            if hasPanel && isPinned && !hasStatusItem { return .pinned }
            return hasStatusItem || hasPanel ? .resting : .none
        }

        var interval: TimeInterval? {
            switch self {
            case .none: nil
            case .resting: UsageRefreshSchedule.fallbackInterval
            case .pinned: UsageRefreshSchedule.pinnedInterval
            }
        }
    }

    private(set) var isRunning = false
    /// When the latest read started (any trigger).
    private(set) var lastStarted: Date?
    /// When the latest read that produced data finished.
    private(set) var lastSucceeded: Date?
    private(set) var failures = 0
    /// Automatic reads wait until this after a failure.
    private(set) var retryNotBefore: Date?
    /// The time a coalesced turn-end read is due.
    private(set) var turnEndDue: Date?
    /// A turn ended during a read: one more read follows it.
    private(set) var followUpPending = false

    init() {}

    // MARK: - Requests

    /// A turn ended. Keeps the earliest pending due time, so a long burst
    /// cannot push the read back forever.
    mutating func receivedTurnEnd(at now: Date) {
        if isRunning {
            followUpPending = true
            return
        }
        let due = dueTime(after: now)
        turnEndDue = min(turnEndDue ?? due, due)
    }

    /// A surface opened. `true` means read now (the caller then calls
    /// `begin`). A read in flight, or one started within `minimumInterval`,
    /// or fresh data, all answer `false`.
    func shouldRefreshOnOpen(at now: Date) -> Bool {
        guard !isRunning else { return false }
        if let lastStarted, now.timeIntervalSince(lastStarted) < Self.minimumInterval {
            return false
        }
        guard let lastSucceeded else { return true }
        return now.timeIntervalSince(lastSucceeded) > Self.openStaleness
    }

    /// A person asked for a refresh. `true` means start a read; `false`
    /// means a read already runs and the request joins it.
    func shouldStartManualRefresh() -> Bool { !isRunning }

    // MARK: - Lifecycle of one read

    /// Marks a read started. `false` when one already runs.
    @discardableResult
    mutating func begin(at now: Date) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        lastStarted = now
        turnEndDue = nil
        followUpPending = false
        return true
    }

    /// Marks the read finished. A failure backs off the automatic reads; a
    /// pending follow-up becomes a coalesced read.
    mutating func finish(at now: Date, succeeded: Bool) {
        isRunning = false
        if succeeded {
            failures = 0
            retryNotBefore = nil
            lastSucceeded = now
        } else {
            failures = min(failures + 1, Self.maximumFailures)
            retryNotBefore = now.addingTimeInterval(Self.fallbackInterval * Double(failures))
        }
        if followUpPending {
            followUpPending = false
            turnEndDue = dueTime(after: now)
        }
    }

    /// The read was cancelled (its surface went away) and will never
    /// finish: forget it without counting a success or a failure.
    mutating func abort() {
        isRunning = false
        followUpPending = false
    }

    // MARK: - When next

    /// The next automatic read, or `nil` while a read runs (`finish` decides
    /// then) or when nothing shows usage.
    func next(cadence: Cadence) -> Date? {
        guard !isRunning, let interval = cadence.interval else { return nil }
        let base = lastStarted ?? .distantPast
        // After failures the fallback stretches: interval × failures.
        var fallback = base.addingTimeInterval(interval * Double(max(failures, 1)))
        if let retryNotBefore { fallback = max(fallback, retryNotBefore) }
        guard let turnEndDue else { return fallback }
        return min(turnEndDue, fallback)
    }

    func isDue(at now: Date, cadence: Cadence) -> Bool {
        guard let next = next(cadence: cadence) else { return false }
        return next <= now
    }

    // MARK: - Private

    private func dueTime(after now: Date) -> Date {
        var due = now.addingTimeInterval(Self.coalesce)
        if let lastStarted {
            due = max(due, lastStarted.addingTimeInterval(Self.minimumInterval))
        }
        if let retryNotBefore { due = max(due, retryNotBefore) }
        return due
    }
}

/// Which hook events end an agent turn, and which usage provider each
/// agent provider feeds.
nonisolated enum UsageRefreshTrigger {
    /// Events that mean the provider's counters just moved: a turn, a
    /// subagent, or a session ended.
    static let turnEndEventNames: Set<String> = [
        "Stop", "SubagentStop", "StopFailure", "SessionEnd",
    ]

    /// `true` for a turn-end event no older than `maximumEventAge`. A spool
    /// replayed at launch is old, so it never starts a read burst.
    static func isFreshTurnEnd(_ event: AgentHookEvent, now: Date) -> Bool {
        guard turnEndEventNames.contains(event.hookEventName) else { return false }
        let age = now.timeIntervalSince(event.time)
        return age >= -5 && age <= UsageRefreshSchedule.maximumEventAge
    }

    static func usageProvider(for provider: AgentHookProvider) -> UsageProviderID {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        }
    }
}
