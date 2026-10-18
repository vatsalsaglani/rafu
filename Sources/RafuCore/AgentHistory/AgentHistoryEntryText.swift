import Foundation

/// Text rules shared by the Claude Code and Codex parsers.
enum AgentHistoryEntryText {
    /// The longest title shown in lists and tabs.
    static let titleLimit = 120
    /// The one-line summary of a tool call or result.
    static let previewLimit = 160

    /// `true` for text an agent CLI wrapped in a tag of its own
    /// (`<command-name>`, `<system-reminder>`, `<environment_context>`,
    /// `<permissions instructions>`, …) rather than text the user typed.
    /// Such tag names hold `-`, `_`, or a space; a prompt that starts with a
    /// plain HTML tag (`<div>`) stays a prompt.
    static func isTagWrapped(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0.isWhitespace })
        guard trimmed.first == "<" else { return false }
        var name = ""
        for character in trimmed.dropFirst() {
            if character == ">" {
                return !name.isEmpty && name.contains(where: { "-_ ".contains($0) })
            }
            let allowed =
                character.isLetter || character.isNumber || character == "_" || character == "-"
                || character == " " || character == ":"
            guard allowed, name.count < 64 else { return false }
            name.append(character)
        }
        return false
    }

    /// The text between `<tag>` and `</tag>`, trimmed.
    static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
            let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    /// One-line preview of a tool's input. Picks the most telling argument.
    static func toolInputPreview(_ input: Any?) -> String {
        if let text = input as? String {
            if let object = AgentHistoryJSON.object(jsonText: text) {
                return toolInputPreview(object)
            }
            return AgentHistoryText.singleLine(text, limit: previewLimit)
        }
        guard let object = input as? [String: Any] else { return "" }
        for key in [
            "command", "cmd", "file_path", "path", "pattern", "url", "query", "description",
            "prompt", "skill", "subject", "plan",
        ] {
            if let text = object[key] as? String, !text.isEmpty {
                return AgentHistoryText.singleLine(text, limit: previewLimit)
            }
            if let parts = object[key] as? [Any] {
                let words = parts.compactMap { $0 as? String }
                if !words.isEmpty {
                    return AgentHistoryText.singleLine(
                        words.joined(separator: " "), limit: previewLimit)
                }
            }
        }
        let compact = AgentHistoryJSON.compactText(object) ?? ""
        return AgentHistoryText.singleLine(compact, limit: previewLimit)
    }

    /// The arguments as readable text for the expanded tool row.
    static func toolInputDetail(_ input: Any?) -> String? {
        guard let input else { return nil }
        if let text = input as? String {
            if let object = AgentHistoryJSON.object(jsonText: text) {
                return AgentHistoryJSON.compactText(object) ?? text
            }
            return text
        }
        return AgentHistoryJSON.compactText(input)
    }

    /// First non-empty line of a tool result.
    static func resultPreview(_ output: String) -> String {
        for line in output.split(whereSeparator: \.isNewline) {
            let preview = AgentHistoryText.singleLine(String(line), limit: previewLimit)
            if !preview.isEmpty { return preview }
        }
        return "(no output)"
    }
}
