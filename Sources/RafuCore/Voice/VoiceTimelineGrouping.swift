import Foundation

/// One delegation and the tool and board rows made under it. The capsule
/// header shows "Working N s" while it runs and "Thought for N s" after.
public nonisolated struct VoiceTimelineGroup: Equatable, Identifiable, Sendable {
    public let header: VoiceTimelineEvent
    public let children: [VoiceTimelineEvent]
    /// True while the delegation can still add steps.
    public let isRunning: Bool
    /// When the group ended, in session milliseconds. `nil` while running.
    public let endMS: Int?

    public var id: String { header.id }

    /// The delegation's step count: its tool and board rows.
    public var stepCount: Int { children.count }

    public var finishedStepCount: Int { children.filter { $0.endMS != nil }.count }

    /// `nil` while running. `.failed` when any step failed, else `.ok`.
    public var outcome: VoiceTimelineEvent.Outcome? {
        guard !isRunning else { return nil }
        return children.contains { $0.outcome == .failed } ? .failed : .ok
    }

    /// The group's length in milliseconds. A running group counts to `nowMS`.
    public func durationMS(nowMS: Int) -> Int {
        max(0, (endMS ?? nowMS) - header.startMS)
    }
}

/// One entry of the redesigned timeline, in session order.
public nonisolated enum VoiceTimelineItem: Equatable, Identifiable, Sendable {
    /// What the user said.
    case you(VoiceTimelineEvent)
    /// What Rafu said, or a Rafu notice.
    case rafu(VoiceTimelineEvent)
    /// A delegation with its steps.
    case group(VoiceTimelineGroup)
    /// A tool or board row made outside any delegation.
    case standalone(VoiceTimelineEvent)

    public var id: String {
        switch self {
        case .you(let event), .rafu(let event), .standalone(let event): event.id
        case .group(let group): group.id
        }
    }
}

/// Builds the capsule list from the flat event list. Pure, so it is testable.
public nonisolated enum VoiceTimelineGrouping {
    /// The newest time the events know, in session milliseconds.
    public static func latestKnownMS(_ events: [VoiceTimelineEvent]) -> Int {
        events.reduce(0) { max($0, $1.endMS ?? $1.startMS, $1.startMS) }
    }

    /// Groups tool and board rows under their delegation: by `delegationID`
    /// when a row has one, else by time (from one delegation's start to the
    /// next delegation's start). Rows before the first delegation stay alone.
    ///
    /// A delegation never gets an end time from the session, so it ends when
    /// its steps have all ended (the end of the last one), when a newer
    /// delegation starts, or when the session closes. `sessionOpen` is the
    /// session state: a closed session leaves nothing running.
    public static func items(events: [VoiceTimelineEvent], sessionOpen: Bool)
        -> [VoiceTimelineItem]
    {
        let delegations = events.filter { $0.lane == .delegation }
        let latest = latestKnownMS(events)
        var childrenByID: [String: [VoiceTimelineEvent]] = [:]
        var claimed = Set<String>()
        for row in events where row.lane == .tool || row.lane == .board {
            guard let owner = owner(of: row, in: delegations) else { continue }
            childrenByID[owner.id, default: []].append(row)
            claimed.insert(row.id)
        }

        var items: [VoiceTimelineItem] = []
        for event in events {
            switch event.lane {
            case .you: items.append(.you(event))
            case .voice: items.append(.rafu(event))
            case .tool, .board:
                if !claimed.contains(event.id) { items.append(.standalone(event)) }
            case .delegation:
                let children = childrenByID[event.id] ?? []
                let next = delegations.first { $0.startMS > event.startMS && $0.id != event.id }
                items.append(
                    .group(
                        group(
                            event, children: children, nextStartMS: next?.startMS,
                            latestMS: latest, sessionOpen: sessionOpen)))
            }
        }
        return items
    }

    private static func owner(of row: VoiceTimelineEvent, in delegations: [VoiceTimelineEvent])
        -> VoiceTimelineEvent?
    {
        if let id = row.delegationID,
            let match = delegations.first(where: { $0.delegationID == id })
        {
            return match
        }
        return delegations.last { $0.startMS <= row.startMS }
    }

    private static func group(
        _ header: VoiceTimelineEvent, children: [VoiceTimelineEvent], nextStartMS: Int?,
        latestMS: Int, sessionOpen: Bool
    ) -> VoiceTimelineGroup {
        let allEnded = children.allSatisfy { $0.endMS != nil }
        let lastEnd = children.compactMap(\.endMS).max()
        let running: Bool
        let end: Int?
        if let explicit = header.endMS {
            running = false
            end = max(explicit, lastEnd ?? explicit)
        } else if !sessionOpen {
            running = false
            end = lastEnd ?? latestMS
        } else if let nextStartMS {
            running = false
            end = lastEnd ?? nextStartMS
        } else if !children.isEmpty, allEnded {
            running = false
            end = lastEnd
        } else {
            running = true
            end = nil
        }
        return VoiceTimelineGroup(
            header: header, children: children, isRunning: running, endMS: end)
    }
}

/// Maps the session's millisecond clock to "now" for running rows. The popover
/// has no clock of its own, so it anchors to the newest time the events know
/// and adds the wall time since it saw that.
public nonisolated struct VoiceTimelineClock: Equatable, Sendable {
    public private(set) var knownMS: Int
    public private(set) var anchor: ContinuousClock.Instant

    public init(knownMS: Int, at anchor: ContinuousClock.Instant) {
        self.knownMS = knownMS
        self.anchor = anchor
    }

    /// Moves the anchor when the known time changes. A lower time means a new
    /// session started, so it resets too.
    public mutating func note(knownMS newer: Int, at instant: ContinuousClock.Instant) {
        guard newer != knownMS else { return }
        knownMS = newer
        anchor = instant
    }

    public func nowMS(at instant: ContinuousClock.Instant) -> Int {
        let components = (instant - anchor).components
        let elapsed =
            Int(components.seconds) * 1_000 + Int(components.attoseconds / 1_000_000_000_000_000)
        return knownMS + max(0, elapsed)
    }
}
