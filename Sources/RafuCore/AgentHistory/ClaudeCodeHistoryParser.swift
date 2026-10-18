import Foundation

/// Reads Claude Code transcripts: `<config>/projects/<encoded-cwd>/<id>.jsonl`.
///
/// Observed entry types (Claude Code 2.x): `user`, `assistant`, `system`,
/// `summary`, `ai-title`, `custom-title`, `attachment`, `last-prompt`, and
/// several bookkeeping types. Every unknown type is ignored. The project path
/// is each entry's `cwd`; the folder name encodes it lossily and is only a
/// last-resort label.
enum ClaudeCodeHistoryParser {
    static let headBytes = 64 << 10
    static let tailBytes = 64 << 10
    static let maximumHeadBytes = 1 << 20

    /// What a `user` entry holds.
    enum UserContent: Equatable {
        /// Text the user typed.
        case prompt(String)
        /// A slash command or a `!` shell command.
        case command(String)
        /// Tool results returned to the model.
        case toolResults([ToolResult])
        /// Injected context, reminders, local command output, …
        case meta
    }

    struct ToolResult: Equatable {
        let toolUseID: String?
        let output: String
        let isError: Bool
    }

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

        var customTitle: String?
        var aiTitle: String?
        var summaryTitle: String?
        var firstPrompt: String?
        var firstCommand: String?
        var sessionID: String?
        var count = 0
        for entry in all {
            switch AgentHistoryJSON.string(entry["type"]) {
            case "custom-title":
                customTitle = AgentHistoryJSON.nonEmptyString(entry["customTitle"]) ?? customTitle
            case "ai-title":
                aiTitle = AgentHistoryJSON.nonEmptyString(entry["aiTitle"]) ?? aiTitle
            case "summary":
                summaryTitle = AgentHistoryJSON.nonEmptyString(entry["summary"]) ?? summaryTitle
            case "user":
                guard !AgentHistoryJSON.bool(entry["isSidechain"]) else { continue }
                sessionID = sessionID ?? AgentHistoryJSON.nonEmptyString(entry["sessionId"])
                switch userContent(entry) {
                case .prompt(let text):
                    count += 1
                    if firstPrompt == nil { firstPrompt = text }
                case .command(let text):
                    count += 1
                    if firstCommand == nil { firstCommand = text }
                case .toolResults, .meta:
                    break
                }
            case "assistant":
                guard !AgentHistoryJSON.bool(entry["isSidechain"]) else { continue }
                sessionID = sessionID ?? AgentHistoryJSON.nonEmptyString(entry["sessionId"])
                count += assistantTextBlockCount(entry)
            default:
                continue
            }
        }
        guard count > 0 || customTitle != nil || aiTitle != nil else { return nil }

        let rawTitle =
            customTitle ?? aiTitle ?? summaryTitle ?? firstPrompt ?? firstCommand
        let title = rawTitle.map {
            AgentHistoryText.singleLine($0, limit: AgentHistoryEntryText.titleLimit)
        }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let id = stem.isEmpty ? (sessionID ?? stem) : stem

        let cwd =
            head.lazy.compactMap { AgentHistoryJSON.nonEmptyString($0["cwd"]) }.first
            ?? tail.reversed().lazy.compactMap { AgentHistoryJSON.nonEmptyString($0["cwd"]) }
            .first
        let branch = all.reversed().lazy.compactMap {
            AgentHistoryJSON.nonEmptyString($0["gitBranch"])
        }.first
        let started = all.lazy.compactMap { AgentHistoryJSON.date($0["timestamp"]) }.first
        let updated = all.reversed().lazy.compactMap { AgentHistoryJSON.date($0["timestamp"]) }
            .first
        let version = all.reversed().lazy.compactMap {
            AgentHistoryJSON.nonEmptyString($0["version"])
        }.first

