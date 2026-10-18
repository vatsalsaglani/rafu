import Foundation

/// An agent CLI whose lifecycle hooks Rafu can observe. The raw value is the
/// first argument of the hook helper (`rafu-agent-events <provider> <spool>`).
public enum AgentHookProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// The hook events Rafu registers in the provider's configuration. The
    /// helper ignores every other event name.
    public var hookEventNames: [String] {
        switch self {
        case .cursor:
            return AgentHookCursorInput.eventNames
        case .claude:
            return Self.commonEventNames + ["Notification", "PostToolUseFailure", "StopFailure"]
        case .codex:
            return Self.commonEventNames + ["Interrupt"]
        }
    }

    private static let commonEventNames = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SubagentStart", "SubagentStop",
    ]
}

/// Why a hook payload was not turned into an event. The helper drops the
/// payload in every case; it never reports the reason to the agent.
public enum AgentHookEventError: Error, Equatable, Sendable {
    case payloadTooLarge
    case notAnObject
    case missingSession
    case unknownEvent
}

/// One normalized hook event (schema version 1). The helper writes it to the
/// private spool as one small JSON file; the app reads, folds, and deletes it.
///
/// Only identity, lifecycle, and a bounded preview are kept. Prompts, tool
/// inputs, tool outputs, and transcripts are discarded at the helper.
public struct AgentHookEvent: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    /// The largest stdin payload the helper accepts.
    public static let maximumPayloadBytes = 1_048_576
    /// The largest assistant-message preview kept for `Stop`.
    public static let maximumMessageLength = 600
    public static let maximumCwdLength = 2_048
    public static let maximumFieldLength = 256
    /// The longest process ancestry chain recorded (PIDs only).
    public static let maximumAncestors = 16

    public var schemaVersion: Int
    public let id: UUID
    public let provider: AgentHookProvider
    public let sessionID: String
    public let turnID: String?
    /// Set for an event from a subagent (Claude `agent_id`).
    public let subagentID: String?
    /// The provider-neutral event name (Cursor names are mapped).
    public let hookEventName: String
    public let cwd: String
    public let toolName: String?
    public let notificationType: String?
    public let toolUseID: String?
    /// At most `maximumMessageLength` characters, for `Stop` and
    /// `AgentResponse` only.
    public let lastAssistantMessage: String?
    /// The helper's parent PID chain, nearest first. Used only to match the
    /// session to a Rafu terminal; never a command line or environment.
    public var ancestorProcessIDs: [Int32]
    public let time: Date

    public init(
        id: UUID = UUID(),
        provider: AgentHookProvider,
        sessionID: String,
        turnID: String? = nil,
        subagentID: String? = nil,
        hookEventName: String,
        cwd: String = "",
        toolName: String? = nil,
        notificationType: String? = nil,
        toolUseID: String? = nil,
        lastAssistantMessage: String? = nil,
        ancestorProcessIDs: [Int32] = [],
        time: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.subagentID = subagentID
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.toolName = toolName
        self.notificationType = notificationType
        self.toolUseID = toolUseID
        self.lastAssistantMessage = lastAssistantMessage
        self.ancestorProcessIDs = Array(ancestorProcessIDs.prefix(Self.maximumAncestors))
        self.time = time
    }

    /// Normalizes one hook payload from `provider`. Throws for anything that
    /// is not a known event with a session id; the helper then writes
    /// nothing.
    public init(
        provider: AgentHookProvider,
        payload: Data,
        id: UUID = UUID(),
        time: Date = Date()
    ) throws {
        guard payload.count <= Self.maximumPayloadBytes else {
            throw AgentHookEventError.payloadTooLarge
        }
        guard let raw = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw AgentHookEventError.notAnObject
        }
        let object = provider == .cursor ? try AgentHookCursorInput.normalize(raw) : raw
        guard let event = object["hook_event_name"] as? String else {
            throw AgentHookEventError.unknownEvent
        }
        guard provider == .cursor || provider.hookEventNames.contains(event) else {
            throw AgentHookEventError.unknownEvent
        }
        guard let session = Self.text(object["session_id"], limit: Self.maximumFieldLength),
            !session.isEmpty
        else { throw AgentHookEventError.missingSession }
        let keepsMessage = ["Stop", "AgentResponse"].contains(event)
        self.init(
            id: id,
            provider: provider,
            sessionID: session,
            turnID: Self.text(object["turn_id"], limit: Self.maximumFieldLength),
            subagentID: Self.text(object["agent_id"], limit: Self.maximumFieldLength),
            hookEventName: event,
            cwd: Self.text(object["cwd"], limit: Self.maximumCwdLength) ?? "",
            toolName: Self.text(object["tool_name"], limit: Self.maximumFieldLength),
            notificationType: Self.text(
                object["notification_type"], limit: Self.maximumFieldLength),
            toolUseID: Self.text(object["tool_use_id"], limit: Self.maximumFieldLength),
            lastAssistantMessage: keepsMessage
                ? Self.text(
                    object["last_assistant_message"], limit: Self.maximumMessageLength,
                    keepsLines: true)
                : nil,
            time: time)
    }

    /// `provider:session`, the ledger key.
    public var sessionKey: String { provider.rawValue + ":" + sessionID }

    /// A bounded string with control characters removed. Line breaks and
    /// tabs survive only when `keepsLines` is set.
    static func text(_ value: Any?, limit: Int, keepsLines: Bool = false) -> String? {
        guard let value = value as? String else { return nil }
        let scalars = value.unicodeScalars.filter { scalar in
            if keepsLines, scalar == "\n" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        var result = String(scalars)
        if result.count > limit { result = String(result.prefix(limit)) }
        return result
    }
}

