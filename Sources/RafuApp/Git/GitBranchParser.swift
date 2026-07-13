import Foundation

nonisolated enum GitBranchParser {
    private static let fieldSeparator = Character(UnicodeScalar(0x1F))

    static func parse(_ data: Data) -> [GitBranch] {
        data.split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            let fields = String(decoding: record, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count == 6 else { return nil }
            let fullName = String(fields[0])
            guard !fullName.hasSuffix("/HEAD") else { return nil }
            let kind: GitBranchKind = fullName.hasPrefix("refs/remotes/") ? .remote : .local
            let tracking = parseTracking(String(fields[4]))
            let upstream = fields[3].isEmpty ? nil : String(fields[3])
            return GitBranch(
                id: fullName,
                name: String(fields[1]),
                kind: kind,
                objectID: String(fields[2]),
                upstream: upstream,
                aheadCount: tracking.ahead,
                behindCount: tracking.behind,
                isCurrent: fields[5] == "*"
            )
        }.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .local }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func parseTracking(_ value: String) -> (ahead: Int, behind: Int) {
        var ahead = 0
        var behind = 0
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        for component in normalized.split(separator: ",") {
            let fields = component.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard fields.count == 2, let count = Int(fields[1]) else { continue }
            if fields[0] == "ahead" { ahead = count }
            if fields[0] == "behind" { behind = count }
        }
        return (ahead, behind)
    }
}
