import Foundation

nonisolated enum GitCommitFilesParser {
    static func parse(_ data: Data) -> [GitCommitFileChange] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var changes: [GitCommitFileChange] = []
        var index = 0
        while index < records.count {
            let status = String(decoding: records[index], as: UTF8.self)
            let code = status.first ?? "M"
            if code == "R" || code == "C" {
                guard records.indices.contains(index + 2) else { break }
                changes.append(
                    GitCommitFileChange(
                        path: String(decoding: records[index + 2], as: UTF8.self),
                        originalPath: String(decoding: records[index + 1], as: UTF8.self),
                        kind: code == "R" ? .renamed : .copied
                    ))
                index += 3
            } else {
                guard records.indices.contains(index + 1) else { break }
                changes.append(
                    GitCommitFileChange(
                        path: String(decoding: records[index + 1], as: UTF8.self),
                        originalPath: nil,
                        kind: kind(for: code)
                    ))
                index += 2
            }
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func kind(for code: Character) -> GitChangeKind {
        switch code {
        case "A": .added
        case "C": .copied
        case "D": .deleted
        case "M": .modified
        case "R": .renamed
        case "T": .typeChanged
        case "U": .conflicted
        default: .unknown
        }
    }
}
