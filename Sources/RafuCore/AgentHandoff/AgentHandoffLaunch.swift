import Foundation

/// The command line that starts the target agent on a written handoff. It
/// is an argument array: no value is ever joined into a shell string here.
///
/// Verified shapes:
/// - Claude Code: `claude "<prompt>"` starts an interactive session with an
///   initial prompt. It reads image files from paths named in the prompt.
/// - Codex: `codex "<prompt>" --image <file>` (`-i`, repeatable; the flag
///   takes one or more values, so the prompt comes first and each file gets
///   its own flag, and a path with a comma is listed in the prompt instead,
///   because the flag splits its value at commas).
public enum AgentHandoffLaunch {
    /// The longest prompt, in UTF-8 bytes.
    public static let maximumPromptBytes = 4_096

    /// The prompt. One line, at most 4 KB. `handoffPath` is the path of
    /// `HANDOFF.md` as the new agent should read it. `listedImagePaths` are
    /// image files named in the prompt itself.
    public static func prompt(
        source: AgentHistoryProvider, title: String, handoffPath: String,
        listedImagePaths: [String] = []
    ) -> String? {
        let cleanTitle = AgentHistoryText.singleLine(title, limit: 120)
            .replacingOccurrences(of: "\"", with: "'")
        let cleanPath = AgentHistoryText.singleLine(handoffPath, limit: 1_500)
        guard cleanPath == handoffPath.trimmingCharacters(in: .whitespacesAndNewlines),
            !cleanPath.isEmpty
        else { return nil }
        var text =
            "Read \(cleanPath). It is a \(source.displayName) session about "
            + "\"\(cleanTitle)\". Continue the task from where it stopped. "
            + "Images referenced there are in the same folder."
        guard text.utf8.count <= maximumPromptBytes else { return nil }
        if !listedImagePaths.isEmpty {
            var listed = 0
            var tail = " Image files:"
            for path in listedImagePaths {
                let single = AgentHistoryText.singleLine(path, limit: 1_500)
                let addition = " \"\(single.replacingOccurrences(of: "\"", with: "'"))\""
                // Keep room for the "and N more" note.
                if (text + tail + addition).utf8.count + 48 > maximumPromptBytes { break }
                tail += addition
                listed += 1
            }
            if listed > 0 {
                text += tail
                if listed < listedImagePaths.count {
                    text += " and \(listedImagePaths.count - listed) more in the same folder."
                }
            }
        }
        return text
    }

    /// The full argument vector, executable name first. `nil` when the
    /// prompt would be too long or the path is not usable.
    public static func arguments(
        target: AgentHistoryProvider, source: AgentHistoryProvider, title: String,
        handoffPath: String, imagePaths: [String]
    ) -> [String]? {
        let images = Array(imagePaths.prefix(AgentHandoffImageLimits.maximumImages))
        switch target {
        case .claudeCode:
            guard
                let prompt = prompt(
                    source: source, title: title, handoffPath: handoffPath,
                    listedImagePaths: images)
            else { return nil }
            return ["claude", prompt]
        case .codex:
            // A comma would split one path into two values.
            let flagged = images.filter { !$0.contains(",") && !$0.hasPrefix("-") }
            let listed = images.filter { $0.contains(",") || $0.hasPrefix("-") }
            guard
                let prompt = prompt(
                    source: source, title: title, handoffPath: handoffPath,
                    listedImagePaths: listed)
            else { return nil }
            var result = ["codex", prompt]
            for path in flagged { result += ["--image", path] }
            return result
        }
    }

    /// One shell line for a terminal that is already a shell (an Ensemble
    /// terminal card). Every element is single-quoted.
    public static func shellLine(_ arguments: [String]) -> String? {
        guard let first = arguments.first, !first.isEmpty,
            arguments.allSatisfy({ argument in
                !argument.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            })
        else { return nil }
        return AgentHistoryResumeCommand.shellLine(arguments)
    }
}
