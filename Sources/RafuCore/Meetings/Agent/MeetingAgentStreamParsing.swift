import Foundation

/// What the reader does after a parser saw one line.
public enum MeetingAgentStreamVerdict: Hashable, Sendable {
    /// Read on.
    case more
    /// End the process now: the parser has seen enough (a refused init
    /// event, not signed in, a setting that no longer works).
    case stop
}

/// A parser of one CLI's JSON-lines standard output.
public protocol MeetingAgentStreamParsing: Sendable {
    mutating func consume(line: Data) -> MeetingAgentStreamVerdict
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

/// Reads the `--output-format stream-json` events of Claude Code (shapes in
/// `meeting-hidden-agent-limits.md` and its saved results). It checks the
/// `system`/`init` event before any answer counts: the tools must be
/// exactly Glob, Grep and Read, no MCP server, permission mode `dontAsk`.
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

    public init() {}

    /// True for the not-signed-in result: `is_error` with the text "Not
    /// logged in" (its `subtype` is still "success").
    public var notLoggedIn: Bool {
        sawResult && resultIsError && (resultText?.contains("Not logged in") ?? false)
    }

    /// The answer: the result text of a result event that is not an error,
    /// after an accepted init event.
    public var answer: String? {
        guard initCheck == .accepted, sawResult, !resultIsError else { return nil }
        return resultText
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
        return .more
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
public struct CodexStreamParser: MeetingAgentStreamParsing {
    public private(set) var notSignedIn = false
    /// A `-c` key or flag that this Codex version no longer knows.
    public private(set) var unrecognizedSetting = false
    public private(set) var turnFailed = false
    public private(set) var turnCompleted = false
    private var lastMessage: String?

    public init() {}

    /// The last `agent_message` of the completed turn.
    public var answer: String? {
        guard turnCompleted, !turnFailed, !notSignedIn, !unrecognizedSetting else { return nil }
        return lastMessage
    }

    public mutating func consume(line: Data) -> MeetingAgentStreamVerdict {
        guard let event = MeetingAgentJSON.object(line) else { return .more }
        switch event["type"] as? String {
        case "turn.started":
            lastMessage = nil
            turnCompleted = false
        case "item.completed":
            guard let item = event["item"] as? [String: Any] else { return .more }
            switch item["type"] as? String {
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
