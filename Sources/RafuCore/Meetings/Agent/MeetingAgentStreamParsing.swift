import Foundation

/// What the reader does after a parser saw one line.
public enum MeetingAgentStreamVerdict: Hashable, Sendable {
    /// Read on.
    case more
    /// End the process now: the parser has seen enough (a refused init
    /// event, not signed in, a setting that no longer works, a tool that
    /// Rafu does not allow).
    case stop
}

/// A piece of streamed answer text from a parser.
public enum MeetingAgentTextEvent: Hashable, Sendable {
    /// More answer text, already cleaned.
    case delta(String)
    /// The agent started a new message: the streamed text so far is not
    /// the answer.
    case reset
}

/// A parser of one CLI's JSON-lines standard output.
public protocol MeetingAgentStreamParsing: Sendable {
    mutating func consume(line: Data) -> MeetingAgentStreamVerdict
    /// The text events since the last call. A parser that streams no text
    /// returns none.
    mutating func takeTextEvents() -> [MeetingAgentTextEvent]
}

extension MeetingAgentStreamParsing {
    public mutating func takeTextEvents() -> [MeetingAgentTextEvent] { [] }
}

/// Splits standard-output bytes into lines with two bounds: one line, and
/// the whole output.
public struct MeetingAgentLineSplitter: Sendable {
    public enum Problem: Error, Hashable, Sendable {
        case lineTooLong
        case outputTooLarge
    }

    public let maximumLineBytes: Int
    public let maximumOutputBytes: Int
    private var pending = Data()
    private var total = 0

    public init(
        maximumLineBytes: Int = MeetingAgentLimits.maximumLineBytes,
        maximumOutputBytes: Int = MeetingAgentLimits.maximumOutputBytes
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumOutputBytes = maximumOutputBytes
    }

    /// The complete lines in `bytes` and the bytes before them, without the
    /// new line.
    public mutating func append(_ bytes: Data) throws(Problem) -> [Data] {
        total += bytes.count
        guard total <= maximumOutputBytes else { throw .outputTooLarge }
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            guard line.count <= maximumLineBytes else { throw .lineTooLong }
            lines.append(Data(line))
            pending = Data(pending[pending.index(after: newline)...])
        }
        guard pending.count <= maximumLineBytes else { throw .lineTooLong }
        return lines
    }

    /// The last line when the output ended with no new line.
    public mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// A JSON object from one line, or nil when the line is not one.
enum MeetingAgentJSON {
    static func object(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty,
            let value = try? JSONSerialization.jsonObject(with: line, options: [])
        else { return nil }
        return value as? [String: Any]
    }
}

/// Reads the `--output-format stream-json --include-partial-messages`
/// events of Claude Code (shapes in `meeting-hidden-agent-limits.md` and its
/// saved results). It checks the `system`/`init` event before any answer
/// counts: the tools must be exactly Glob, Grep and Read, no MCP server,
/// permission mode `dontAsk`. It streams the text of top-level
/// `text_delta` events after an accepted init event, resets the text at each
/// `message_start`, and stops the run at a tool call outside the three
/// tools. The answer is always the `result` text, never the streamed text.
public struct ClaudeStreamParser: MeetingAgentStreamParsing {
    public enum InitCheck: Hashable, Sendable {
        case notSeen
        case accepted
        case refused
    }

    public static let checkedTools: Set<String> = ["Glob", "Grep", "Read"]
    public static let checkedPermissionMode = "dontAsk"

    public private(set) var initCheck: InitCheck = .notSeen
    /// `claude_code_version` from the init event, for diagnostics.
    public private(set) var cliVersion: String?
    /// The `result` text of the result event.
    public private(set) var resultText: String?
    public private(set) var resultIsError = false
    public private(set) var sawResult = false
    /// The agent called a tool other than Glob, Grep or Read.
    public private(set) var forbiddenTool = false

    private var textEvents: [MeetingAgentTextEvent] = []
    private var streamedBytes = 0

    public init() {}

    /// True for the not-signed-in result: `is_error` with the text "Not
    /// logged in" (its `subtype` is still "success").
    public var notLoggedIn: Bool {
        sawResult && resultIsError && (resultText?.contains("Not logged in") ?? false)
    }

    /// The answer: the result text of a result event that is not an error,
    /// after an accepted init event, with no forbidden tool call.
    public var answer: String? {
        guard initCheck == .accepted, sawResult, !resultIsError, !forbiddenTool else {
            return nil
        }
        return resultText
    }

    public mutating func takeTextEvents() -> [MeetingAgentTextEvent] {
        defer { textEvents = [] }
        return textEvents
    }

    public mutating func consume(line: Data) -> MeetingAgentStreamVerdict {
        guard let event = MeetingAgentJSON.object(line) else { return .more }
        let type = event["type"] as? String
        if type == "system", event["subtype"] as? String == "init" {
            if let version = event["claude_code_version"] as? String { cliVersion = version }
            // A second init event can never turn a refusal into acceptance.
            guard initCheck != .refused else { return .stop }
            initCheck = Self.check(event) ? .accepted : .refused
            return initCheck == .refused ? .stop : .more
        }
        if type == "result" {
            sawResult = true
            resultIsError = (event["is_error"] as? Bool) ?? true
            resultText = event["result"] as? String
            if notLoggedIn { return .stop }
            // A result before an accepted init event is never an answer.
            return initCheck == .accepted ? .more : .stop
        }
        if type == "stream_event", let inner = event["event"] as? [String: Any] {
            let parent = event["parent_tool_use_id"]
            return consumeStreamEvent(inner, topLevel: parent == nil || parent is NSNull)
        }
        if type == "assistant", let message = event["message"] as? [String: Any],
            let content = message["content"] as? [Any]
        {
            for case let block as [String: Any] in content where !Self.isAllowed(block) {
                forbiddenTool = true
                return .stop
            }
        }
        return .more
    }

