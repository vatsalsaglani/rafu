import Foundation

nonisolated enum GitStashParser {
    static func parse(_ data: Data) -> [GitStashEntry] {
        data.split(separator: 0, omittingEmptySubsequences: true).compactMap(parseRecord)
    }

    private static func parseRecord(_ record: Data.SubSequence) -> GitStashEntry? {
        let fields = record.split(
            separator: 0x1F,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
            let selector = String(data: Data(fields[0]), encoding: .utf8),
            let timestampText = String(data: Data(fields[1]), encoding: .utf8),
            let timestamp = Int64(timestampText),
            timestamp >= 0,
            let subject = String(data: Data(fields[2]), encoding: .utf8),
            let index = parseIndex(selector)
        else { return nil }

        let details = parseSubject(subject)
        return GitStashEntry(
            index: index,
            selector: "stash@{\(index)}",
            message: details.message,
            createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            branch: details.branch
        )
    }

    private static func parseIndex(_ selector: String) -> Int? {
        guard selector.hasPrefix("stash@{"), selector.hasSuffix("}") else { return nil }
        let start = selector.index(selector.startIndex, offsetBy: 7)
        let end = selector.index(before: selector.endIndex)
        guard start < end,
            let index = Int(selector[start..<end]),
            index >= 0,
            selector == "stash@{\(index)}"
        else { return nil }
        return index
    }

    private static func parseSubject(_ subject: String) -> (message: String, branch: String?) {
        if let parsed = parseSubject(subject, prefix: "WIP on ") {
            return ("WIP — \(parsed.message)", parsed.branch)
        }
        if let parsed = parseSubject(subject, prefix: "On ") {
            return parsed
        }
        return (subject.isEmpty ? "Stashed changes" : subject, nil)
    }

    private static func parseSubject(
        _ subject: String,
        prefix: String
    ) -> (message: String, branch: String?)? {
        guard subject.hasPrefix(prefix) else { return nil }
        let remainder = subject.dropFirst(prefix.count)
        guard let separator = remainder.range(of: ": ") else { return nil }
        let branch = String(remainder[..<separator.lowerBound])
        let message = String(remainder[separator.upperBound...])
        guard !branch.isEmpty else { return nil }
        return (message.isEmpty ? "Stashed changes" : message, branch)
    }
}
