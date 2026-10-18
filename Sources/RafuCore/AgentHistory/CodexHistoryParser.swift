import Foundation

/// Reads Codex rollouts: `<codex home>/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// Each line is `{"timestamp", "type", "payload"}`. The first line is
/// `session_meta` (`id`, `cwd`, `timestamp`, `git`, `originator`,
/// `cli_version`, `source`). Then `response_item` (payload `type`
/// `message` / `function_call` / `function_call_output` / `custom_tool_call`
/// / `custom_tool_call_output` / `reasoning` / …), `event_msg`, and
/// `turn_context`. Unknown types are ignored.
enum CodexHistoryParser {
    static let headBytes = 64 << 10
    static let tailBytes = 64 << 10
    static let maximumHeadBytes = 1 << 20

    // MARK: Summary

    static func summary(
        fileURL: URL, size: Int64, modificationDate: Date
    ) throws -> AgentHistorySessionSummary? {
        let sample = try AgentHistoryFileReader.sample(
            fileURL, size: size, headBytes: headBytes, tailBytes: tailBytes,
            maximumHeadBytes: maximumHeadBytes)
        return summary(
            sample: sample, fileURL: fileURL, size: size, modificationDate: modificationDate)
    }

    static func summary(
        sample: AgentHistoryFileReader.Sample, fileURL: URL, size: Int64,
        modificationDate: Date
    ) -> AgentHistorySessionSummary? {
        let head = sample.headLines.compactMap(AgentHistoryJSON.object)
        let tail = sample.tailLines.compactMap(AgentHistoryJSON.object)
        let all = head + tail

        var meta: [String: Any]?
        var turnCWD: String?
        var firstPrompt: String?
        var fallbackPrompt: String?
        var count = 0
        var fallbackCount = 0
        for entry in all {
            let payload = AgentHistoryJSON.dictionary(entry["payload"]) ?? [:]
            switch AgentHistoryJSON.string(entry["type"]) {
            case "session_meta":
                if meta == nil { meta = payload }
            case "turn_context":
                if turnCWD == nil { turnCWD = AgentHistoryJSON.nonEmptyString(payload["cwd"]) }
            case "response_item":
                guard AgentHistoryJSON.string(payload["type"]) == "message" else { continue }
                switch AgentHistoryJSON.string(payload["role"]) {
                case "user":
                    guard let text = userText(payload) else { continue }
                    count += 1
                    if firstPrompt == nil { firstPrompt = text }
                case "assistant":
                    if messageText(payload) != nil { count += 1 }
                default:
                    continue
                }
            case "event_msg":
                switch AgentHistoryJSON.string(payload["type"]) {
                case "user_message":
                    guard let text = AgentHistoryJSON.nonEmptyString(payload["message"]),
                        !isInjected(text)
                    else { continue }
                    fallbackCount += 1
                    if fallbackPrompt == nil { fallbackPrompt = text }
                case "agent_message":
                    if AgentHistoryJSON.nonEmptyString(payload["message"]) != nil {
                        fallbackCount += 1
                    }
                default:
                    continue
                }
            default:
                continue
            }
        }
        if let meta, isSubagent(meta) { return nil }
        if count == 0 { count = fallbackCount }
        guard meta != nil || count > 0 else { return nil }

        let id = AgentHistoryJSON.nonEmptyString(meta?["id"]) ?? sessionID(fromFileName: fileURL)
        guard let id, !id.isEmpty else { return nil }
        let cwd = AgentHistoryJSON.nonEmptyString(meta?["cwd"]) ?? turnCWD
        let git = AgentHistoryJSON.dictionary(meta?["git"])
        let started =
            AgentHistoryJSON.date(meta?["timestamp"])
            ?? all.lazy.compactMap { AgentHistoryJSON.date($0["timestamp"]) }.first
        let updated = all.reversed().lazy.compactMap { AgentHistoryJSON.date($0["timestamp"]) }
            .first
        let title = (firstPrompt ?? fallbackPrompt).map {
            AgentHistoryText.singleLine($0, limit: AgentHistoryEntryText.titleLimit)
        }

        var estimated = count
        if !sample.coversWholeFile, sample.sampledBytes > 0 {
            let ratio = Double(size) / Double(sample.sampledBytes)
            estimated = max(count, Int((Double(count) * ratio).rounded()))
        }
        return AgentHistorySessionSummary(
            key: AgentHistorySessionKey(provider: .codex, sessionID: id),
            title: (title?.isEmpty == false ? title : nil) ?? "Untitled Session",
            projectPath: cwd,
            startedAt: started,
            updatedAt: updated,
            gitBranch: AgentHistoryJSON.nonEmptyString(git?["branch"]),
            messageCount: estimated,
            isMessageCountEstimated: !sample.coversWholeFile,
            fileURL: fileURL,
            fileSize: size,
            modificationDate: modificationDate,
            cliVersion: AgentHistoryJSON.nonEmptyString(meta?["cli_version"]))
    }

