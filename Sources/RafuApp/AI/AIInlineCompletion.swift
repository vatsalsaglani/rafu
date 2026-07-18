import Foundation

/// Pure prompt/response shaping for the opt-in AI inline (tab) completion.
/// The editor sends a bounded window of text around the caret — never the
/// whole document — and only while the user has explicitly enabled
/// completion for the window (AGENTS: AI stays explicit; the toggle is the
/// consent, off by default and not persisted).
nonisolated enum AICompletionPromptBuilder {
    /// Bounded context: characters kept before / after the caret.
    static let maximumPrefixCharacters = 2_000
    static let maximumSuffixCharacters = 500
    /// Suggestions longer than this are truncated at a line boundary.
    static let maximumSuggestionCharacters = 600

    static let instructions = """
        You are an inline code-completion engine inside a text editor. \
        The user's file content is provided with <CURSOR> marking the caret. \
        Reply with ONLY the raw text to insert at the caret — no markdown \
        fences, no quotes, no commentary, no repetition of text already \
        before the caret. Keep the completion short: finish the current \
        statement or line, at most 3 lines. If no useful completion exists, \
        reply with an empty response.
        """

    static func prompt(prefix: String, suffix: String, fileName: String) -> String {
        let boundedPrefix = String(prefix.suffix(maximumPrefixCharacters))
        let boundedSuffix = String(suffix.prefix(maximumSuffixCharacters))
        return """
            File: \(fileName)

            \(boundedPrefix)<CURSOR>\(boundedSuffix)
            """
    }

    /// Cleans a model reply into an insertable suggestion: strips markdown
    /// code fences, trailing whitespace noise, and caps the length at a line
    /// boundary. Returns nil when nothing useful remains.
    static func sanitize(_ raw: String) -> String? {
        var text = raw
        // Strip a single wrapping fence block if the model added one.
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n")
        }
        // Drop trailing whitespace/newlines; keep leading spaces (indent) but
        // drop leading newlines (they'd render as an empty ghost).
        while text.hasPrefix("\n") || text.hasPrefix("\r") { text.removeFirst() }
        while let last = text.last, last == "\n" || last == "\r" || last == " " {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        if text.count > maximumSuggestionCharacters {
            let head = String(text.prefix(maximumSuggestionCharacters))
            text = head.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast().joined(separator: "\n")
            guard !text.isEmpty else { return nil }
        }
        return text
    }
}
