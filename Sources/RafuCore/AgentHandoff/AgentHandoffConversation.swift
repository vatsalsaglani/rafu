import Foundation

/// One entry of the conversation that a handoff may carry. Thinking is never
/// stored here: the loader drops it before it reaches memory.
public struct AgentHandoffItem: Equatable, Sendable {
    public let role: AgentTranscriptItem.Role
    /// `message`, `command`, `toolCall`, or `toolResult`. Never `thinking`.
    public let kind: AgentTranscriptItem.Kind
    public let text: String
    /// Tool output text; used only when the user includes tool outputs.
    public let detail: String?
    public let toolName: String?
    public let isError: Bool
    public let timestamp: Date?
    public let images: [AgentHandoffImageRef]
    /// File paths this entry mentions: `@path` mentions, Claude file
    /// attachments, and the `file_path` argument of a tool call.
    public let attachmentPaths: [String]

    public init(
        role: AgentTranscriptItem.Role, kind: AgentTranscriptItem.Kind, text: String,
        detail: String? = nil, toolName: String? = nil, isError: Bool = false,
        timestamp: Date? = nil, images: [AgentHandoffImageRef] = [],
        attachmentPaths: [String] = []
    ) {
        self.role = role
        self.kind = kind
        self.text = text
        self.detail = detail
        self.toolName = toolName
        self.isError = isError
        self.timestamp = timestamp
        self.images = images
        self.attachmentPaths = attachmentPaths
    }

    /// A prompt or a slash command starts a new turn.
    var startsTurn: Bool {
        role == .user && (kind == .message || kind == .command)
    }
}

/// The part of a session that a handoff can carry, with image pointers but
/// no image bytes.
public struct AgentHandoffConversation: Equatable, Sendable {
    public let provider: AgentHistoryProvider
    public let items: [AgentHandoffItem]
    /// Older entries cut to keep memory bounded.
    public let droppedLeadingItems: Int
    /// The file was larger than the read bound, so only its end was read.
    public let readFromTail: Bool
    public let skippedLineCount: Int

    public init(
        provider: AgentHistoryProvider, items: [AgentHandoffItem], droppedLeadingItems: Int = 0,
        readFromTail: Bool = false, skippedLineCount: Int = 0
    ) {
        self.provider = provider
        self.items = items
        self.droppedLeadingItems = droppedLeadingItems
        self.readFromTail = readFromTail
        self.skippedLineCount = skippedLineCount
    }

    /// Entries grouped by prompt. Entries before the first prompt form the
    /// first group.
    public var turns: [[AgentHandoffItem]] {
        var result: [[AgentHandoffItem]] = []
        for item in items {
            if item.startsTurn || result.isEmpty {
                result.append([item])
            } else {
                result[result.count - 1].append(item)
            }
        }
        return result
    }

    /// `true` when the older part of the session is not in `items`.
    public var isTrimmedAtStart: Bool { droppedLeadingItems > 0 || readFromTail }
}

/// Reads one session for a handoff, off the main actor.
public enum AgentHandoffLoader {
    /// The most bytes read from one file. A larger file is read from its end.
    public static let maximumBytes = 256 << 20
    /// The most entries kept. Older ones are dropped while reading.
    public static let maximumItems = 3_000

    static let limits = AgentTranscriptLimits(
        maximumBytes: Int.max, maximumItems: 1_000, maximumMessageCharacters: 30_000,
        maximumDetailCharacters: 2_000)

    @concurrent
    public static func load(_ session: AgentHistorySessionSummary) async throws
        -> AgentHandoffConversation
    {
        try load(fileURL: session.fileURL, provider: session.provider)
    }

    /// Decodes the chosen images. Bounded: each image is at most 5 MB after
    /// decoding, and only magic-byte-verified PNG, JPEG, GIF, and WebP data
    /// is kept. A cancelled task stops between images.
    @concurrent
    public static func decodeImages(
        _ refs: [AgentHandoffImageRef], session: AgentHistorySessionSummary
    ) async -> [Int: AgentHandoffImageResult] {
        decodeImages(refs, fileURL: session.fileURL, provider: session.provider)
    }

    // MARK: Reading

