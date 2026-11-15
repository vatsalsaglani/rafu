import Foundation

/// Where one observed agent session is, from its hook events alone.
public enum AgentSessionState: String, Codable, Equatable, Sendable {
    /// A prompt or tool call is in progress.
    case working
    /// The agent asked to run a tool and waits for approval.
    case waitingForPermission
    /// The agent asked a question, or its turn failed and needs the person.
    case needsInput
    /// The turn ended (or the session just started) and the agent is idle.
    case finished
    /// The session ended.
    case ended
}

/// One active sub-agent of a session (ADR 0029 amendment). In memory only:
/// the ledger persists nothing, and nothing here is logged.
public struct TrackedSubagent: Equatable, Identifiable, Sendable {
    /// The provider's sub-agent id (Claude `agent_id`).
    public let id: String
    /// The sub-agent type (`implementor`, `Explore`), when the installed
    /// helper reports it. `nil` from a helper installed before sub-agent
    /// names were tracked, until the person reconnects Activity tracking.
    public internal(set) var type: String?
    /// The model the spawn asked for; `nil` when it inherits the default.
    public internal(set) var model: String?
    /// The spawn's short task description (at most
    /// `AgentHookEvent.maximumSubagentDescriptionLength` characters).
    public internal(set) var taskDescription: String?
    public let startedAt: Date
    public internal(set) var lastEventAt: Date

    public init(
        id: String, type: String? = nil, model: String? = nil, taskDescription: String? = nil,
        startedAt: Date, lastEventAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.model = model
        self.taskDescription = taskDescription
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt ?? startedAt
    }
}

/// A spawn seen in `PreToolUse` whose `SubagentStart` has not arrived yet.
/// The start carries the id; the spawn carries the model and description.
struct PendingSubagentSpawn: Equatable, Sendable {
    let type: String?
    let model: String?
    let taskDescription: String?
    let at: Date
}

/// One agent session, folded from its hook events. Small values only: no
/// prompt, tool input, or transcript is ever stored.
public struct TrackedAgentSession: Equatable, Identifiable, Sendable {
    /// The most active sub-agents kept per session; the least recently
    /// active one drops first.
    public static let maximumSubagents = 16
    /// A sub-agent without events for this long is dropped (one that
    /// crashed without `SubagentStop`).
    public static let subagentStaleInterval: TimeInterval = 10 * 60
    /// A spawn waits this long for its `SubagentStart`.
    static let pendingSpawnLifetime: TimeInterval = 2 * 60
    static let maximumPendingSpawns = 16
    static let maximumStoppedSubagentIDs = 32
    /// After this long without an event, a `working` session is not current.
    public static let staleInterval: TimeInterval = 10 * 60
    /// A reply counts as fresh for this long when no Rafu terminal owns it.
    public static let replyFreshInterval: TimeInterval = 2 * 60

    public let provider: AgentHookProvider
    public let sessionID: String
    /// A stable row identity for lists, made when the session is first seen.
    public let rowID: UUID
    public internal(set) var state: AgentSessionState
    public internal(set) var cwd: String
    public internal(set) var lastTool: String?
    /// At most `AgentHookEvent.maximumMessageLength` characters.
    public internal(set) var lastMessagePreview: String?
    public internal(set) var lastEventName: String
    public internal(set) var turnID: String?
    /// The `Stop` event that produced the current reply; `nil` when the
    /// session is idle without a new reply.
    public internal(set) var replyEventID: UUID?
    public internal(set) var replyAt: Date?
    /// The helper's parent PID chain from the newest event that had one.
    public internal(set) var ancestorProcessIDs: [Int32]
    public let startedAt: Date
    public internal(set) var updatedAt: Date
    /// Active sub-agents, in start order. A parent `Stop` keeps them
    /// (background sub-agents outlive the turn); `SubagentStop`,
    /// `SessionEnd`, and `subagentStaleInterval` of silence remove them.
    public internal(set) var subagents: [TrackedSubagent] = []
    var pendingSpawns: [PendingSubagentSpawn] = []
    /// Recently stopped sub-agent ids, so a late event never revives one.
    var stoppedSubagentIDs: [String] = []

