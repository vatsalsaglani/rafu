import Foundation

nonisolated enum UnifiedDiffParser {
    static func parse(path: String, originalPath: String?, patch: String) -> GitFileDiff {
        if patch.contains("GIT binary patch") || patch.contains("Binary files ") {
            return GitFileDiff(
                path: path,
                originalPath: originalPath,
                isBinary: true,
                hunks: [],
                rawPatch: patch
            )
        }

        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hunks: [GitDiffHunk] = []
        var nextRowID = 0
        var index = 0
        while index < lines.count {
            guard let range = parseRange(lines[index]) else {
                index += 1
                continue
            }

            let header = lines[index]
            index += 1
            var body: [PatchLine] = []
            while index < lines.count, !lines[index].hasPrefix("@@ ") {
                let line = lines[index]
                if line.hasPrefix("diff --git ") { break }
                if line == "\\ No newline at end of file" {
                    index += 1
                    continue
                }
                if let first = line.first, first == " " || first == "+" || first == "-" {
                    body.append(PatchLine(prefix: first, content: String(line.dropFirst())))
                }
                index += 1
            }
            let rows = align(
                body,
                oldStart: range.oldStart,
                newStart: range.newStart,
                rowIDStart: nextRowID
            )
            nextRowID += rows.count
            hunks.append(
                GitDiffHunk(
                    id: hunks.count,
                    header: header,
                    oldStart: range.oldStart,
                    oldCount: range.oldCount,
                    newStart: range.newStart,
                    newCount: range.newCount,
                    rows: rows
                ))
        }

        return GitFileDiff(
            path: path,
            originalPath: originalPath,
            isBinary: false,
            hunks: hunks,
            rawPatch: patch
        )
    }

    static func addedFile(path: String, data: Data) -> GitFileDiff {
        guard !data.prefix(8_192).contains(0) else {
            return GitFileDiff(
                path: path,
                originalPath: nil,
                isBinary: true,
                hunks: [],
                rawPatch: ""
            )
        }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        let rows = lines.enumerated().map { offset, content in
            GitDiffRow(
                id: offset,
                oldLine: nil,
                newLine: GitDiffLine(number: offset + 1, content: content, kind: .addition),
                kind: .addition
            )
        }
        let hunk = GitDiffHunk(
            id: 0,
            header: "@@ -0,0 +1,\(lines.count) @@",
            oldStart: 0,
            oldCount: 0,
            newStart: 1,
            newCount: lines.count,
            rows: rows
        )
        return GitFileDiff(
            path: path,
            originalPath: nil,
            isBinary: false,
            hunks: lines.isEmpty ? [] : [hunk],
            rawPatch: lines.map { "+\($0)" }.joined(separator: "\n")
        )
    }

    private static func parseRange(_ header: String) -> HunkRange? {
        guard header.hasPrefix("@@ "),
            let closingRange = header.range(
                of: " @@", range: header.index(header.startIndex, offsetBy: 3)..<header.endIndex)
        else { return nil }
        let rangeText = header[
            header.index(header.startIndex, offsetBy: 3)..<closingRange.lowerBound]
        let sides = rangeText.split(separator: " ")
        guard sides.count >= 2,
            let old = parseSide(sides[0], prefix: "-"),
            let new = parseSide(sides[1], prefix: "+")
        else { return nil }
        return HunkRange(
            oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
    }

    private static func parseSide(_ side: Substring, prefix: Character) -> (start: Int, count: Int)?
    {
        guard side.first == prefix else { return nil }
        let values = side.dropFirst().split(separator: ",", maxSplits: 1)
        guard let start = Int(values[0]) else { return nil }
        let count = values.count == 2 ? Int(values[1]) ?? 0 : 1
        return (start, count)
    }

    private static func align(
        _ body: [PatchLine], oldStart: Int, newStart: Int, rowIDStart: Int
    ) -> [GitDiffRow] {
        var rows: [GitDiffRow] = []
        var oldNumber = oldStart
        var newNumber = newStart
        var index = 0

        while index < body.count {
            let line = body[index]
            if line.prefix == " " {
                rows.append(
                    GitDiffRow(
                        id: rowIDStart + rows.count,
                        oldLine: GitDiffLine(
                            number: oldNumber, content: line.content, kind: .context),
                        newLine: GitDiffLine(
                            number: newNumber, content: line.content, kind: .context),
                        kind: .context
                    ))
                oldNumber += 1
                newNumber += 1
                index += 1
                continue
            }

            var deletions: [String] = []
            var additions: [String] = []
            while index < body.count, body[index].prefix == "-" {
                deletions.append(body[index].content)
                index += 1
            }
            while index < body.count, body[index].prefix == "+" {
                additions.append(body[index].content)
                index += 1
            }

            let pairCount = max(deletions.count, additions.count)
            for offset in 0..<pairCount {
                let oldLine =
                    deletions.indices.contains(offset)
                    ? GitDiffLine(
                        number: oldNumber + offset, content: deletions[offset], kind: .deletion)
                    : nil
                let newLine =
                    additions.indices.contains(offset)
                    ? GitDiffLine(
                        number: newNumber + offset, content: additions[offset], kind: .addition)
                    : nil
                let kind: GitDiffRowKind =
                    if oldLine != nil && newLine != nil {
                        .modification
                    } else if oldLine != nil {
                        .deletion
                    } else {
                        .addition
                    }
                rows.append(
                    GitDiffRow(
                        id: rowIDStart + rows.count,
                        oldLine: oldLine,
                        newLine: newLine,
                        kind: kind
                    ))
            }
            oldNumber += deletions.count
            newNumber += additions.count
        }
        return rows
    }
}

private nonisolated struct PatchLine {
    let prefix: Character
    let content: String
}

private nonisolated struct HunkRange {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
}