    static func load(
        fileURL: URL, provider: AgentHistoryProvider, maximumBytes: Int = maximumBytes,
        maximumItems: Int = maximumItems
    ) throws -> AgentHandoffConversation {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let startOffset = size > maximumBytes ? UInt64(size - maximumBytes) : 0
        var collector = AgentHandoffCollector(provider: provider, maximumItems: maximumItems)
        var skipped = 0
        var dropFirst = startOffset > 0
        try AgentHandoffLineReader.forEachLine(fileURL, startOffset: startOffset) { offset, line in
            if dropFirst {
                dropFirst = false
                return true
            }
            guard let entry = AgentHistoryJSON.object(line) else {
                skipped += 1
                return true
            }
            collector.add(entry, lineOffset: offset, lineLength: line.count)
            return true
        }
        return collector.finish(readFromTail: startOffset > 0, skippedLineCount: skipped)
    }

    static func decodeImages(
        _ refs: [AgentHandoffImageRef], fileURL: URL, provider: AgentHistoryProvider
    ) -> [Int: AgentHandoffImageResult] {
        var results: [Int: AgentHandoffImageResult] = [:]
        let handle = try? FileHandle(forReadingFrom: fileURL)
        defer { try? handle?.close() }
        for ref in refs {
            if Task.isCancelled { break }
            if let known = ref.knownSkip {
                results[ref.id] = .skipped(known)
                continue
            }
            switch ref.location {
            case .localFile(let path):
                results[ref.id] = AgentHandoffImageDecoder.decode(localFile: path)
            case .embedded(let offset, let length, let ordinal):
                guard let handle, length > 0,
                    (try? handle.seek(toOffset: offset)) != nil,
                    let line = try? handle.read(upToCount: length), line.count == length,
                    let entry = AgentHistoryJSON.object(line)
                else {
                    results[ref.id] = .skipped(.unreadable)
                    continue
                }
                let found = images(in: entry, provider: provider)
                guard ordinal < found.count else {
                    results[ref.id] = .skipped(.unreadable)
                    continue
                }
                results[ref.id] = AgentHandoffImageDecoder.decode(found[ordinal].raw)
            }
        }
        return results
    }

    /// The images of one parsed line, in the order the loader numbered them.
    static func images(
        in entry: [String: Any], provider: AgentHistoryProvider
    ) -> [AgentHandoffImageExtractor.Found] {
        switch provider {
        case .claudeCode:
            return AgentHandoffImageExtractor.claudeImages(entry)
        case .codex:
            guard AgentHistoryJSON.string(entry["type"]) == "response_item",
                let payload = AgentHistoryJSON.dictionary(entry["payload"])
            else { return [] }
            return AgentHandoffImageExtractor.codexImages(payload)
        }
    }
}

/// Bounded line reading that also reports where each line starts.
enum AgentHandoffLineReader {
    static let newline: UInt8 = 0x0A

    static func forEachLine(
        _ url: URL, startOffset: UInt64 = 0, chunkSize: Int = 4 << 20,
        _ body: (UInt64, Data) throws -> Bool
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if startOffset > 0 { try handle.seek(toOffset: startOffset) }
        var buffer = Data()
        var bufferStart = startOffset
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                // End of file: the last line may lack a newline.
                let tail = buffer.filter { $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }
                if !tail.isEmpty { _ = try body(bufferStart, buffer) }
                return
            }
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let end = buffer[cursor...].firstIndex(of: newline) {
                let line = buffer[cursor..<end]
                if !line.isEmpty {
                    let offset = bufferStart + UInt64(cursor - buffer.startIndex)
                    if try !body(offset, Data(line)) { return }
                }
                cursor = buffer.index(after: end)
            }
            bufferStart += UInt64(cursor - buffer.startIndex)
            buffer = Data(buffer[cursor...])
        }
    }
}

/// Walks lines and builds items, reusing the Agent History parsers so a
/// handoff and the Agent Session tab agree on what a prompt, a reply, and a
/// tool call are.
struct AgentHandoffCollector {
    let provider: AgentHistoryProvider
    let maximumItems: Int
    private var primary: [AgentHandoffItem] = []
    private var fallback: [AgentHandoffItem] = []
    private var primaryDropped = 0
    private var fallbackDropped = 0
    private var toolNames: [String: String] = [:]
    private var pendingAttachments: [String] = []
    private var nextImageID = 0

    init(provider: AgentHistoryProvider, maximumItems: Int) {
        self.provider = provider
        self.maximumItems = maximumItems
    }

    mutating func add(_ entry: [String: Any], lineOffset: UInt64, lineLength: Int) {
        switch provider {
        case .claudeCode: addClaude(entry, lineOffset: lineOffset, lineLength: lineLength)
        case .codex: addCodex(entry, lineOffset: lineOffset, lineLength: lineLength)
        }
    }