    private mutating func consumeStreamEvent(_ inner: [String: Any], topLevel: Bool)
        -> MeetingAgentStreamVerdict
    {
        switch inner["type"] as? String {
        case "content_block_start":
            if let block = inner["content_block"] as? [String: Any], !Self.isAllowed(block) {
                forbiddenTool = true
                return .stop
            }
        case "message_start":
            guard topLevel, initCheck == .accepted else { break }
            textEvents.append(.reset)
            streamedBytes = 0
        case "content_block_delta":
            guard topLevel, initCheck == .accepted,
                let delta = inner["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta", let raw = delta["text"] as? String
            else { break }
            let text = MeetingAgentDeltaText.clean(raw)
            guard !text.isEmpty else { break }
            // Past the answer limit the stream shows no more text; the
            // result text decides.
            let bytes = text.utf8.count
            guard streamedBytes + bytes <= MeetingAgentLimits.maximumAnswerBytes else {
                streamedBytes = MeetingAgentLimits.maximumAnswerBytes + 1
                break
            }
            streamedBytes += bytes
            textEvents.append(.delta(text))
        default:
            break
        }
        return .more
    }

    /// A content block is allowed unless it is a tool call (any type that
    /// ends in `tool_use`) to a tool other than Glob, Grep or Read.
    static func isAllowed(_ block: [String: Any]) -> Bool {
        guard let type = block["type"] as? String, type.hasSuffix("tool_use") else { return true }
        guard type == "tool_use", let name = block["name"] as? String else { return false }
        return checkedTools.contains(name)
    }

    static func check(_ event: [String: Any]) -> Bool {
        guard let tools = event["tools"] as? [String], tools.count == checkedTools.count,
            Set(tools) == checkedTools
        else { return false }
        guard let servers = event["mcp_servers"] as? [Any], servers.isEmpty else { return false }
        return event["permissionMode"] as? String == checkedPermissionMode
    }
}

/// Reads the `exec --json` events of Codex (shapes in the saved results of
/// `meeting-hidden-agent-limits.md`, section "Codex with the meeting text on
/// standard input"):
///
/// - `{"type":"turn.started"}`
/// - `{"type":"item.completed","item":{"type":"agent_message","text":…}}`
/// - `{"type":"turn.completed",…}`
/// - `{"type":"error","message":"Reconnecting... (… 401 Unauthorized …)"}`
/// - `{"type":"item.completed","item":{"type":"error","message":"Codex is
///   ignoring 1 unrecognized configuration setting. …"}}`
/// - `{"type":"turn.failed","error":{"message":…}}`
///
/// Each `item.*` event must have the item type `agent_message`, `reasoning`
/// or `error`. Any other item (for example `mcp_tool_call`) stops the run.
/// Codex streams no answer text: `agent_message` comes only as a completed
/// item.
public struct CodexStreamParser: MeetingAgentStreamParsing {
    public static let allowedItemTypes: Set<String> = ["agent_message", "reasoning", "error"]

    public private(set) var notSignedIn = false
    /// A `-c` key or flag that this Codex version no longer knows.
    public private(set) var unrecognizedSetting = false
    public private(set) var turnFailed = false
    public private(set) var turnCompleted = false
    /// An item of a type outside `allowedItemTypes`.
    public private(set) var toolEvent = false
    private var lastMessage: String?

    public init() {}

    /// The last `agent_message` of the completed turn.
    public var answer: String? {
        guard turnCompleted, !turnFailed, !notSignedIn, !unrecognizedSetting, !toolEvent else {
            return nil
        }
        return lastMessage
    }

    public mutating func consume(line: Data) -> MeetingAgentStreamVerdict {
        guard let event = MeetingAgentJSON.object(line) else { return .more }
        let type = event["type"] as? String
        if let type, type.hasPrefix("item.") {
            guard let item = event["item"] as? [String: Any],
                let itemType = item["type"] as? String, Self.allowedItemTypes.contains(itemType)
            else {
                toolEvent = true
                return .stop
            }
            guard type == "item.completed" else { return .more }
            switch itemType {
            case "agent_message":
                if let text = item["text"] as? String { lastMessage = text }
            case "error":
                if let message = item["message"] as? String,
                    message.contains("unrecognized configuration setting")
                {
                    unrecognizedSetting = true
                    return .stop
                }
            default: break
            }
            return .more
        }
        switch type {
        case "turn.started":
            lastMessage = nil
            turnCompleted = false
        case "turn.completed":
            turnCompleted = true
        case "turn.failed":
            turnFailed = true
            let message = (event["error"] as? [String: Any])?["message"] as? String
            if let message, message.contains("401 Unauthorized") { notSignedIn = true }
            return .stop
        case "error":
            if let message = event["message"] as? String, message.contains("401 Unauthorized") {
                notSignedIn = true
                return .stop
            }
        default: break
        }
        return .more
    }
}
