import Foundation

/// Maps a GitHub remote URL to the web page of one commit, for the History
/// hover card's "Open on GitHub". Pure: it reads the remote URL string Git
/// already returned and never contacts the network. Only `github.com`
/// remotes produce a URL; every other host, or a URL it cannot read, gives
/// `nil` and the card hides the action. Any user name or token in an HTTPS
/// remote is dropped, so a credential never reaches the browser.
nonisolated enum GitHubRemoteURL {
    private static let host = "github.com"

    /// Accepts `git@github.com:owner/repo(.git)`,
    /// `https://[user@]github.com/owner/repo(.git)`, and
    /// `ssh://git@github.com[:port]/owner/repo(.git)`.
    static func repositoryURL(remote: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = repositoryPath(from: trimmed) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var repository = String(parts[1])
        if repository.hasSuffix(".git") { repository.removeLast(".git".count) }
        let owner = String(parts[0])
        guard isValidSegment(owner), isValidSegment(repository) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(owner)/\(repository)"
        return components.url
    }

    static func commitURL(remote: String, sha: String) -> URL? {
        guard sha.count >= 7, sha.allSatisfy(\.isHexDigit),
            let repository = repositoryURL(remote: remote)
        else { return nil }
        return repository.appending(path: "commit").appending(path: sha)
    }

    /// "owner/repo(.git)" from a supported remote, or nil.
    private static func repositoryPath(from remote: String) -> String? {
        // scp-like form: git@github.com:owner/repo.git
        if !remote.contains("://") {
            guard let at = remote.firstIndex(of: "@"),
                let colon = remote[at...].firstIndex(of: ":")
            else { return nil }
            let hostPart = remote[remote.index(after: at)..<colon]
            guard hostPart.lowercased() == host else { return nil }
            return String(remote[remote.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let components = URLComponents(string: remote),
            let scheme = components.scheme?.lowercased(),
            ["https", "http", "ssh", "git"].contains(scheme),
            components.host?.lowercased() == host
        else { return nil }
        return components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// GitHub owner and repository names use letters, digits, '-', '_', '.'.
    private static func isValidSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || "-_.".unicodeScalars.contains(scalar))
        }
    }
}