    func finish(readFromTail: Bool, skippedLineCount: Int) -> AgentHandoffConversation {
        var items = primary
        var dropped = primaryDropped
        if provider == .codex, !primary.contains(where: { $0.kind == .message }),
            !fallback.isEmpty
        {
            items = fallback
            dropped = fallbackDropped
        }
        if items.count > maximumItems {
            dropped += items.count - maximumItems
            items = Array(items.suffix(maximumItems))
        }
        return AgentHandoffConversation(
            provider: provider, items: items, droppedLeadingItems: dropped,
            readFromTail: readFromTail, skippedLineCount: skippedLineCount)
    }

    // MARK: Claude Code

    private mutating func addClaude(_ entry: [String: Any], lineOffset: UInt64, lineLength: Int) {
        if AgentHistoryJSON.string(entry["type"]) == "attachment" {
            if let path = Self.claudeFileAttachmentPath(entry) { pendingAttachments.append(path) }
            return
        }
        var builder = AgentTranscriptBuilder(limits: AgentHandoffLoader.limits)
        ClaudeCodeHistoryParser.append(entry, to: &builder, toolNames: &toolNames)
        guard !builder.items.isEmpty else { return }
        let found = AgentHandoffImageExtractor.claudeImages(entry)
        let toolPaths = Self.claudeToolFilePaths(entry)
        append(
            builder.items, found: found, toolPaths: toolPaths, lineOffset: lineOffset,
            lineLength: lineLength, into: \.primary, dropped: \.primaryDropped)
    }

    /// `attachment` entries of type `file` name the file the user mentioned
    /// with `@`. Only the path is read, never the file content.
    static func claudeFileAttachmentPath(_ entry: [String: Any]) -> String? {
        guard let attachment = AgentHistoryJSON.dictionary(entry["attachment"]),
            AgentHistoryJSON.string(attachment["type"]) == "file"
        else { return nil }
        return AgentHistoryJSON.nonEmptyString(attachment["filename"])
            ?? AgentHistoryJSON.nonEmptyString(attachment["displayPath"])
    }

    static func claudeToolFilePaths(_ entry: [String: Any]) -> [String] {
        guard AgentHistoryJSON.string(entry["type"]) == "assistant",
            let message = AgentHistoryJSON.dictionary(entry["message"]),
            let blocks = AgentHistoryJSON.array(message["content"])
        else { return [] }
        var paths: [String] = []
        for case let block as [String: Any] in blocks {
            guard AgentHistoryJSON.string(block["type"]) == "tool_use",
                let input = AgentHistoryJSON.dictionary(block["input"]),
                let path = AgentHistoryJSON.nonEmptyString(input["file_path"])
            else { continue }
            paths.append(path)
        }
        return paths
    }

    // MARK: Codex

    private mutating func addCodex(_ entry: [String: Any], lineOffset: UInt64, lineLength: Int) {
        let payload = AgentHistoryJSON.dictionary(entry["payload"]) ?? [:]
        let timestamp = AgentHistoryJSON.date(entry["timestamp"])
        var builder = AgentTranscriptBuilder(limits: AgentHandoffLoader.limits)
        switch AgentHistoryJSON.string(entry["type"]) {
        case "response_item":
            CodexHistoryParser.appendResponseItem(
                payload, timestamp: timestamp, to: &builder, toolNames: &toolNames)
            guard !builder.items.isEmpty else { return }
            let toolPaths = Self.codexToolFilePaths(payload)
            append(
                builder.items, found: AgentHandoffImageExtractor.codexImages(payload),
                toolPaths: toolPaths, lineOffset: lineOffset, lineLength: lineLength,
                into: \.primary, dropped: \.primaryDropped)
        case "event_msg":
            CodexHistoryParser.appendFallbackEvent(payload, timestamp: timestamp, to: &builder)
            guard !builder.items.isEmpty else { return }
            append(
                builder.items, found: [], toolPaths: [], lineOffset: lineOffset,
                lineLength: lineLength, into: \.fallback, dropped: \.fallbackDropped)
        default:
            return
        }
    }

    static func codexToolFilePaths(_ payload: [String: Any]) -> [String] {
        guard AgentHistoryJSON.string(payload["type"]) == "function_call" else { return [] }
        var arguments = payload["arguments"]
        if let text = arguments as? String { arguments = AgentHistoryJSON.object(jsonText: text) }
        guard let object = arguments as? [String: Any],
            let path = AgentHistoryJSON.nonEmptyString(object["file_path"])
        else { return [] }
        return [path]
    }

