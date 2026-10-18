import Foundation

/// One displayable entry of an opened transcript.
public struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public enum Kind: String, Sendable {
        /// A prompt or a reply; Markdown text.
        case message
        /// A slash command the user ran (`/review`, …).
        case command
        /// A tool call. `text` is a one-line summary; `detail` the arguments.
        case toolCall
        /// A tool result. `text` is a one-line preview; `detail` the output.
        case toolResult
        /// Model reasoning. Hidden by default.
        case thinking
    }

    /// The position in the transcript (0-based). Stable for one load.
    public let id: Int
    public let role: Role
    public let kind: Kind
    public let text: String
    public let detail: String?
    public let toolName: String?
    public let isError: Bool
    public let timestamp: Date?
    /// `text` or `detail` was cut to the per-item limit.
    public let isTruncated: Bool

    public init(
        id: Int, role: Role, kind: Kind, text: String, detail: String? = nil,
        toolName: String? = nil, isError: Bool = false, timestamp: Date? = nil,
        isTruncated: Bool = false
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.detail = detail
        self.toolName = toolName
        self.isError = isError
        self.timestamp = timestamp
        self.isTruncated = isTruncated
    }

    /// Prompts and replies, the entries a message-text search looks at.
    public var isConversation: Bool { kind == .message || kind == .command }
}

/// Upper bounds for opening one transcript.
public struct AgentTranscriptLimits: Equatable, Sendable {
    public var maximumBytes: Int
    public var maximumItems: Int
    public var maximumMessageCharacters: Int
    public var maximumDetailCharacters: Int

    public init(
        maximumBytes: Int = 20 << 20,
        maximumItems: Int = 5_000,
        maximumMessageCharacters: Int = 100_000,
        maximumDetailCharacters: Int = 16_384
    ) {
        self.maximumBytes = maximumBytes
        self.maximumItems = maximumItems
        self.maximumMessageCharacters = maximumMessageCharacters
        self.maximumDetailCharacters = maximumDetailCharacters
    }

    public static let standard = AgentTranscriptLimits()
    /// Smaller bounds for a message-text search across many sessions.
    public static let search = AgentTranscriptLimits(
        maximumBytes: 8 << 20, maximumItems: 5_000, maximumMessageCharacters: 100_000,
        maximumDetailCharacters: 0)
}

/// A parsed, bounded transcript. Owned by the one tab that shows it.
public struct AgentTranscript: Equatable, Sendable {
    public enum TruncationReason: String, Sendable {
        case byteLimit
        case itemLimit
    }

    public let key: AgentHistorySessionKey
    public let items: [AgentTranscriptItem]
    /// Set when a limit stopped the read; the visible list is the start of
    /// the session only.
    public let truncation: TruncationReason?
    /// Lines that were not valid JSON objects (skipped).
    public let skippedLineCount: Int

    public var isTruncated: Bool { truncation != nil }

    public init(
        key: AgentHistorySessionKey, items: [AgentTranscriptItem],
        truncation: TruncationReason?, skippedLineCount: Int
    ) {
        self.key = key
        self.items = items
        self.truncation = truncation
        self.skippedLineCount = skippedLineCount
    }

    /// Items whose text (or, for tool items, detail) contains `query`.
    /// Thinking is searched only when `includeThinking` is set.
    public func matchingItemIDs(_ query: String, includeThinking: Bool) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.compactMap { item in
            if item.kind == .thinking, !includeThinking { return nil }
            if item.text.range(of: needle, options: options) != nil { return item.id }
            if let detail = item.detail, detail.range(of: needle, options: options) != nil {
                return item.id
            }
            return nil
        }
    }

    /// `true` when a prompt or reply contains `query`.
    public func conversationContains(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.contains { item in
            item.isConversation && item.text.range(of: needle, options: options) != nil
        }
    }
}

/// Collects items while a parser walks the lines, and enforces the limits.
struct AgentTranscriptBuilder {
    let limits: AgentTranscriptLimits
    private(set) var items: [AgentTranscriptItem] = []
    private(set) var isFull = false

    init(limits: AgentTranscriptLimits) {
        self.limits = limits
    }

    mutating func append(
        role: AgentTranscriptItem.Role, kind: AgentTranscriptItem.Kind, text: String,
        detail: String? = nil, toolName: String? = nil, isError: Bool = false,
        timestamp: Date? = nil
    ) {
        guard !isFull else { return }
        let textLimit =
            kind == .message || kind == .thinking ? limits.maximumMessageCharacters : 400
        let body = AgentHistoryText.bounded(text, limit: textLimit)
        var boundedDetail: String?
        var detailCut = false
        if let detail, limits.maximumDetailCharacters > 0 {
            let cut = AgentHistoryText.bounded(detail, limit: limits.maximumDetailCharacters)
            boundedDetail = cut.text
            detailCut = cut.truncated
        }
        items.append(
            AgentTranscriptItem(
                id: items.count, role: role, kind: kind, text: body.text, detail: boundedDetail,
                toolName: toolName, isError: isError, timestamp: timestamp,
                isTruncated: body.truncated || detailCut))
        if items.count >= limits.maximumItems { isFull = true }
    }
}

/// Opens one transcript off the main actor.
public enum AgentTranscriptLoader {
    @concurrent
    public static func load(
        _ session: AgentHistorySessionSummary, limits: AgentTranscriptLimits = .standard
    ) async throws -> AgentTranscript {
        try load(fileURL: session.fileURL, key: session.key, limits: limits)
    }

    /// Synchronous core, shared by the loader and the message-text search.
    static func load(
        fileURL: URL, key: AgentHistorySessionKey, limits: AgentTranscriptLimits
    ) throws -> AgentTranscript {
        switch key.provider {
        case .claudeCode:
            return try ClaudeCodeHistoryParser.transcript(
                fileURL: fileURL, key: key, limits: limits)
        case .codex:
            return try CodexHistoryParser.transcript(fileURL: fileURL, key: key, limits: limits)
        }
    }
}
