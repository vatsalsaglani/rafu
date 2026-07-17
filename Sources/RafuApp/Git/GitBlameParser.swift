import Foundation

nonisolated enum GitBlameParser {
    static func parse(_ data: Data) -> GitBlame {
        let records = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)

        var metadataByCommit: [String: Metadata] = [:]
        var current: (header: Header, metadata: Metadata)?
        var lines: [GitBlameLine] = []

        for record in records {
            let value = String(record)
            if let header = parseHeader(value) {
                current = (header, metadataByCommit[header.commitID] ?? Metadata())
                continue
            }
            guard var block = current else { continue }

            if value.hasPrefix("\t") {
                if let author = block.metadata.author,
                    let seconds = block.metadata.authorTime,
                    let summary = block.metadata.summary
                {
                    metadataByCommit[block.header.commitID] = block.metadata
                    lines.append(
                        GitBlameLine(
                            lineNumber: block.header.finalLine,
                            commitID: block.header.commitID,
                            shortID: String(block.header.commitID.prefix(8)),
                            author: author,
                            time: Date(timeIntervalSince1970: TimeInterval(seconds)),
                            summary: summary,
                            isBoundary: block.metadata.isBoundary
                        )
                    )
                }
                current = nil
                continue
            }

            if value == "boundary" {
                block.metadata.isBoundary = true
            } else if value.hasPrefix("author ") {
                block.metadata.author = String(value.dropFirst("author ".count))
            } else if value.hasPrefix("author-time ") {
                block.metadata.authorTime = Int64(value.dropFirst("author-time ".count))
            } else if value.hasPrefix("summary ") {
                block.metadata.summary = String(value.dropFirst("summary ".count))
            }
            current = block
        }

        return GitBlame(lines: lines.sorted { $0.lineNumber < $1.lineNumber })
    }

    private static func parseHeader(_ value: String) -> Header? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3 || fields.count == 4,
            isObjectID(fields[0]),
            let finalLine = Int(fields[2]),
            finalLine > 0
        else { return nil }
        if fields.count == 4 {
            guard let groupCount = Int(fields[3]), groupCount > 0 else { return nil }
        }
        return Header(commitID: String(fields[0]), finalLine: finalLine)
    }

    private static func isObjectID(_ value: Substring) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }

    private struct Header {
        let commitID: String
        let finalLine: Int
    }

    private struct Metadata {
        var author: String?
        var authorTime: Int64?
        var summary: String?
        var isBoundary = false
    }
}
