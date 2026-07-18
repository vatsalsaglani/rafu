import Foundation

/// Parses `git worktree list --porcelain` output. Records are separated by a
/// blank line; each record is newline-delimited `key value` (or bare-flag)
/// attributes. The first record is always the main worktree.
///
/// Attributes handled: `worktree <path>`, `HEAD <oid>`, `branch <ref>`,
/// `detached`, `bare`, `locked [reason]`, `prunable [reason]`. Unknown
/// attributes are ignored so a newer git can add fields without breaking us.
nonisolated enum GitWorktreeParser {
    static func parse(_ output: String) -> [GitWorktree] {
        // Split into records on blank lines; tolerate CRLF and a trailing
        // blank record.
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        let records = normalized.components(separatedBy: "\n\n")
        var result: [GitWorktree] = []
        for (index, record) in records.enumerated() {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let worktree = parseRecord(lines, isMain: result.isEmpty && index == 0) else {
                continue
            }
            result.append(worktree)
        }
        return result
    }

    private static func parseRecord(
        _ lines: [Substring], isMain: Bool
    ) -> GitWorktree? {
        var path: String?
        var headOID: String?
        var branch: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false

        for line in lines {
            let (key, value) = splitAttribute(line)
            switch key {
            case "worktree": path = value
            case "HEAD": headOID = value
            case "branch": branch = shortBranch(value)
            case "detached": isDetached = true
            case "bare": isBare = true
            case "locked":
                isLocked = true
                lockReason = value.isEmpty ? nil : value
            case "prunable": isPrunable = true
            default: break
            }
        }

        guard let path, !path.isEmpty else { return nil }
        return GitWorktree(
            path: path,
            headOID: headOID,
            branch: branch,
            isDetached: isDetached || (branch == nil && !isBare),
            isBare: isBare,
            isMain: isMain,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable
        )
    }

    /// Splits a porcelain attribute line into `(key, value)` on the first
    /// space. Bare flags (`bare`, `detached`) yield an empty value.
    private static func splitAttribute(_ line: Substring) -> (String, String) {
        guard let spaceIndex = line.firstIndex(of: " ") else {
            return (String(line), "")
        }
        let key = String(line[line.startIndex..<spaceIndex])
        let value = String(line[line.index(after: spaceIndex)...])
        return (key, value)
    }

    /// `refs/heads/lane/x` → `lane/x`; leaves any non-heads ref as-is.
    private static func shortBranch(_ ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }
}
