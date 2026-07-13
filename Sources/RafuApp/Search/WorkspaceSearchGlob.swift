import Foundation

/// One compiled include/exclude glob for workspace search.
///
/// Supported syntax: `*` matches within one path component, `?` matches a
/// single non-slash character, `**` crosses directory boundaries, and a
/// leading or embedded `**/` also matches zero directories. A pattern
/// without `/` (for example `*.swift`) matches the last path component at
/// any depth; a pattern containing `/` matches the whole relative path.
nonisolated struct WorkspaceSearchGlob: Sendable, Equatable {
    let pattern: String
    private let regex: NSRegularExpression
    private let matchesLastPathComponentOnly: Bool

    init?(pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard
            let regex = try? NSRegularExpression(
                pattern: Self.regexPattern(fromGlob: trimmed)
            )
        else { return nil }
        self.pattern = trimmed
        self.regex = regex
        matchesLastPathComponentOnly = !trimmed.contains("/")
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pattern == rhs.pattern
    }

    func matches(relativePath: String) -> Bool {
        let candidate =
            matchesLastPathComponentOnly
            ? (relativePath as NSString).lastPathComponent
            : relativePath
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    private static func regexPattern(fromGlob glob: String) -> String {
        var translated = "^"
        var characters = Substring(glob)
        while let character = characters.first {
            if character == "*" {
                if characters.hasPrefix("**/") {
                    translated += "(?:.*/)?"
                    characters = characters.dropFirst(3)
                } else if characters.hasPrefix("**") {
                    translated += ".*"
                    characters = characters.dropFirst(2)
                } else {
                    translated += "[^/]*"
                    characters = characters.dropFirst()
                }
            } else if character == "?" {
                translated += "[^/]"
                characters = characters.dropFirst()
            } else {
                translated += NSRegularExpression.escapedPattern(for: String(character))
                characters = characters.dropFirst()
            }
        }
        return translated + "$"
    }
}