    /// `rollout-2025-01-02T03-04-05-<uuid>.jsonl` → `<uuid>`.
    static func sessionID(fromFileName url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("rollout-"), stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    /// Codex records helper threads (`source: {"subagent": …}`) as their own
    /// rollouts. They belong to the parent thread, so the list hides them.
    static func isSubagent(_ meta: [String: Any]) -> Bool {
        if let source = AgentHistoryJSON.dictionary(meta["source"]) {
            return source.keys.contains { $0.lowercased().contains("subagent") }
        }
        return false
    }

    /// Codex injects instructions and environment as user messages
    /// (`<environment_context>`, `<user_instructions>`, AGENTS.md text, …).
    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if AgentHistoryEntryText.isTagWrapped(trimmed) { return true }
        return trimmed.hasPrefix("# AGENTS.md instructions")
    }

    /// The visible text of a `message` payload (`input_text` / `output_text`
    /// / `text` content items).
    static func messageText(_ payload: [String: Any]) -> String? {
        if let text = AgentHistoryJSON.nonEmptyString(payload["content"]) { return text }
        guard let content = AgentHistoryJSON.array(payload["content"]) else { return nil }
        var parts: [String] = []
        for case let item as [String: Any] in content {
            switch AgentHistoryJSON.string(item["type"]) {
            case "input_text", "output_text", "text":
                if let text = AgentHistoryJSON.nonEmptyString(item["text"]) { parts.append(text) }
            case "input_image":
                parts.append("[Image]")
            default:
                continue
            }
        }
        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// A user message's text, or `nil` for injected context.
    static func userText(_ payload: [String: Any]) -> String? {
        guard let text = messageText(payload), !isInjected(text) else { return nil }
        return text
    }

    // MARK: Transcript

    static func transcript(
        fileURL: URL, key: AgentHistorySessionKey, limits: AgentTranscriptLimits
    ) throws -> AgentTranscript {
        var builder = AgentTranscriptBuilder(limits: limits)
        var fallback = AgentTranscriptBuilder(limits: limits)
        var skipped = 0
        var toolNames: [String: String] = [:]
        let reachedByteLimit = try AgentHistoryFileReader.forEachLine(
            fileURL, maxBytes: limits.maximumBytes
        ) { line in
            guard let entry = AgentHistoryJSON.object(line) else {
                skipped += 1
                return true
            }
            let timestamp = AgentHistoryJSON.date(entry["timestamp"])
            let payload = AgentHistoryJSON.dictionary(entry["payload"]) ?? [:]
            switch AgentHistoryJSON.string(entry["type"]) {
            case "response_item":
                appendResponseItem(
                    payload, timestamp: timestamp, to: &builder, toolNames: &toolNames)
            case "event_msg":
                appendFallbackEvent(payload, timestamp: timestamp, to: &fallback)
            default:
                break
            }
            return !builder.isFull
        }
        let hasMessages = builder.items.contains { $0.kind == .message }
        let result = hasMessages || fallback.items.isEmpty ? builder : fallback
        let truncation: AgentTranscript.TruncationReason? =
            result.isFull ? .itemLimit : (reachedByteLimit ? .byteLimit : nil)
        return AgentTranscript(
            key: key, items: result.items, truncation: truncation, skippedLineCount: skipped)
    }

    static func appendResponseItem(
        _ payload: [String: Any], timestamp: Date?, to builder: inout AgentTranscriptBuilder,
        toolNames: inout [String: String]
    ) {
        switch AgentHistoryJSON.string(payload["type"]) {
        case "message":
            switch AgentHistoryJSON.string(payload["role"]) {
            case "user":
                guard let text = userText(payload) else { return }
                builder.append(role: .user, kind: .message, text: text, timestamp: timestamp)
            case "assistant":
                guard let text = messageText(payload) else { return }
                builder.append(role: .assistant, kind: .message, text: text, timestamp: timestamp)
            default:
                return
            }
        case "function_call", "custom_tool_call":
            let name = AgentHistoryJSON.nonEmptyString(payload["name"]) ?? "tool"
            if let callID = AgentHistoryJSON.string(payload["call_id"]) { toolNames[callID] = name }
            let input = payload["arguments"] ?? payload["input"]
            builder.append(
                role: .assistant, kind: .toolCall,
                text: AgentHistoryEntryText.toolInputPreview(input),
                detail: AgentHistoryEntryText.toolInputDetail(input),
                toolName: name, timestamp: timestamp)
        case "local_shell_call":
            let action = AgentHistoryJSON.dictionary(payload["action"])
            if let callID = AgentHistoryJSON.string(payload["call_id"]) {
                toolNames[callID] = "shell"
            }
            builder.append(
                role: .assistant, kind: .toolCall,
                text: AgentHistoryEntryText.toolInputPreview(action),
                detail: action.flatMap { AgentHistoryEntryText.toolInputDetail($0) },
                toolName: "shell", timestamp: timestamp)
        case "web_search_call":
            let action = AgentHistoryJSON.dictionary(payload["action"])
            builder.append(
                role: .assistant, kind: .toolCall,
                text: AgentHistoryEntryText.toolInputPreview(action),
                detail: action.flatMap { AgentHistoryEntryText.toolInputDetail($0) },
                toolName: "web_search", timestamp: timestamp)
        case "function_call_output", "custom_tool_call_output":
            let callID = AgentHistoryJSON.string(payload["call_id"])
            let output = outputText(payload["output"])
            builder.append(
                role: .user, kind: .toolResult,
                text: AgentHistoryEntryText.resultPreview(output.text),
                detail: output.text, toolName: callID.flatMap { toolNames[$0] },
                isError: output.isError, timestamp: timestamp)
        case "reasoning":
            var parts: [String] = []
            for case let item as [String: Any] in AgentHistoryJSON.array(payload["summary"]) ?? [] {
                if let text = AgentHistoryJSON.nonEmptyString(item["text"]) { parts.append(text) }
            }
            guard !parts.isEmpty else { return }
            builder.append(
                role: .assistant, kind: .thinking, text: parts.joined(separator: "\n\n"),
                timestamp: timestamp)
        default:
            return
        }
    }

    /// Older rollouts may carry only `event_msg` user/agent messages.
    static func appendFallbackEvent(
        _ payload: [String: Any], timestamp: Date?, to builder: inout AgentTranscriptBuilder
    ) {
        guard let text = AgentHistoryJSON.nonEmptyString(payload["message"]) else { return }
        switch AgentHistoryJSON.string(payload["type"]) {
        case "user_message":
            guard !isInjected(text) else { return }
            builder.append(role: .user, kind: .message, text: text, timestamp: timestamp)
        case "agent_message":
            builder.append(role: .assistant, kind: .message, text: text, timestamp: timestamp)
        default:
            return
        }
    }

    /// Tool output is a string, a JSON string `{"output", "metadata":
    /// {"exit_code"}}`, an object with `content`, or a list of content items.
    static func outputText(_ value: Any?) -> (text: String, isError: Bool) {
        if let text = value as? String {
            if let object = AgentHistoryJSON.object(jsonText: text),
                let inner = AgentHistoryJSON.string(object["output"])
            {
                let metadata = AgentHistoryJSON.dictionary(object["metadata"])
                let exitCode = AgentHistoryJSON.int(metadata?["exit_code"]) ?? 0
                return (inner, exitCode != 0)
            }
            return (text, false)
        }
        if let object = value as? [String: Any] {
            let failed =
                object["success"] != nil && !AgentHistoryJSON.bool(object["success"])
            if let content = AgentHistoryJSON.string(object["content"]) {
                return (content, failed)
            }
            if let items = AgentHistoryJSON.array(object["content"]) {
                return (contentItemsText(items), failed)
            }
            return (AgentHistoryJSON.compactText(object) ?? "", failed)
        }
        if let items = value as? [Any] {
            return (contentItemsText(items), false)
        }
        return ("", false)
    }

    private static func contentItemsText(_ items: [Any]) -> String {
        var parts: [String] = []
        for case let item as [String: Any] in items {
            if let text = AgentHistoryJSON.string(item["text"]) { parts.append(text) }
        }
        return parts.joined(separator: "\n")
    }
}

/// Codex thread names from `<codex home>/session_index.jsonl`: append-only
/// `{"id", "thread_name", "updated_at"}` rows where the last complete row for
/// an id is the current name. Read as a bounded tail; symlinks are refused.
enum CodexSessionIndex {
    static let byteLimit = 4 << 20

    static func load(index: URL, byteLimit: Int = byteLimit) throws -> [String: String] {
        guard byteLimit > 0 else { return [:] }
        let values = try index.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return [:] }
        let handle = try FileHandle(forReadingFrom: index)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let offset = length > UInt64(byteLimit) ? length - UInt64(byteLimit) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: byteLimit) ?? Data()
        // Drop a partial first row (cut by the limit) and a partial last row
        // (the CLI may be appending).
        let lines = AgentHistoryFileReader.lines(in: data, dropFirst: offset > 0, dropLast: true)
        var titles: [String: String] = [:]
        for line in lines where line.count <= 16_384 {
            guard let row = AgentHistoryJSON.object(line),
                let id = AgentHistoryJSON.nonEmptyString(row["id"]),
                let name = AgentHistoryJSON.string(row["thread_name"])
            else { continue }
            let title = AgentHistoryText.singleLine(name, limit: AgentHistoryEntryText.titleLimit)
            if title.isEmpty {
                titles.removeValue(forKey: id)
            } else {
                titles[id] = title
            }
        }
        return titles
    }
}
