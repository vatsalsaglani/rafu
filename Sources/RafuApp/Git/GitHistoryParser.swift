import Foundation

nonisolated enum GitHistoryParser {
    private static let fieldSeparator = Character(UnicodeScalar(0x1F))

    static func parse(_ data: Data) -> [GitCommitSummary] {
        data.split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            let fields = String(decoding: record, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count == 7,
                let date = ISO8601DateFormatter.git.date(from: String(fields[4]))
            else { return nil }
            return GitCommitSummary(
                id: String(fields[0]),
                parentIDs: fields[1].split(separator: " ").map(String.init),
                authorName: String(fields[2]),
                authorEmail: String(fields[3]),
                authoredAt: date,
                subject: String(fields[5]),
                decorations: fields[6].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            )
        }
    }
}
nonisolated

    extension ISO8601DateFormatter
{
    fileprivate static var git: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
