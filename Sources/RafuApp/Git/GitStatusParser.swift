import Foundation

nonisolated struct ParsedGitStatus: Sendable {
    var branch = "HEAD"
    var headOID: String?
    var upstream: String?
    var aheadCount = 0
    var behindCount = 0
    var isDetached = false
    var isUnborn = false
    var changes: [GitChange] = []
}

nonisolated enum GitStatusParser {
    static func parse(_ data: Data) -> ParsedGitStatus {
        var parsed = ParsedGitStatus()
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0

        while index < records.count {
            let record = String(decoding: records[index], as: UTF8.self)
            if record.hasPrefix("# ") {
                parseHeader(record, into: &parsed)
            } else if record.hasPrefix("1 ") {
                if let change = parseOrdinary(record) { parsed.changes.append(change) }
            } else if record.hasPrefix("2 ") {
                let originalPath =
                    records.indices.contains(index + 1)
                    ? String(decoding: records[index + 1], as: UTF8.self)
                    : nil
                if let change = parseRenamed(record, originalPath: originalPath) {
                    parsed.changes.append(change)
                    index += 1
                }
            } else if record.hasPrefix("u ") {
                if let change = parseUnmerged(record) { parsed.changes.append(change) }
            } else if record.hasPrefix("? ") {
                parsed.changes.append(
                    GitChange(
                        path: String(record.dropFirst(2)),
                        indexStatus: "?",
                        worktreeStatus: "?",
                        kind: .untracked
                    ))
            }
            index += 1
        }

        parsed.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return parsed
    }

    private static func parseHeader(_ record: String, into parsed: inout ParsedGitStatus) {
        if record.hasPrefix("# branch.oid ") {
            let value = String(record.dropFirst("# branch.oid ".count))
            parsed.isUnborn = value == "(initial)"
            parsed.headOID = parsed.isUnborn ? nil : value
        } else if record.hasPrefix("# branch.head ") {
            let value = String(record.dropFirst("# branch.head ".count))
            parsed.isDetached = value == "(detached)"
            parsed.branch = parsed.isDetached ? "HEAD" : value
        } else if record.hasPrefix("# branch.upstream ") {
            parsed.upstream = String(record.dropFirst("# branch.upstream ".count))
        } else if record.hasPrefix("# branch.ab ") {
            let values = record.dropFirst("# branch.ab ".count).split(separator: " ")
            for value in values {
                if value.first == "+" { parsed.aheadCount = Int(value.dropFirst()) ?? 0 }
                if value.first == "-" { parsed.behindCount = Int(value.dropFirst()) ?? 0 }
            }
        }
    }

    private static func parseOrdinary(_ record: String) -> GitChange? {
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9, let status = statusPair(fields[1]) else { return nil }
        return GitChange(
            path: String(fields[8]),
            indexStatus: status.index,
            worktreeStatus: status.worktree
        )
    }

    private static func parseRenamed(_ record: String, originalPath: String?) -> GitChange? {
        let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        guard fields.count == 10, let status = statusPair(fields[1]) else { return nil }
        return GitChange(
            path: String(fields[9]),
            originalPath: originalPath,
            indexStatus: status.index,
            worktreeStatus: status.worktree
        )
    }

    private static func parseUnmerged(_ record: String) -> GitChange? {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        guard fields.count == 11, let status = statusPair(fields[1]) else { return nil }
        return GitChange(
            path: String(fields[10]),
            indexStatus: status.index,
            worktreeStatus: status.worktree,
            kind: .conflicted
        )
    }

    private static func statusPair(_ value: Substring) -> (index: Character, worktree: Character)? {
        let characters = Array(value)
        guard characters.count == 2 else { return nil }
        return (characters[0], characters[1])
    }
}