    // MARK: Shared

    private mutating func append(
        _ source: [AgentTranscriptItem], found: [AgentHandoffImageExtractor.Found],
        toolPaths: [String], lineOffset: UInt64, lineLength: Int,
        into list: WritableKeyPath<AgentHandoffCollector, [AgentHandoffItem]>,
        dropped: WritableKeyPath<AgentHandoffCollector, Int>
    ) {
        let kept = source.filter { $0.kind != .thinking }
        guard !kept.isEmpty else { return }

        // Pick the entry that each image belongs to: a message image goes to
        // the line's first prompt or reply; a tool-result image goes to the
        // line's last tool result.
        var imagesByIndex: [Int: [AgentHandoffImageRef]] = [:]
        for (ordinal, image) in found.enumerated() {
            let target: Int?
            if image.isToolResult {
                target = kept.lastIndex { $0.kind == .toolResult }
            } else {
                target = kept.firstIndex { $0.kind == .message || $0.kind == .command }
            }
            guard let target else { continue }
            let location: AgentHandoffImageLocation
            var skip: AgentHandoffImageSkipReason?
            switch image.raw {
            case .localFile(let path):
                location = .localFile(path: path)
            case .remote:
                location = .embedded(
                    lineOffset: lineOffset, lineLength: lineLength, ordinal: ordinal)
                skip = .remoteURL
            case .unusable:
                location = .embedded(
                    lineOffset: lineOffset, lineLength: lineLength, ordinal: ordinal)
                skip = .badEncoding
            case .base64:
                location = .embedded(
                    lineOffset: lineOffset, lineLength: lineLength, ordinal: ordinal)
                if let length = image.encodedLength,
                    length / 4 * 3 > AgentHandoffImageLimits.maximumDecodedBytes + 3
                {
                    skip = .tooLarge
                }
            }
            imagesByIndex[target, default: []].append(
                AgentHandoffImageRef(
                    id: nextImageID, location: location, isToolResult: image.isToolResult,
                    encodedLength: image.encodedLength, knownSkip: skip))
            nextImageID += 1
        }

        var built: [AgentHandoffItem] = []
        for (index, item) in kept.enumerated() {
            var paths: [String] = []
            if built.isEmpty, !pendingAttachments.isEmpty {
                paths += pendingAttachments
                pendingAttachments.removeAll()
            }
            if item.role == .user, item.kind == .message {
                paths += AgentHandoffMentions.paths(in: item.text)
            }
            if item.kind == .toolCall { paths += toolPaths }
            built.append(
                AgentHandoffItem(
                    role: item.role, kind: item.kind, text: item.text, detail: item.detail,
                    toolName: item.toolName, isError: item.isError, timestamp: item.timestamp,
                    images: imagesByIndex[index] ?? [], attachmentPaths: paths))
        }
        self[keyPath: list].append(contentsOf: built)
        if self[keyPath: list].count > maximumItems * 2 {
            let excess = self[keyPath: list].count - maximumItems
            self[keyPath: list].removeFirst(excess)
            self[keyPath: dropped] += excess
        }
    }
}

/// `@path` mentions in prompt text.
enum AgentHandoffMentions {
    /// Tokens that start with `@` and look like a path: they hold a `/` or a
    /// file extension. `@claude` and e-mail addresses are not paths.
    static func paths(in text: String) -> [String] {
        var result: [String] = []
        for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
            var token = String(rawToken)
            while let first = token.first, "([{\"'`".contains(first) { token.removeFirst() }
            guard token.first == "@" else { continue }
            token.removeFirst()
            while let last = token.last, ".,;:!?)]}\"'`".contains(last) { token.removeLast() }
            guard !token.isEmpty, token.count <= 512, !token.contains("@") else { continue }
            let name = token.split(separator: "/").last.map(String.init) ?? token
            let ext = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
            let hasExtension =
                ext.count > 1
                && ext.last.map { part in
                    !part.isEmpty && part.count <= 10
                        && part.allSatisfy { $0.isLetter || $0.isNumber }
                        && part.contains { $0.isLetter }
                } == true
            guard token.contains("/") || hasExtension else { continue }
            if !result.contains(token) { result.append(token) }
        }
        return result
    }
}
