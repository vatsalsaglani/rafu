import Foundation

/// What a Claude Code `PermissionRequest` asks for, reduced to the few fields
/// Up next shows. Only the answer mode of the hook helper
/// (`rafu-agent-events claude <spool> --answer`) builds one, and only for the
/// tools below. The text stays in memory and in the private spool file until
/// the app drains it; it is never logged.
///
/// - Bash: `command`, the optional `description`, and
///   `dangerouslyDisableSandbox`. A command that asks to run outside the
///   sandbox is incomplete: the row does not show that flag, so only the
///   terminal can answer it.
/// - Write: `file_path` and the whole `content`.
/// - Edit and MultiEdit: `file_path` and every old and new string, from the
///   single form (`old_string`, `new_string`, `replace_all`) or the `edits`
///   array. Each edit shows as `- ` lines (removed) and `+ ` lines (added).
///   Every other key is never read.
/// - A tool of an MCP server (`mcp__<server>__<tool>`): the raw tool name and
///   the whole `tool_input` as sorted, pretty JSON text. Nothing is masked: a
///   hidden value would let the person approve what the row does not show.
///   A name outside the strict form (see `mcpParts(of:)`) is not summarized.
///
/// Limits match `CanvasAgentRequest`, so the app can show the value as it is.
/// A command, a path or a file body that was cut or changed by sanitizing, a
/// command or body with blank space that could hide its end, or an input of a
/// shape this type does not know, makes the summary incomplete, and the row
/// then offers only "Open terminal": what the person reads must be exactly
/// what runs.
public nonisolated struct AgentPermissionRequestSummary: Codable, Equatable, Sendable {
    /// Claude Code tools whose `tool_input` this type reads.
    public static let commandToolNames: Set<String> = ["Bash"]
    public static let fileToolNames: Set<String> = ["Edit", "MultiEdit", "Write"]

    /// The longest file path kept. The row's reason line (`"Change file: " + path`)
    /// must hold it whole, so the path bound sits below the reason bound.
    public static let maximumFilePathBytes = CanvasAgentRequest.Limits.filePathBytes

    /// The most edits of one Edit or MultiEdit input that are read.
    private static let maximumEdits = 64

    /// The longest MCP tool name read, in UTF-8 bytes.
    public static let maximumToolNameBytes = 200
    private static let mcpPrefix = "mcp__"
    private static let claudeAIServerPrefix = "claude_ai_"

    /// A tool of an MCP server: the raw name and the arguments as JSON text.
    public struct ToolCall: Codable, Equatable, Sendable {
        /// The raw hook tool name, `mcp__<server>__<tool>`.
        public let name: String
        /// The `tool_input` as sorted, pretty JSON text. Never masked.
        public let arguments: String

        /// The server part of the name, as the tool's server calls itself.
        public var server: String {
            AgentPermissionRequestSummary.mcpParts(of: name)?.server ?? ""
        }
        /// The tool part of the name.
        public var tool: String {
            AgentPermissionRequestSummary.mcpParts(of: name)?.tool ?? ""
        }
        /// The reason line the row shows: the friendly server and the tool,
        /// then the raw name.
        public var reasonLine: String {
            AgentPermissionRequestSummary.toolReason(name: name) ?? ""
        }
    }

    /// The server and the tool of an MCP tool name, or nil for a name that is
    /// not `mcp__<server>__<tool>`, is longer than `maximumToolNameBytes`, has
    /// a character outside `A-Z a-z 0-9 _ - .`, or has an empty server or tool.
    /// The server ends at the first `__` after the prefix.
    public static func mcpParts(of name: String) -> (server: String, tool: String)? {
        guard name.utf8.count <= maximumToolNameBytes, name.hasPrefix(mcpPrefix),
            name.utf8.allSatisfy({ isNameByte($0) })
        else { return nil }
        let rest = name.dropFirst(mcpPrefix.count)
        guard let split = rest.range(of: "__") else { return nil }
        let server = rest[..<split.lowerBound]
        let tool = rest[split.upperBound...]
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (String(server), String(tool))
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"),
            UInt8(ascii: "."):
            true
        default: false
        }
    }

    /// The server as the row names it. A server that starts with `claude_ai_`
    /// shows without it, with spaces for underscores, and "(claude.ai)"; any
    /// other server shows as it is. Rafu cannot prove where a server comes
    /// from, so this is a label, not a claim of trust.
    public static func friendlyServer(_ server: String) -> String {
        guard server.hasPrefix(claudeAIServerPrefix),
            server.count > claudeAIServerPrefix.count
        else { return server }
        let rest = server.dropFirst(claudeAIServerPrefix.count)
        return rest.replacingOccurrences(of: "_", with: " ") + " (claude.ai)"
    }

    /// `"<friendly server>: <tool>\n<raw name>"`. The raw name is always on
    /// line 2, so the friendly form cannot hide the real target.
    public static func toolReason(name: String) -> String? {
        guard let parts = mcpParts(of: name) else { return nil }
        return "\(friendlyServer(parts.server)): \(parts.tool)\n\(name)"
    }

    /// The server label, the tool and the raw name from a reason line built
    /// by `toolReason(name:)`, or nil for any other text.
    public static func toolIdentity(
        fromReason reason: String
    ) -> (server: String, tool: String, name: String)? {
        let lines = reason.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 2, let colon = lines[0].range(of: ": ") else { return nil }
        let name = String(lines[1])
        guard toolReason(name: name) == reason else { return nil }
        return (
            String(lines[0][..<colon.lowerBound]), String(lines[0][colon.upperBound...]), name
        )
    }

    public let command: String?
    public let description: String?
    /// The one file change of an Edit, MultiEdit or Write. Empty for Bash.
    public let fileChanges: [CanvasAgentRequest.FileChange]
    /// The call of an MCP tool. Nil for every other tool.
    public let toolCall: ToolCall?
    /// False when the command, the path or the file body did not fit or was
    /// changed, or the input had a shape this type does not know.
    public let isComplete: Bool

    /// The path of the file change, if any.
    public var filePath: String? { fileChanges.first?.path }

    /// Builds the summary for one hook payload, or nil for a tool or an
    /// input this type does not read.
    public init?(toolName: String?, toolInput: Any?) {
        guard let toolName else { return nil }
        if Self.mcpParts(of: toolName) != nil {
            // An absent input is `{}`; a present one must be an object.
            let input: [String: Any]
            if toolInput == nil {
                input = [:]
            } else if let object = toolInput as? [String: Any] {
                input = object
            } else {
                return nil
            }
            guard let arguments = Self.argumentsText(input) else { return nil }
            self.init(toolName: toolName, arguments: arguments)
            return
        }
        guard let input = toolInput as? [String: Any] else { return nil }
        if Self.commandToolNames.contains(toolName) {
            guard let raw = input["command"] as? String else { return nil }
            self.init(
                command: raw, description: input["description"] as? String, fileChanges: [],
                leavesSandbox: input["dangerouslyDisableSandbox"] as? Bool == true)
        } else if Self.fileToolNames.contains(toolName) {
            guard let path = input["file_path"] as? String else { return nil }
            let read = Self.readFileChange(toolName: toolName, input: input)
            self.init(
                command: nil, description: nil,
                fileChanges: [
                    CanvasAgentRequest.FileChange(
                        path: path, kind: read.kind, body: read.body, isDiff: read.isDiff)
                ],
                leavesSandbox: !read.understood)
        } else {
            return nil
        }
    }

    /// The tool input as sorted, pretty JSON. JSON escapes line breaks and
    /// control characters inside strings, so they show as text.
    private static func argumentsText(_ input: [String: Any]) -> String? {
        if input.isEmpty { return "{}" }
        guard JSONSerialization.isValidJSONObject(input),
            let data = try? JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    /// The body of a file tool's input. `understood` is false when the input
    /// has a shape this type does not know: the body then cannot be trusted
    /// to be the whole change.
    private static func readFileChange(toolName: String, input: [String: Any]) -> (
        kind: CanvasAgentRequest.FileChange.Kind, body: String, isDiff: Bool, understood: Bool
    ) {
        if toolName == "Write" {
            guard let content = input["content"] as? String else {
                return (.overwrite, "", false, false)
            }
            return (.overwrite, content, false, true)
        }
        // Edit: one old and new string, or an `edits` array. Never both.
        var edits: [[String: Any]] = []
        var understood = true
        if let raw = input["edits"] {
            guard let list = raw as? [Any], !list.isEmpty,
                input["old_string"] == nil, input["new_string"] == nil
            else { return (.edit, "", true, false) }
            if list.count > maximumEdits { understood = false }
            for item in list.prefix(maximumEdits) {
                if let object = item as? [String: Any] {
                    edits.append(object)
                } else {
                    understood = false
                }
            }
        } else {
            edits = [input]
        }
        var groups: [String] = []
        for edit in edits {
            guard let old = edit["old_string"] as? String,
                let new = edit["new_string"] as? String
            else {
                understood = false
                continue
            }
            var lines: [String] = []
            if edit["replace_all"] as? Bool == true { lines.append("(every match)") }
            if !old.isEmpty { lines.append(contentsOf: diffLines(old, prefix: "- ")) }
            if !new.isEmpty { lines.append(contentsOf: diffLines(new, prefix: "+ ")) }
            if lines.isEmpty { understood = false }
            groups.append(lines.joined(separator: "\n"))
        }
        return (.edit, groups.joined(separator: "\n\n"), true, understood)
    }

    private static func diffLines(_ text: String, prefix: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }
    }

    /// Sanitizes the arguments of an MCP tool call. Nil for a name outside the
    /// strict form. A cut or changed text, or blank space that could hide
    /// the end, makes the summary incomplete.
    init?(toolName: String, arguments: String) {
        guard Self.mcpParts(of: toolName) != nil else { return nil }
        let clean = CanvasAgentRequest.clean(
            arguments, limit: CanvasAgentRequest.Limits.commandBytes, keepsLineBreaks: true)
        guard !clean.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.command = nil
        self.description = nil
        self.fileChanges = []
        self.toolCall = ToolCall(name: toolName, arguments: clean.text)
        self.isComplete = !clean.altered && !CanvasAgentRequest.hidesText(clean.text)
    }

    /// Sanitizes the fields. Nil when nothing worth showing is left.
    /// `leavesSandbox` makes the summary incomplete.
    init?(
        command: String?, description: String?, fileChanges: [CanvasAgentRequest.FileChange],
        leavesSandbox: Bool = false
    ) {
        var complete = !leavesSandbox
        var cleanCommand: String?
        if let command {
            let clean = CanvasAgentRequest.clean(
                command, limit: CanvasAgentRequest.Limits.commandBytes, keepsLineBreaks: true)
            guard !clean.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            complete = complete && !clean.altered && !CanvasAgentRequest.hidesText(clean.text)
            cleanCommand = clean.text
        }
        var cleanChanges: [CanvasAgentRequest.FileChange] = []
        for change in fileChanges.prefix(1) {
            let path = CanvasAgentRequest.clean(
                change.path, limit: Self.maximumFilePathBytes, keepsLineBreaks: false)
            guard !path.text.isEmpty else { return nil }
            let body = CanvasAgentRequest.clean(
                change.body, limit: CanvasAgentRequest.Limits.fileChangeBodyBytes,
                keepsLineBreaks: true)
            complete =
                complete && !path.altered && !body.altered
                && !CanvasAgentRequest.hidesText(body.text)
                && !(change.isDiff && body.text.isEmpty)
            cleanChanges.append(
                CanvasAgentRequest.FileChange(
                    path: path.text, kind: change.kind, body: body.text, isDiff: change.isDiff))
        }
        // The summary holds one file; a second one would be hidden.
        if fileChanges.count > 1 { complete = false }
        guard cleanCommand != nil || !cleanChanges.isEmpty else { return nil }
        let cleanDescription = description.map {
            CanvasAgentRequest.clean(
                $0, limit: CanvasAgentRequest.Limits.reasonBytes, keepsLineBreaks: true
            ).text
        }
        self.command = cleanCommand
        self.description = cleanDescription?.isEmpty == true ? nil : cleanDescription
        self.fileChanges = cleanChanges
        self.toolCall = nil
        self.isComplete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case command, description, fileChanges, isComplete, toolCall
        /// Written by an older helper: the path only.
        case filePath
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(description, forKey: .description)
        if !fileChanges.isEmpty { try container.encode(fileChanges, forKey: .fileChanges) }
        try container.encodeIfPresent(toolCall, forKey: .toolCall)
        try container.encode(isComplete, forKey: .isComplete)
    }

    /// Decodes, then re-sanitizes. A value the sanitizer would change is
    /// rejected, so the app never shows unbounded or unclean text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decodeIfPresent(String.self, forKey: .command)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        var fileChanges =
            try container.decodeIfPresent(
                [CanvasAgentRequest.FileChange].self, forKey: .fileChanges) ?? []
        var complete = try container.decode(Bool.self, forKey: .isComplete)
        if let toolCall = try container.decodeIfPresent(ToolCall.self, forKey: .toolCall) {
            // A tool call has no command, description or file change.
            guard command == nil, description == nil, fileChanges.isEmpty,
                let value = Self(toolName: toolCall.name, arguments: toolCall.arguments),
                value.toolCall == toolCall, value.isComplete || !complete
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "The request summary is not sanitized."))
            }
            self.command = nil
            self.description = nil
            self.fileChanges = []
            self.toolCall = toolCall
            self.isComplete = complete
            return
        }
        // An older helper sent the path only: it has no change to show.
        if fileChanges.isEmpty,
            let path = try container.decodeIfPresent(String.self, forKey: .filePath)
        {
            fileChanges = [
                CanvasAgentRequest.FileChange(path: path, kind: .edit, body: "", isDiff: true)
            ]
            complete = false
        }
        guard
            let value = Self(
                command: command, description: description, fileChanges: fileChanges),
            value.command == command, value.description == description,
            value.fileChanges == fileChanges, value.isComplete || !complete
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The request summary is not sanitized."))
        }
        // A decoded summary may be less complete than the sanitizer would
        // say, never more.
        self.command = value.command
        self.description = value.description
        self.fileChanges = value.fileChanges
        self.toolCall = nil
        self.isComplete = complete
    }
}