    public init(
        provider: AgentHookProvider,
        sessionID: String,
        rowID: UUID = UUID(),
        state: AgentSessionState = .finished,
        cwd: String = "",
        lastTool: String? = nil,
        lastMessagePreview: String? = nil,
        lastEventName: String = "",
        turnID: String? = nil,
        replyEventID: UUID? = nil,
        replyAt: Date? = nil,
        ancestorProcessIDs: [Int32] = [],
        startedAt: Date,
        updatedAt: Date? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.rowID = rowID
        self.state = state
        self.cwd = cwd
        self.lastTool = lastTool
        self.lastMessagePreview = lastMessagePreview
        self.lastEventName = lastEventName
        self.turnID = turnID
        self.replyEventID = replyEventID
        self.replyAt = replyAt
        self.ancestorProcessIDs = ancestorProcessIDs
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    /// `provider:session`.
    public var id: String { provider.rawValue + ":" + sessionID }

    /// The agent waits for the person: approval or an answer.
    public var needsAttention: Bool {
        state == .waitingForPermission || state == .needsInput
    }

    /// A `working` session whose events stopped arriving.
    public func isStale(at now: Date) -> Bool {
        state == .working && now.timeIntervalSince(updatedAt) > Self.staleInterval
    }

    /// The session finished a turn with a reply within `replyFreshInterval`.
    public func hasFreshReply(at now: Date) -> Bool {
        guard state == .finished, replyEventID != nil, let replyAt else { return false }
        let age = now.timeIntervalSince(replyAt)
        return age >= 0 && age < Self.replyFreshInterval
    }

    /// The last path component of `cwd`, for display.
    public var projectName: String {
        cwd.isEmpty ? "Unknown folder" : URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Folds hook events into sessions. Pure and bounded: the same events in
/// the same order always give the same sessions.
public struct AgentSessionLedger: Equatable, Sendable {
    public static let maximumSessions = 256
    public static let maximumSeenEvents = 4_096
    /// An ended session stays visible this long.
    public static let endedRetention: TimeInterval = 2 * 60
    /// Any session without events for this long is dropped.
    public static let idleRetention: TimeInterval = 6 * 60 * 60

    /// Claude and Codex tools that ask the person a question.
    static let questionTools: Set<String> = [
        "AskUserQuestion", "request_user_input", "functions.request_user_input",
    ]

    public private(set) var sessionsByKey: [String: TrackedAgentSession] = [:]
    private var seenOrder: [UUID] = []
    private var seen: Set<UUID> = []

    public init() {}

    /// Sessions that need the person first, then the most recently updated.
    public var sessions: [TrackedAgentSession] {
        sessionsByKey.values.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    /// Applies one event. Returns `false` when it changed nothing: a
    /// duplicate, an unknown schema, an event older than the session's
    /// newest, or a late event from an earlier turn.
    @discardableResult
    public mutating func apply(_ event: AgentHookEvent) -> Bool {
        guard event.schemaVersion == AgentHookEvent.currentSchemaVersion,
            !seen.contains(event.id)
        else { return false }
        remember(event.id)
        var row =
            sessionsByKey[event.sessionKey]
            ?? TrackedAgentSession(
                provider: event.provider, sessionID: event.sessionID, cwd: event.cwd,
                lastEventName: event.hookEventName, startedAt: event.time)
        // Sub-agent bookkeeping runs before the order and turn guards: each
        // sub-agent's helper process writes its own events, a Codex child
        // can carry its own turn id, and a background sub-agent outlives
        // the parent's turn. It never changes the parent's state.
        let subagentsChanged = Self.foldSubagent(event, into: &row)
        let startsTurn = ["UserPromptSubmit", "SessionStart"].contains(event.hookEventName)
        let isLateTurn =
            row.turnID != nil && event.turnID != nil && row.turnID != event.turnID && !startsTurn
        guard event.time >= row.updatedAt, !isLateTurn else {
            guard subagentsChanged else { return false }
            sessionsByKey[event.sessionKey] = row
            evictOverflow()
            return true
        }
        row.updatedAt = event.time
        row.lastEventName = event.hookEventName
        if !event.cwd.isEmpty { row.cwd = event.cwd }
        if let turn = event.turnID { row.turnID = turn }
        if !event.ancestorProcessIDs.isEmpty { row.ancestorProcessIDs = event.ancestorProcessIDs }
        if let tool = event.toolName { row.lastTool = tool }
        Self.fold(event, into: &row)
        if event.hookEventName == "SessionEnd", event.subagentID == nil {
            row.subagents = []
            row.pendingSpawns = []
        }
        sessionsByKey[event.sessionKey] = row
        evictOverflow()
        return true
    }

    /// Updates `row`'s sub-agent list for `event`. Returns whether the row
    /// changed. A spawn `PreToolUse` queues its type, model, and
    /// description; the next `SubagentStart` of that type claims them.
    private static func foldSubagent(_ event: AgentHookEvent, into row: inout TrackedAgentSession)
        -> Bool
    {
        var changed = false
        if event.isSubagentSpawn {
            row.pendingSpawns.append(
                PendingSubagentSpawn(
                    type: event.subagentType, model: event.subagentModel,
                    taskDescription: event.subagentDescription, at: event.time))
            if row.pendingSpawns.count > TrackedAgentSession.maximumPendingSpawns {
                row.pendingSpawns.removeFirst(
                    row.pendingSpawns.count - TrackedAgentSession.maximumPendingSpawns)
            }
            changed = true
        }
        guard let id = event.subagentID else { return changed }
        if event.hookEventName == "SubagentStop" {
            if let index = row.subagents.firstIndex(where: { $0.id == id }) {
                row.subagents.remove(at: index)
                changed = true
            }
            if !row.stoppedSubagentIDs.contains(id) {
                row.stoppedSubagentIDs.append(id)
                let overflow =
                    row.stoppedSubagentIDs.count - TrackedAgentSession.maximumStoppedSubagentIDs
                if overflow > 0 { row.stoppedSubagentIDs.removeFirst(overflow) }
            }
            return changed
        }
        guard !row.stoppedSubagentIDs.contains(id) else { return changed }
        // On a spawn from inside a sub-agent, the type names the child.
        let type = event.isSubagentSpawn ? nil : event.subagentType
        let starts = event.hookEventName == "SubagentStart"
        if let index = row.subagents.firstIndex(where: { $0.id == id }) {
            var subagent = row.subagents[index]
            if event.time > subagent.lastEventAt { subagent.lastEventAt = event.time }
            if subagent.type == nil, let type { subagent.type = type }
            if starts, subagent.taskDescription == nil, subagent.model == nil {
                claimSpawn(for: &subagent, in: &row)
            }
            if subagent != row.subagents[index] {
                row.subagents[index] = subagent
                changed = true
            }
            return changed
        }
        // Rafu may start watching mid-run: any sub-agent event adds it.
        var subagent = TrackedSubagent(id: id, type: type, startedAt: event.time)
        if starts { claimSpawn(for: &subagent, in: &row) }
        row.subagents.append(subagent)
        while row.subagents.count > TrackedAgentSession.maximumSubagents,
            let oldest = row.subagents.indices.min(by: {
                row.subagents[$0].lastEventAt < row.subagents[$1].lastEventAt
            })
        {
            row.subagents.remove(at: oldest)
        }
        return true
    }

    /// Moves the oldest pending spawn of `subagent`'s type (else the oldest
    /// spawn that named no type) onto `subagent`.
    private static func claimSpawn(
        for subagent: inout TrackedSubagent, in row: inout TrackedAgentSession
    ) {
        let index =
            row.pendingSpawns.firstIndex(where: { $0.type != nil && $0.type == subagent.type })
            ?? row.pendingSpawns.firstIndex(where: { $0.type == nil })
        guard let index else { return }
        let spawn = row.pendingSpawns.remove(at: index)
        if subagent.type == nil { subagent.type = spawn.type }
        subagent.model = spawn.model
        subagent.taskDescription = spawn.taskDescription
    }

    /// Drops ended sessions after `endedRetention` and every session after
    /// `idleRetention` without events. Returns whether anything was dropped.
    /// Also drops sub-agents silent for `subagentStaleInterval` and spawns
    /// that waited `pendingSpawnLifetime` for their start.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = sessionsByKey.count
        sessionsByKey = sessionsByKey.filter { _, row in
            let age = now.timeIntervalSince(row.updatedAt)
            if row.state == .ended { return age < Self.endedRetention }
            return age < Self.idleRetention
        }
        var changed = sessionsByKey.count != before
        for (key, row) in sessionsByKey where !row.subagents.isEmpty || !row.pendingSpawns.isEmpty {
            var updated = row
            updated.subagents.removeAll {
                now.timeIntervalSince($0.lastEventAt) > TrackedAgentSession.subagentStaleInterval
            }
            updated.pendingSpawns.removeAll {
                now.timeIntervalSince($0.at) > TrackedAgentSession.pendingSpawnLifetime
            }
            guard updated != row else { continue }
            if updated.subagents.count != row.subagents.count { changed = true }
            sessionsByKey[key] = updated
        }
        return changed
    }

    private static func fold(_ event: AgentHookEvent, into row: inout TrackedAgentSession) {
        // A subagent's events keep the parent busy; they never finish it. A
        // subagent that stops says nothing about the parent's turn.
        if event.subagentID != nil || event.hookEventName.hasPrefix("Subagent") {
            switch event.hookEventName {
            case "PermissionRequest": row.state = .waitingForPermission
            case "SessionEnd", "SubagentStop", "Stop": break
            default: if row.state != .ended { row.state = .working }
            }
            return
        }
        switch event.hookEventName {
        case "SessionStart":
            row.state = .finished
            row.replyEventID = nil
        case "UserPromptSubmit":
            row.state = .working
            row.replyEventID = nil
        case "PreToolUse":
            let asks = event.toolName.map(questionTools.contains) ?? false
            row.state = asks ? .needsInput : .working
        case "PostToolUse", "PostToolUseFailure":
            row.state = .working
        case "PermissionRequest":
            row.state = .waitingForPermission
        case "Notification":
            switch event.notificationType {
            case "permission_prompt": row.state = .waitingForPermission
            case "idle_prompt", "elicitation_dialog": row.state = .needsInput
            default: break
            }
        case "Stop":
            row.state = .finished
            row.replyEventID = event.id
            row.replyAt = event.time
            if let message = event.lastAssistantMessage { row.lastMessagePreview = message }
        case "AgentResponse":
            if let message = event.lastAssistantMessage { row.lastMessagePreview = message }
        case "Interrupt":
            row.state = .finished
            row.replyEventID = nil
        case "StopFailure":
            row.state = .needsInput
            row.replyEventID = nil
        case "SessionEnd":
            row.state = .ended
            row.replyEventID = nil
        default:
            break
        }
    }

    private mutating func remember(_ id: UUID) {
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > Self.maximumSeenEvents {
            let overflow = seenOrder.count - Self.maximumSeenEvents
            for old in seenOrder.prefix(overflow) { seen.remove(old) }
            seenOrder.removeFirst(overflow)
        }
    }

    private mutating func evictOverflow() {
        while sessionsByKey.count > Self.maximumSessions,
            let oldest = sessionsByKey.values.min(by: { $0.updatedAt < $1.updatedAt })
        {
            sessionsByKey.removeValue(forKey: oldest.id)
        }
    }
}
