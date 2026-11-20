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
/// inputs, tool outputs, and transcripts are discarded at the helper. The
/// one exception is a sub-agent spawn (Claude's `Agent`/`Task` tool): its
/// sub-agent type, model, and short task description are kept, sanitized
/// and length-capped; its prompt is never read.
///
/// The sub-agent fields are optional, so the schema stays version 1: an
/// event from an older installed helper decodes with them `nil`.
///
/// The second exception is the answer mode of the helper
/// (`rafu-agent-events claude <spool> --answer`): a Claude Code
/// `PermissionRequest` then carries a sanitized, bounded `requestSummary`
/// (see `AgentPermissionRequestSummary`) so Up next can show what is asked.
/// The normal helper mode never sets it.
public struct AgentHookEvent: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    /// The longest sub-agent type or model name kept.
    public static let maximumSubagentLabelLength = 64
    /// The longest sub-agent task description kept, ellipsis included.
    public static let maximumSubagentDescriptionLength = 80
    /// Claude Code tools that start a sub-agent (`Task` before 2.x).
    public static let subagentSpawnToolNames: Set<String> = ["Agent", "Task"]
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
    /// The sub-agent's type (`implementor`, `Explore`): from `agent_type` on
    /// an event with `agent_id`, or from the spawn tool's `subagent_type`
    /// on a spawn `PreToolUse` (`isSubagentSpawn`). A config name, filtered
    /// to `[A-Za-z0-9 _.:-]`, at most `maximumSubagentLabelLength`.
    public let subagentType: String?
    /// The model the spawn asked for, when it named one. Spawn only.
    public let subagentModel: String?
    /// The spawn's short task description, on one line, at most
    /// `maximumSubagentDescriptionLength` characters. Spawn only. Comes
    /// from the agent's prompt-side input, so it is kept in memory only and
    /// never logged.
    public let subagentDescription: String?
    /// The command or file a Claude `PermissionRequest` asks about. Set only
    /// by the helper's answer mode; kept in memory only, never logged.
    public let requestSummary: AgentPermissionRequestSummary?

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
        time: Date = Date(),
        subagentType: String? = nil,
        subagentModel: String? = nil,
        subagentDescription: String? = nil,
        requestSummary: AgentPermissionRequestSummary? = nil
    ) {
        self.requestSummary = requestSummary
        self.subagentType = subagentType
        self.subagentModel = subagentModel
        self.subagentDescription = subagentDescription
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
    /// nothing. `includesRequestSummary` is set only by the helper's answer
    /// mode; it reads a Claude `PermissionRequest`'s command or file path.
    public init(
        provider: AgentHookProvider,
        payload: Data,
        id: UUID = UUID(),
        time: Date = Date(),
        includesRequestSummary: Bool = false
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
        let subagentID = Self.text(object["agent_id"], limit: Self.maximumFieldLength)
        let toolName = Self.text(object["tool_name"], limit: Self.maximumFieldLength)
        let isSpawn = Self.isSubagentSpawn(provider: provider, event: event, toolName: toolName)
        // Only these three keys of a spawn's tool input are read; never
        // `prompt` or any other tool input.
        let spawn = isSpawn ? object["tool_input"] as? [String: Any] : nil
        let subagentType =
            isSpawn
            ? Self.subagentLabel(spawn?["subagent_type"])
            : (subagentID == nil ? nil : Self.subagentLabel(object["agent_type"]))
        self.init(
            id: id,
            provider: provider,
            sessionID: session,
            turnID: Self.text(object["turn_id"], limit: Self.maximumFieldLength),
            subagentID: subagentID,
            hookEventName: event,
            cwd: Self.text(object["cwd"], limit: Self.maximumCwdLength) ?? "",
            toolName: toolName,
            notificationType: Self.text(
                object["notification_type"], limit: Self.maximumFieldLength),
            toolUseID: Self.text(object["tool_use_id"], limit: Self.maximumFieldLength),
            lastAssistantMessage: keepsMessage
                ? Self.text(
                    object["last_assistant_message"], limit: Self.maximumMessageLength,
                    keepsLines: true)
                : nil,
            time: time,
            subagentType: subagentType,
            subagentModel: isSpawn ? Self.subagentLabel(spawn?["model"]) : nil,
            subagentDescription: isSpawn ? Self.subagentDescription(spawn?["description"]) : nil,
            requestSummary: includesRequestSummary && provider == .claude
                && event == "PermissionRequest"
                ? AgentPermissionRequestSummary(
                    toolName: toolName, toolInput: object["tool_input"])
                : nil)
    }

    /// `provider:session`, the ledger key.
    public var sessionKey: String { provider.rawValue + ":" + sessionID }

    /// This event is a Claude Code `PreToolUse` of a tool that starts a
    /// sub-agent. Its sub-agent fields describe the sub-agent about to
    /// start, not the agent that sent the event.
    public var isSubagentSpawn: Bool {
        Self.isSubagentSpawn(provider: provider, event: hookEventName, toolName: toolName)
    }

    static func isSubagentSpawn(provider: AgentHookProvider, event: String, toolName: String?)
        -> Bool
    {
        provider == .claude && event == "PreToolUse"
            && toolName.map(subagentSpawnToolNames.contains) == true
    }

    /// A sub-agent type or model name: a config name, not prose. Keeps
    /// `[A-Za-z0-9 _.:-]` only, trims, caps at
    /// `maximumSubagentLabelLength`; `nil` when nothing is left.
    public static func subagentLabel(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _.:-")
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter(allowed.contains)))
        let trimmed = String(
            kept.trimmingCharacters(in: .whitespaces).prefix(maximumSubagentLabelLength)
        )
        .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A sub-agent's short task description: control characters removed,
    /// whitespace runs folded to one space, trimmed, and capped at
    /// `maximumSubagentDescriptionLength` characters with an ellipsis;
    /// `nil` when nothing is left.
    public static func subagentDescription(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        // Read at most a bounded prefix: the cap is tiny.
        let bounded = value.prefix(maximumFieldLength * 4)
        var scalars = String.UnicodeScalarView()
        for scalar in bounded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let joined = String(scalars).split(separator: " ").joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        let limit = maximumSubagentDescriptionLength
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit - 1).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

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
