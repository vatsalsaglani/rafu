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

/// One agent session, folded from its hook events. Small values only: no
/// prompt, tool input, or transcript is ever stored.
public struct TrackedAgentSession: Equatable, Identifiable, Sendable {
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
        guard event.time >= row.updatedAt else { return false }
        let startsTurn = ["UserPromptSubmit", "SessionStart"].contains(event.hookEventName)
        if let current = row.turnID, let incoming = event.turnID, current != incoming,
            !startsTurn
        {
            return false
        }
        row.updatedAt = event.time
        row.lastEventName = event.hookEventName
        if !event.cwd.isEmpty { row.cwd = event.cwd }
        if let turn = event.turnID { row.turnID = turn }
        if !event.ancestorProcessIDs.isEmpty { row.ancestorProcessIDs = event.ancestorProcessIDs }
        if let tool = event.toolName { row.lastTool = tool }
        Self.fold(event, into: &row)
        sessionsByKey[event.sessionKey] = row
        evictOverflow()
        return true
    }

    /// Drops ended sessions after `endedRetention` and every session after
    /// `idleRetention` without events. Returns whether anything was dropped.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = sessionsByKey.count
        sessionsByKey = sessionsByKey.filter { _, row in
            let age = now.timeIntervalSince(row.updatedAt)
            if row.state == .ended { return age < Self.endedRetention }
            return age < Self.idleRetention
        }
        return sessionsByKey.count != before
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
