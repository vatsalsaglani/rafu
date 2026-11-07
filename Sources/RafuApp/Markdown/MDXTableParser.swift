import Foundation

/// Finds the first GFM pipe table in a Markdown string (`<Matrix>` and
/// `<Compare>`, ADR 0034). Pure and bounded: it runs off the main actor
/// beside `MDXBlockBuilder`, and it never evaluates anything.
nonisolated enum MDXTableParser {
    /// A table and the Markdown on either side of it.
    struct Extraction: Equatable {
        let before: String
        let table: MDXTable
        let after: String
    }

    static let maxColumns = 32

    static func firstTable(in markdown: String) -> MDXTable? {
        extractFirstTable(in: markdown)?.table
    }

    static func extractFirstTable(in markdown: String) -> Extraction? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var inFence = false
        var index = 0
        while index + 1 < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                index += 1
                continue
            }
            guard !inFence, line.contains("|") else {
                index += 1
                continue
            }
            let header = cells(of: line)
            let delimiter = cells(of: lines[index + 1])
            guard !header.isEmpty, header.count <= maxColumns, header.count == delimiter.count,
                delimiter.allSatisfy(isDelimiterCell)
            else {
                index += 1
                continue
            }
            var rows: [[String]] = []
            var end = index + 2
            while end < lines.count, lines[end].contains("|"),
                rows.count < MDXBlockBuilder.maxListEntries
            {
                var row = cells(of: lines[end])
                if row.count > header.count {
                    row = Array(row.prefix(header.count))
                } else if row.count < header.count {
                    row += Array(repeating: "", count: header.count - row.count)
                }
                rows.append(row)
                end += 1
            }
            return Extraction(
                before: lines[..<index].joined(separator: "\n"),
                table: MDXTable(
                    columns: header.map(plainText), rows: rows.map { $0.map(plainText) }),
                after: lines[end...].joined(separator: "\n"))
        }
        return nil
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.hasPrefix(":") { body = body.dropFirst() }
        if body.hasSuffix(":") { body = body.dropLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    /// Splits one row on unescaped pipes. A leading and a trailing pipe are
    /// optional.
    private static func cells(of line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A cell's inline Markdown as plain text (`**x**` becomes `x`).
    private static func plainText(_ cell: String) -> String {
        guard
            let attributed = try? AttributedString(
                markdown: cell,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible))
        else { return cell }
        return String(attributed.characters)
    }
}

nonisolated extension MDXBlockBuilder {
    struct ChecklistItem: Equatable {
        let text: String
        let done: Bool
    }

    /// The items of a Markdown task list (`- [x] done`, `- [ ] open`). Nil
    /// unless every non-blank line is one item, so no other text is lost
    /// when the view draws the items. Uses the same marker grammar as
    /// `checklistCounts`.
    static func checklistItems(in text: String) -> [ChecklistItem]? {
        var items: [ChecklistItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty { continue }
            guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+"
            else { return nil }
            let rest = trimmed.dropFirst().drop { $0 == " " }
            let done: Bool
            if rest.hasPrefix("[ ]") {
                done = false
            } else if rest.hasPrefix("[x]") || rest.hasPrefix("[X]") {
                done = true
            } else {
                return nil
            }
            items.append(
                ChecklistItem(
                    text: rest.dropFirst(3).trimmingCharacters(in: .whitespaces), done: done))
            if items.count > maxListEntries { return nil }
        }
        return items.isEmpty ? nil : items
    }
}
