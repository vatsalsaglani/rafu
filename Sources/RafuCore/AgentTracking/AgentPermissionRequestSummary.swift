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
/// - Edit, MultiEdit, Write: `file_path`. The file content, the old and new
///   strings, and every other key are never read.
///
/// Limits match `CanvasAgentRequest`, so the app can show the value as it is.
/// A command or a path that was cut or changed by sanitizing, or a command
/// with blank space that could hide its end, makes the summary incomplete, and the row then offers only "Open terminal": what the person
/// reads must be exactly what runs.
public nonisolated struct AgentPermissionRequestSummary: Codable, Equatable, Sendable {
    /// Claude Code tools whose `tool_input` this type reads.
    public static let commandToolNames: Set<String> = ["Bash"]
    public static let fileToolNames: Set<String> = ["Edit", "MultiEdit", "Write"]

    /// The longest file path kept. The row's reason line (`"Edit file: " + path`)
    /// must hold it whole, so the path bound sits below the reason bound.
    public static let maximumFilePathBytes = CanvasAgentRequest.Limits.reasonBytes - 32

    public let command: String?
    public let description: String?
    public let filePath: String?
    /// False when the command or the path did not fit or was changed.
    public let isComplete: Bool

    /// Builds the summary for one hook payload, or nil for a tool or an
    /// input this type does not read.
    public init?(toolName: String?, toolInput: Any?) {
        guard let toolName, let input = toolInput as? [String: Any] else { return nil }
        if Self.commandToolNames.contains(toolName) {
            guard let raw = input["command"] as? String else { return nil }
            self.init(
                command: raw, description: input["description"] as? String, filePath: nil,
                leavesSandbox: input["dangerouslyDisableSandbox"] as? Bool == true)
        } else if Self.fileToolNames.contains(toolName) {
            guard let raw = input["file_path"] as? String else { return nil }
            self.init(command: nil, description: nil, filePath: raw)
        } else {
            return nil
        }
    }

    /// Sanitizes the three fields. Nil when nothing worth showing is left.
    /// `leavesSandbox` makes the summary incomplete.
    init?(command: String?, description: String?, filePath: String?, leavesSandbox: Bool = false) {
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
        var cleanPath: String?
        if let filePath {
            let clean = CanvasAgentRequest.clean(
                filePath, limit: Self.maximumFilePathBytes, keepsLineBreaks: false)
            guard !clean.text.isEmpty else { return nil }
            complete = complete && !clean.altered
            cleanPath = clean.text
        }
        guard cleanCommand != nil || cleanPath != nil else { return nil }
        let cleanDescription = description.map {
            CanvasAgentRequest.clean(
                $0, limit: CanvasAgentRequest.Limits.reasonBytes, keepsLineBreaks: true
            ).text
        }
        self.command = cleanCommand
        self.description = cleanDescription?.isEmpty == true ? nil : cleanDescription
        self.filePath = cleanPath
        self.isComplete = complete
    }

    private enum CodingKeys: String, CodingKey {
        case command, description, filePath, isComplete
    }

    /// Decodes, then re-sanitizes. A value the sanitizer would change is
    /// rejected, so the app never shows unbounded or unclean text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decodeIfPresent(String.self, forKey: .command)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        let filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        let complete = try container.decode(Bool.self, forKey: .isComplete)
        guard let value = Self(command: command, description: description, filePath: filePath),
            value.command == command, value.description == description,
            value.filePath == filePath, value.isComplete || !complete
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
        self.filePath = value.filePath
        self.isComplete = complete
    }
}