        var estimated = count
        if !sample.coversWholeFile, sample.sampledBytes > 0 {
            let ratio = Double(size) / Double(sample.sampledBytes)
            estimated = max(count, Int((Double(count) * ratio).rounded()))
        }
        return AgentHistorySessionSummary(
            key: AgentHistorySessionKey(provider: .claudeCode, sessionID: id),
            title: (title?.isEmpty == false ? title : nil) ?? "Untitled Session",
            projectPath: cwd,
            fallbackProjectLabel: cwd == nil
                ? decodedFolderLabel(fileURL.deletingLastPathComponent().lastPathComponent)
                : nil,
            startedAt: started,
            updatedAt: updated,
            gitBranch: branch,
            messageCount: estimated,
            isMessageCountEstimated: !sample.coversWholeFile,
            fileURL: fileURL,
            fileSize: size,
            modificationDate: modificationDate,
            cliVersion: version)
    }

    /// Claude Code replaces every non-alphanumeric character of the cwd with
    /// `-`, so this is only a readable guess ("-Users-me-app" → "/Users/me/app").
    static func decodedFolderLabel(_ folder: String) -> String? {
        guard !folder.isEmpty else { return nil }
        return folder.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: Entry content

    static func userContent(_ entry: [String: Any]) -> UserContent {
        if AgentHistoryJSON.bool(entry["isMeta"])
            || AgentHistoryJSON.bool(entry["isCompactSummary"])
        {
            return .meta
        }
        guard let message = AgentHistoryJSON.dictionary(entry["message"]) else { return .meta }
        if let text = AgentHistoryJSON.string(message["content"]) {
            return classify(text)
        }
        guard let blocks = AgentHistoryJSON.array(message["content"]) else { return .meta }
        var texts: [String] = []
        var results: [ToolResult] = []
        for case let block as [String: Any] in blocks {
            switch AgentHistoryJSON.string(block["type"]) {
            case "text":
                guard let text = AgentHistoryJSON.nonEmptyString(block["text"]) else { continue }
                switch classify(text) {
                case .prompt(let value): texts.append(value)
                case .command(let value): return .command(value)
                default: continue
                }
            case "image":
                texts.append("[Image]")
            case "tool_result":
                results.append(
                    ToolResult(
                        toolUseID: AgentHistoryJSON.string(block["tool_use_id"]),
                        output: toolResultText(block["content"]),
                        isError: AgentHistoryJSON.bool(block["is_error"])))
            default:
                continue
            }
        }
        if !results.isEmpty { return .toolResults(results) }
        let prompt = texts.joined(separator: "\n\n")
        return prompt.isEmpty ? .meta : .prompt(prompt)
    }

    static func classify(_ text: String) -> UserContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .meta }
        if let name = AgentHistoryEntryText.tagContent("command-name", in: trimmed) {
            let command = name.hasPrefix("/") ? name : "/" + name
            let arguments = AgentHistoryEntryText.tagContent("command-args", in: trimmed) ?? ""
            return .command(arguments.isEmpty ? command : command + " " + arguments)
        }
        if let input = AgentHistoryEntryText.tagContent("bash-input", in: trimmed) {
            return .command("! " + input)
        }
        if AgentHistoryEntryText.isTagWrapped(trimmed) { return .meta }
        if trimmed.hasPrefix("Caveat: The messages below were generated by the user") {
            return .meta
        }
        if trimmed.hasPrefix("[Request interrupted by user") { return .meta }
        return .prompt(trimmed)
    }

    static func toolResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [Any] else { return "" }
        var parts: [String] = []
        for case let block as [String: Any] in blocks {
            switch AgentHistoryJSON.string(block["type"]) {
            case "text":
                if let text = AgentHistoryJSON.string(block["text"]) { parts.append(text) }
            case "image":
                parts.append("[Image]")
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func assistantTextBlockCount(_ entry: [String: Any]) -> Int {
        guard let message = AgentHistoryJSON.dictionary(entry["message"]) else { return 0 }
        if AgentHistoryJSON.nonEmptyString(message["content"]) != nil { return 1 }
        guard let blocks = AgentHistoryJSON.array(message["content"]) else { return 0 }
        var count = 0
        for case let block as [String: Any] in blocks
        where AgentHistoryJSON.string(block["type"]) == "text"
            && AgentHistoryJSON.nonEmptyString(block["text"]) != nil
        {
            count += 1
        }
        return count
    }

    // MARK: Transcript

    static func transcript(
        fileURL: URL, key: AgentHistorySessionKey, limits: AgentTranscriptLimits
    ) throws -> AgentTranscript {
        var builder = AgentTranscriptBuilder(limits: limits)
        var skipped = 0
        var toolNames: [String: String] = [:]
        let reachedByteLimit = try AgentHistoryFileReader.forEachLine(
            fileURL, maxBytes: limits.maximumBytes
        ) { line in
            guard let entry = AgentHistoryJSON.object(line) else {
                skipped += 1
                return true
            }
            append(entry, to: &builder, toolNames: &toolNames)
            return !builder.isFull
        }
        let truncation: AgentTranscript.TruncationReason? =
            builder.isFull ? .itemLimit : (reachedByteLimit ? .byteLimit : nil)
        return AgentTranscript(
            key: key, items: builder.items, truncation: truncation, skippedLineCount: skipped)
    }

    static func append(
        _ entry: [String: Any], to builder: inout AgentTranscriptBuilder,
        toolNames: inout [String: String]
    ) {
        let type = AgentHistoryJSON.string(entry["type"])
        guard type == "user" || type == "assistant",
            !AgentHistoryJSON.bool(entry["isSidechain"])
        else { return }
        let timestamp = AgentHistoryJSON.date(entry["timestamp"])
        if type == "user" {
            switch userContent(entry) {
            case .prompt(let text):
                builder.append(role: .user, kind: .message, text: text, timestamp: timestamp)
            case .command(let text):
                builder.append(role: .user, kind: .command, text: text, timestamp: timestamp)
            case .toolResults(let results):
                for result in results {
                    let name = result.toolUseID.flatMap { toolNames[$0] }
                    builder.append(
                        role: .user, kind: .toolResult,
                        text: AgentHistoryEntryText.resultPreview(result.output),
                        detail: result.output, toolName: name, isError: result.isError,
                        timestamp: timestamp)
                }
            case .meta:
                return
            }
            return
        }
        guard let message = AgentHistoryJSON.dictionary(entry["message"]) else { return }
        if let text = AgentHistoryJSON.nonEmptyString(message["content"]) {
            builder.append(role: .assistant, kind: .message, text: text, timestamp: timestamp)
            return
        }
        guard let blocks = AgentHistoryJSON.array(message["content"]) else { return }
        for case let block as [String: Any] in blocks {
            switch AgentHistoryJSON.string(block["type"]) {
            case "text":
                guard let text = AgentHistoryJSON.nonEmptyString(block["text"]) else { continue }
                builder.append(role: .assistant, kind: .message, text: text, timestamp: timestamp)
            case "thinking":
                guard let text = AgentHistoryJSON.nonEmptyString(block["thinking"]) else {
                    continue
                }
                builder.append(
                    role: .assistant, kind: .thinking, text: text, timestamp: timestamp)
            case "tool_use", "server_tool_use":
                let name = AgentHistoryJSON.nonEmptyString(block["name"]) ?? "tool"
                if let id = AgentHistoryJSON.string(block["id"]) { toolNames[id] = name }
                builder.append(
                    role: .assistant, kind: .toolCall,
                    text: AgentHistoryEntryText.toolInputPreview(block["input"]),
                    detail: AgentHistoryEntryText.toolInputDetail(block["input"]),
                    toolName: name, timestamp: timestamp)
            default:
                continue
            }
        }
    }
}