/// Cursor's hook JSON uses its own event names and keys. It is mapped to the
/// Claude/Codex shape before the shared normalization. Only the final
/// response preview is kept; no transcript or tool body is read.
public enum AgentHookCursorInput {
    public static let eventNames = [
        "sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse",
        "postToolUseFailure", "subagentStart", "subagentStop", "afterAgentResponse", "stop",
    ]

    static func normalize(_ input: [String: Any]) throws -> [String: Any] {
        guard let name = input["hook_event_name"] as? String, eventNames.contains(name) else {
            throw AgentHookEventError.unknownEvent
        }
        let mapped: String
        switch name {
        case "sessionStart": mapped = "SessionStart"
        case "sessionEnd": mapped = "SessionEnd"
        case "beforeSubmitPrompt": mapped = "UserPromptSubmit"
        case "preToolUse": mapped = "PreToolUse"
        case "postToolUse": mapped = "PostToolUse"
        case "postToolUseFailure": mapped = "PostToolUseFailure"
        case "subagentStart": mapped = "SubagentStart"
        case "afterAgentResponse": mapped = "AgentResponse"
        case "stop", "subagentStop":
            switch input["status"] as? String {
            case "completed": mapped = name == "stop" ? "Stop" : "SubagentStop"
            case "aborted": mapped = "Interrupt"
            case "error": mapped = "StopFailure"
            default: throw AgentHookEventError.unknownEvent
            }
        default:
            throw AgentHookEventError.unknownEvent
        }
        var result: [String: Any] = ["hook_event_name": mapped]
        result["session_id"] = input["conversation_id"] ?? input["session_id"]
        result["turn_id"] = input["generation_id"]
        result["cwd"] = input["cwd"] ?? (input["workspace_roots"] as? [String])?.first
        result["tool_name"] = input["tool_name"]
        result["tool_use_id"] = input["tool_use_id"]
        if name == "subagentStart" || name == "subagentStop" {
            result["agent_id"] = input["agent_id"]
        }
        if name == "afterAgentResponse" { result["last_assistant_message"] = input["text"] }
        return result
    }
}
