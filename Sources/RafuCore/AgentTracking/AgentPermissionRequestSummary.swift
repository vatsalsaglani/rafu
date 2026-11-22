import Foundation

/// What a Claude Code `PermissionRequest` asks for, reduced to the few fields
/// Up next shows. Only the answer mode of the hook helper
/// (`rafu-agent-events claude <spool> --answer`) builds one. The text stays in
/// memory and in the private spool file until the app drains it; it is never
/// logged.
///
/// Every request gets a `classification`; nothing is dropped without one:
///
/// - `command` — Bash: `command`, the optional `description`, and
///   `dangerouslyDisableSandbox`. A command that asks to run outside the
///   sandbox is incomplete: the row does not show that flag, so only the
///   terminal can answer it.
/// - `fileChange` — Write: `file_path` and the whole `content`. Edit and
///   MultiEdit: `file_path` and every old and new string, from the single
///   form (`old_string`, `new_string`, `replace_all`) or the `edits` array.
///   Each edit shows as `- ` lines (removed) and `+ ` lines (added). Every
///   other key is never read.
/// - `toolCall` — a tool of an MCP server (`mcp__<server>__<tool>`), or a
///   Claude Code built-in tool that has no card of its own (see
///   `isBuiltInToolName(_:)`): the raw tool name and the whole `tool_input`
///   as sorted, pretty JSON text. Nothing is masked: a hidden value would
///   let the person approve what the row does not show.
/// - `questions` — AskUserQuestion: the questions of `tool_input.questions`.
/// - `plan` — ExitPlanMode: `plan` and `planFilePath`.
/// - `unclassified` — any other name, or an input of a shape this type does
///   not know. Only the name is kept; the row shows a notice.
///
/// Limits match `CanvasAgentRequest`, so the app can show the value as it is.
/// A command, a path or a file body that was cut or changed by sanitizing, a
/// command or body with blank space that could hide its end, or an input of a
/// shape this type does not know, makes the summary incomplete, and the row
/// then offers only "Open terminal": what the person reads must be exactly
/// what runs.
public nonisolated struct AgentPermissionRequestSummary: Codable, Equatable, Sendable {
    /// What kind of prompt a `PermissionRequest` is.
    public enum Classification: String, Codable, Hashable, Sendable, CaseIterable {
        case command, fileChange, toolCall, questions, plan, unclassified
    }

    /// Claude Code tools whose `tool_input` this type reads.
    public static let commandToolNames: Set<String> = ["Bash"]
    public static let fileToolNames: Set<String> = ["Edit", "MultiEdit", "Write"]
    /// The tool that asks the user questions. A plain allow is not a valid
    /// answer for it: the answer goes in `updatedInput`.
    public static let questionToolName = "AskUserQuestion"
    /// The tool that asks the user to approve a plan. A plain allow is not a
    /// valid answer for it either.
    public static let planToolName = "ExitPlanMode"

    /// The longest file path kept. The row's reason line (`"Change file: " + path`)
    /// must hold it whole, so the path bound sits below the reason bound.
    public static let maximumFilePathBytes = CanvasAgentRequest.Limits.filePathBytes

    /// The most edits of one Edit or MultiEdit input that are read.
    private static let maximumEdits = 64

    /// The longest MCP tool name read, in UTF-8 bytes.
    public static let maximumToolNameBytes = 200
    /// The longest built-in tool name, in UTF-8 bytes.
    public static let maximumBuiltInToolNameBytes = 64
    /// The most preview text of all choices of one question set together.
    /// A preview past it is dropped (it is display only), so a summary of
    /// four questions stays far below one spool file.
    public static let maximumPreviewBytesTotal = CanvasAgentRequest.Limits.previewBytesTotal
    private static let mcpPrefix = "mcp__"
    private static let claudeAIServerPrefix = "claude_ai_"
    /// The server label of a built-in tool in its reason line.
    public static let builtInToolLabel = "Claude Code tool"

    /// A tool call: the raw name and the arguments as JSON text.
    public struct ToolCall: Codable, Equatable, Sendable {
        /// The raw hook tool name: `mcp__<server>__<tool>` or a built-in name.
        public let name: String
        /// The `tool_input` as sorted, pretty JSON text. Never masked.
        public let arguments: String

        /// True for a Claude Code built-in tool, false for an MCP tool.
        public var isBuiltIn: Bool { AgentPermissionRequestSummary.mcpParts(of: name) == nil }
        /// The server part of an MCP tool name, as the tool's server calls
        /// itself. Empty for a built-in tool.
        public var server: String {
            AgentPermissionRequestSummary.mcpParts(of: name)?.server ?? ""
        }
        /// The tool part of an MCP tool name, or the built-in name.
        public var tool: String {
            AgentPermissionRequestSummary.mcpParts(of: name)?.tool ?? name
        }
        /// The reason line the row shows: the friendly server (or "Claude
        /// Code tool") and the tool, then the raw name.
        public var reasonLine: String {
            AgentPermissionRequestSummary.toolReason(name: name) ?? ""
        }
    }

    /// The plan of an ExitPlanMode request. Display only.
    public struct Plan: Codable, Equatable, Sendable {
        /// The plan file path, if Claude Code sent one.
        public let path: String?
        /// The plan text, cut at `CanvasAgentRequest.Limits.planBytes`.
        public let text: String

        public init(path: String?, text: String) {
            self.path = path
            self.text = text
        }
    }

    /// The one permission update Rafu can offer as "Allow and remember": one
    /// `addRules` entry with one allow rule. Anything else is not offered.
    /// The fields follow the Claude Code hooks reference (permission update
    /// entries).
    public struct PermissionSuggestion: Codable, Equatable, Sendable {
        /// Where Claude Code writes the rule.
        public enum Destination: String, Codable, Hashable, Sendable, CaseIterable {
            case session, localSettings, projectSettings, userSettings

            /// The words the row uses for it.
            public var label: String {
                switch self {
                case .session: "this session"
                case .localSettings: "local settings"
                case .projectSettings: "project settings"
                case .userSettings: "user settings"
                }
            }
        }

        /// The longest rule content kept, in UTF-8 bytes.
        public static let maximumRuleContentBytes = 256

        /// The tool the rule names: a built-in name or an MCP tool name.
        public let toolName: String
        /// The specifier of the rule (`npm test` in `Bash(npm test)`), or nil
        /// for the whole tool.
        public let ruleContent: String?
        public let destination: Destination

        /// The rule as Claude Code writes it: `Bash(npm test)` or `WebSearch`.
        public var rule: String {
            ruleContent.map { "\(toolName)(\($0))" } ?? toolName
        }

        /// The exact effect, for the remember choice.
        public var line: String { "Add rule \(rule) to \(destination.label)" }

        /// The suggestion when `entries` (`permission_suggestions`) holds
        /// exactly one entry of the one form Rafu understands, else nil.
        public init?(entries: Any?) {
            guard let list = entries as? [Any], list.count == 1,
                let entry = list[0] as? [String: Any]
            else { return nil }
            self.init(entry: entry)
        }

        /// One `addRules` entry with `behavior` `allow`, a known
        /// `destination`, and one rule `{toolName, ruleContent?}`. Any other
        /// key, a name outside the strict forms, or a text the sanitizer
        /// would change gives nil.
        public init?(entry: [String: Any]) {
            guard Set(entry.keys) == ["type", "rules", "behavior", "destination"],
                entry["type"] as? String == "addRules", entry["behavior"] as? String == "allow",
                let destination = (entry["destination"] as? String).flatMap(
                    Destination.init(rawValue:)),
                let rules = entry["rules"] as? [Any], rules.count == 1,
                let rule = rules[0] as? [String: Any],
                Set(rule.keys).isSubset(of: ["toolName", "ruleContent"]),
                let toolName = rule["toolName"] as? String
            else { return nil }
            let content: String?
            if let raw = rule["ruleContent"] {
                guard let text = raw as? String else { return nil }
                content = text
            } else {
                content = nil
            }
            self.init(toolName: toolName, ruleContent: content, destination: destination)
        }

        init?(toolName: String, ruleContent: String?, destination: Destination) {
            guard
                AgentPermissionRequestSummary.mcpParts(of: toolName) != nil
                    || AgentPermissionRequestSummary.isBuiltInToolName(toolName)
            else { return nil }
            if let ruleContent {
                let clean = CanvasAgentRequest.clean(
                    ruleContent, limit: Self.maximumRuleContentBytes, keepsLineBreaks: false)
                guard !clean.altered, !clean.text.isEmpty else { return nil }
            }
            self.toolName = toolName
            self.ruleContent = ruleContent
            self.destination = destination
        }

        private enum CodingKeys: String, CodingKey { case toolName, ruleContent, destination }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard
                let value = Self(
                    toolName: try container.decode(String.self, forKey: .toolName),
                    ruleContent: try container.decodeIfPresent(String.self, forKey: .ruleContent),
                    destination: try container.decode(Destination.self, forKey: .destination))
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "The suggestion is not one Rafu understands."))
            }
            self = value
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

    /// True for a name in the built-in form `^[A-Za-z][A-Za-z0-9_]{0,63}$`
    /// that holds no `__` (so it cannot pose as an MCP tool name).
    public static func isBuiltInToolName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= maximumBuiltInToolNameBytes,
            isLetterByte(first), !name.contains("__")
        else { return false }
        return bytes.allSatisfy { isLetterByte($0) || isDigitByte($0) || $0 == UInt8(ascii: "_") }
    }

    /// The classification of a tool by its name only. An input of a shape
    /// this type does not know can still make a request `unclassified`.
    public static func classification(forToolName name: String) -> Classification {
        if commandToolNames.contains(name) { return .command }
        if fileToolNames.contains(name) { return .fileChange }
        if name == questionToolName { return .questions }
        if name == planToolName { return .plan }
        if mcpParts(of: name) != nil { return .toolCall }
        if name.hasPrefix(mcpPrefix) { return .unclassified }
        return isBuiltInToolName(name) ? .toolCall : .unclassified
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetterByte(byte) || isDigitByte(byte) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }

    private static func isLetterByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigitByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
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

    /// `"<friendly server>: <tool>\n<raw name>"` for an MCP tool, or
    /// `"Claude Code tool: <name>\n<name>"` for a built-in tool card. The raw
    /// name is always on line 2, so the friendly form cannot hide the real
    /// target.
    public static func toolReason(name: String) -> String? {
        if let parts = mcpParts(of: name) {
            return "\(friendlyServer(parts.server)): \(parts.tool)\n\(name)"
        }
        guard classification(forToolName: name) == .toolCall else { return nil }
        return "\(builtInToolLabel): \(name)\n\(name)"
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

    public let classification: Classification
    public let command: String?
    public let description: String?
    /// The one file change of an Edit, MultiEdit or Write. Empty otherwise.
    public let fileChanges: [CanvasAgentRequest.FileChange]
    /// The call of an MCP tool or a built-in tool. Nil for every other class.
    public let toolCall: ToolCall?
    /// The questions of an AskUserQuestion request. Each id is the index of
    /// the question in `tool_input.questions` ("0", "1", ...). Claude Code
    /// keys an answer by the question text, so two questions with one text
    /// are terminal-only.
    public let questions: [CanvasAgentRequest.Question]
    /// The plan of an ExitPlanMode request.
    public let plan: Plan?
    /// The one permission update Rafu could offer to remember, if any.
    public let permissionSuggestion: PermissionSuggestion?
    /// The tool name of an `unclassified` request, sanitized, if it had one.
    public let unclassifiedToolName: String?
    /// False when the command, the path or the file body did not fit or was
    /// changed, or the input had a shape this type does not know.
    public let isComplete: Bool

    /// The path of the file change, if any.
    public var filePath: String? { fileChanges.first?.path }

    /// True for a request the helper waits on and Up next can answer: a
    /// command, a file change, a tool call (MCP or built-in), or a question
    /// set. Claude Code keeps its own dialog on screen while the hook waits,
    /// also for AskUserQuestion (probe on Claude Code 2.1.330). A plan and
    /// an unclassified request are only shown: the helper writes the event
    /// and exits at once.
    public var waitsForAnswer: Bool {
        switch classification {
        case .command, .fileChange, .toolCall, .questions: true
        case .plan, .unclassified: false
        }
    }

    /// The line a notice row shows for an `unclassified` request; nil for
    /// every other class.
    public var noticeReason: String? {
        guard classification == .unclassified else { return nil }
        guard let name = unclassifiedToolName, !name.isEmpty else {
            return "Claude Code asks for permission. Open the terminal to answer."
        }
        return "Claude Code asks to use \(name). Open the terminal to answer."
    }

    /// Builds the summary for one hook payload, or nil when it is
    /// `unclassified`. Use `classify(toolName:toolInput:permissionSuggestions:)`
    /// to keep an unclassified request.
    public init?(toolName: String?, toolInput: Any?, permissionSuggestions: Any? = nil) {
        let summary = Self.classify(
            toolName: toolName, toolInput: toolInput, permissionSuggestions: permissionSuggestions)
        guard summary.classification != .unclassified else { return nil }
        self = summary
    }

    /// The summary for one hook payload, of any class. Never nil.
    public static func classify(
        toolName: String?, toolInput: Any?, permissionSuggestions: Any? = nil
    ) -> AgentPermissionRequestSummary {
        let read = read(toolName: toolName, toolInput: toolInput)
        guard var summary = read else { return unclassified(toolName) }
        // Only a request that can be allowed with a remembered rule.
        if summary.classification == .command || summary.classification == .toolCall {
            summary = summary.with(
                suggestion: PermissionSuggestion(entries: permissionSuggestions))
        }
        return summary
    }

    private static func read(toolName: String?, toolInput: Any?) -> Self? {
        guard let toolName else { return nil }
        switch classification(forToolName: toolName) {
        case .toolCall:
            // An absent input is `{}`; a present one must be an object.
            let input: [String: Any]
            if toolInput == nil {
                input = [:]
            } else if let object = toolInput as? [String: Any] {
                input = object
            } else {
                return nil
            }
            guard let arguments = argumentsText(input) else { return nil }
            return Self(toolName: toolName, arguments: arguments)
        case .command:
            guard let input = toolInput as? [String: Any],
                let raw = input["command"] as? String
            else { return nil }
            return Self(
                command: raw, description: input["description"] as? String, fileChanges: [],
                leavesSandbox: input["dangerouslyDisableSandbox"] as? Bool == true)
        case .fileChange:
            guard let input = toolInput as? [String: Any],
                let path = input["file_path"] as? String
            else { return nil }
            let read = readFileChange(toolName: toolName, input: input)
            return Self(
                command: nil, description: nil,
                fileChanges: [
                    CanvasAgentRequest.FileChange(
                        path: path, kind: read.kind, body: read.body, isDiff: read.isDiff)
                ],
                leavesSandbox: !read.understood)
        case .questions:
            guard let input = toolInput as? [String: Any] else { return nil }
            let read = readQuestions(input)
            return Self(
                classification: .questions, questions: read.questions, complete: read.complete)
        case .plan:
            guard let input = toolInput as? [String: Any] else { return nil }
            let text = input["plan"] as? String
            let path = input["planFilePath"] as? String
            let cleanText = CanvasAgentRequest.clean(
                text ?? "", limit: CanvasAgentRequest.Limits.planBytes, keepsLineBreaks: true)
            let cleanPath = path.map {
                CanvasAgentRequest.clean($0, limit: maximumFilePathBytes, keepsLineBreaks: false)
            }
            let complete =
                text != nil && !cleanText.altered && cleanPath?.altered != true
                && cleanPath?.text.isEmpty != true
            return Self(
                classification: .plan,
                plan: Plan(path: cleanPath?.text, text: cleanText.text), complete: complete)
        case .unclassified:
            return nil
        }
    }

    private static func unclassified(_ toolName: String?) -> Self {
        let name = toolName.map {
            CanvasAgentRequest.clean($0, limit: maximumToolNameBytes, keepsLineBreaks: false).text
        }
        return Self(
            classification: .unclassified,
            unclassifiedToolName: name?.isEmpty == true ? nil : name, complete: false)
    }

    /// The questions of an AskUserQuestion input. `complete` is false when
    /// the list is missing, empty or too long, or any question is
    /// terminal-only.
    private static func readQuestions(
        _ input: [String: Any]
    ) -> (questions: [CanvasAgentRequest.Question], complete: Bool) {
        let limits = CanvasAgentRequest.Limits.self
        guard let raw = input["questions"] as? [Any], !raw.isEmpty else { return ([], false) }
        var complete = raw.count <= limits.questions
        var previewBudget = maximumPreviewBytesTotal
        var questions: [CanvasAgentRequest.Question] = []
        // The id is the index in the original list: the helper checks the
        // answer against its own copy of that list.
        for (index, item) in raw.prefix(limits.questions).enumerated() {
            guard let object = item as? [String: Any], let text = object["question"] as? String
            else {
                complete = false
                continue
            }
            var understood = object["options"] is [Any]
            let options = object["options"] as? [Any] ?? []
            var choices: [CanvasAgentRequest.Choice] = []
            for option in options.prefix(limits.choices + 1) {
                guard let option = option as? [String: Any],
                    let label = option["label"] as? String
                else {
                    understood = false
                    continue
                }
                var preview = option["preview"] as? String
                if let text = preview {
                    let size = min(text.utf8.count, limits.previewBytes)
                    if size > previewBudget {
                        preview = nil
                    } else {
                        previewBudget -= size
                    }
                }
                choices.append(
                    CanvasAgentRequest.Choice(
                        label: label, detail: option["description"] as? String ?? "",
                        preview: preview))
            }
            // A cut or changed question text could mislead the person.
            let cleanText = CanvasAgentRequest.clean(
                text, limit: limits.questionBytes, keepsLineBreaks: true)
            questions.append(
                CanvasAgentRequest.Question(
                    id: String(index), header: object["header"] as? String ?? "", text: text,
                    choices: choices, allowsMultiple: object["multiSelect"] as? Bool ?? false,
                    allowsFreeText: true,
                    terminalOnly: !understood || choices.count != options.count
                        || cleanText.altered))
        }
        // Claude Code keys an answer by the question text.
        let texts = questions.map(\.text)
        questions = questions.map { question in
            guard texts.filter({ $0 == question.text }).count > 1 else { return question }
            return CanvasAgentRequest.Question(
                id: question.id, header: question.header, text: question.text,
                choices: question.choices, allowsMultiple: question.allowsMultiple,
                allowsFreeText: question.allowsFreeText, terminalOnly: true)
        }
        complete =
            complete && questions.count == raw.count && !questions.contains(where: \.terminalOnly)
        return (questions, complete)
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

    /// Sanitizes the arguments of a tool call. Nil for a name that is not a
    /// tool-call name (`classification(forToolName:)`). A cut or changed
    /// text, or blank space that could hide the end, makes the summary
    /// incomplete.
    init?(toolName: String, arguments: String) {
        guard Self.classification(forToolName: toolName) == .toolCall else { return nil }
        let clean = CanvasAgentRequest.clean(
            arguments, limit: CanvasAgentRequest.Limits.commandBytes, keepsLineBreaks: true)
        guard !clean.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.init(
            classification: .toolCall,
            toolCall: ToolCall(name: toolName, arguments: clean.text),
            complete: !clean.altered && !CanvasAgentRequest.hidesText(clean.text))
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
        self.init(
            classification: cleanCommand != nil ? .command : .fileChange,
            command: cleanCommand,
            description: cleanDescription?.isEmpty == true ? nil : cleanDescription,
            fileChanges: cleanChanges, complete: complete)
    }

    /// Stores the fields as they are.
    private init(
        classification: Classification, command: String? = nil, description: String? = nil,
        fileChanges: [CanvasAgentRequest.FileChange] = [], toolCall: ToolCall? = nil,
        questions: [CanvasAgentRequest.Question] = [], plan: Plan? = nil,
        permissionSuggestion: PermissionSuggestion? = nil, unclassifiedToolName: String? = nil,
        complete: Bool
    ) {
        self.classification = classification
        self.command = command
        self.description = description
        self.fileChanges = fileChanges
        self.toolCall = toolCall
        self.questions = questions
        self.plan = plan
        self.permissionSuggestion = permissionSuggestion
        self.unclassifiedToolName = unclassifiedToolName
        self.isComplete = complete
    }

    private func with(suggestion: PermissionSuggestion?) -> Self {
        Self(
            classification: classification, command: command, description: description,
            fileChanges: fileChanges, toolCall: toolCall, questions: questions, plan: plan,
            permissionSuggestion: suggestion, unclassifiedToolName: unclassifiedToolName,
            complete: isComplete)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case classification, command, description, fileChanges, isComplete, toolCall
        case questions, plan, permissionSuggestion, unclassifiedToolName
        /// Written by an older helper: the path only.
        case filePath
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(classification, forKey: .classification)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(description, forKey: .description)
        if !fileChanges.isEmpty { try container.encode(fileChanges, forKey: .fileChanges) }
        try container.encodeIfPresent(toolCall, forKey: .toolCall)
        if !questions.isEmpty { try container.encode(questions, forKey: .questions) }
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encodeIfPresent(permissionSuggestion, forKey: .permissionSuggestion)
        try container.encodeIfPresent(unclassifiedToolName, forKey: .unclassifiedToolName)
        try container.encode(isComplete, forKey: .isComplete)
    }

    /// Decodes, then re-sanitizes. A value the sanitizer would change is
    /// rejected, so the app never shows unbounded or unclean text. A decoded
    /// summary may be less complete than the sanitizer would say, never more.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func corrupted() -> DecodingError {
            DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The request summary is not sanitized."))
        }
        // An older helper sends no classification: it is derived below.
        let stated = try container.decodeIfPresent(Classification.self, forKey: .classification)
        let command = try container.decodeIfPresent(String.self, forKey: .command)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        var fileChanges =
            try container.decodeIfPresent(
                [CanvasAgentRequest.FileChange].self, forKey: .fileChanges) ?? []
        let toolCall = try container.decodeIfPresent(ToolCall.self, forKey: .toolCall)
        let questions =
            try container.decodeIfPresent([CanvasAgentRequest.Question].self, forKey: .questions)
            ?? []
        let plan = try container.decodeIfPresent(Plan.self, forKey: .plan)
        let suggestion = try container.decodeIfPresent(
            PermissionSuggestion.self, forKey: .permissionSuggestion)
        let unclassifiedName = try container.decodeIfPresent(
            String.self, forKey: .unclassifiedToolName)
        var complete = try container.decode(Bool.self, forKey: .isComplete)
        // Each class carries only its own fields.
        let hasCommandFields = command != nil || description != nil || !fileChanges.isEmpty
        let others: [Bool] = [
            hasCommandFields, toolCall != nil, !questions.isEmpty, plan != nil,
            unclassifiedName != nil,
        ]
        guard others.filter({ $0 }).count <= 1 else { throw corrupted() }
        // Only a command or a tool call may carry a suggestion.
        if suggestion != nil, stated != nil, stated != .command, stated != .toolCall {
            throw corrupted()
        }

        switch stated {
        case .questions:
            let limits = CanvasAgentRequest.Limits.self
            guard !questions.isEmpty, questions.count <= limits.questions,
                Set(questions.map(\.id)).count == questions.count, suggestion == nil
            else { throw corrupted() }
            let sanitizerSays = !questions.contains(where: \.terminalOnly)
            guard sanitizerSays || !complete else { throw corrupted() }
            self.init(classification: .questions, questions: questions, complete: complete)
            return
        case .plan:
            guard let plan, suggestion == nil else { throw corrupted() }
            let text = CanvasAgentRequest.clean(
                plan.text, limit: CanvasAgentRequest.Limits.planBytes, keepsLineBreaks: true)
            let path = plan.path.map {
                CanvasAgentRequest.clean(
                    $0, limit: Self.maximumFilePathBytes, keepsLineBreaks: false)
            }
            guard !text.altered, path?.altered != true else { throw corrupted() }
            self.init(classification: .plan, plan: plan, complete: complete)
            return
        case .unclassified:
            if let unclassifiedName {
                let clean = CanvasAgentRequest.clean(
                    unclassifiedName, limit: Self.maximumToolNameBytes, keepsLineBreaks: false)
                guard !clean.altered, !clean.text.isEmpty else { throw corrupted() }
            }
            guard !complete, suggestion == nil, !hasCommandFields, toolCall == nil else {
                throw corrupted()
            }
            self.init(
                classification: .unclassified, unclassifiedToolName: unclassifiedName,
                complete: false)
            return
        case .toolCall, .command, .fileChange, nil:
            break
        }
        if let toolCall {
            guard stated == nil || stated == .toolCall,
                let value = Self(toolName: toolCall.name, arguments: toolCall.arguments),
                value.toolCall == toolCall, value.isComplete || !complete
            else { throw corrupted() }
            self.init(
                classification: .toolCall, toolCall: toolCall, permissionSuggestion: suggestion,
                complete: complete)
            return
        }
        guard stated != .toolCall else { throw corrupted() }
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
            value.fileChanges == fileChanges, value.isComplete || !complete,
            stated == nil || stated == value.classification,
            suggestion == nil || value.classification == .command
        else { throw corrupted() }
        self.init(
            classification: value.classification, command: value.command,
            description: value.description, fileChanges: value.fileChanges,
            permissionSuggestion: suggestion, complete: complete)
    }
}
