import Foundation

nonisolated struct MarkdownFrontmatter: Sendable, Equatable {
    nonisolated enum Value: Sendable, Equatable {
        case scalar(String)
        case list([String])
        case block(String)
    }

    nonisolated struct Field: Sendable, Equatable {
        let key: String
        let value: Value
    }

    /// Lifted out of `fields`: first of `name`/`title` (case-insensitive).
    let title: String?
    /// Lifted out of `fields`: first of `description`/`summary`/`subtitle`.
    let description: String?
    /// Every remaining top-level field, in file order.
    let fields: [Field]
    /// The content between the fences, without the fence lines.
    let raw: String
    /// Total top-level key count including lifted keys.
    let fieldCount: Int
}

nonisolated enum MarkdownFrontmatterParseResult: Sendable, Equatable {
    case parsed(MarkdownFrontmatter)
    case unparsed(raw: String)
}

nonisolated struct MarkdownFrontmatterScanner: Sendable {
    private struct Line: Sendable {
        let text: String
        let lineEnding: String
    }

    private enum BlockStyle {
        case folded
        case literal
    }

    private typealias Entry = (key: String, value: MarkdownFrontmatter.Value)

    /// Detects and consumes leading metadata. The returned remainder is built
    /// from the original line endings, so MarkdownUI receives the body as it
    /// appeared after the closing fence.
    func scan(_ source: String) -> (
        result: MarkdownFrontmatterParseResult,
        remainder: String
    )? {
        var source = source
        if source.hasPrefix("\u{FEFF}") {
            source.removeFirst()
        }

        let lines = makeLines(from: source)
        guard let opening = lines.first, isFence(opening.text, token: "---") else {
            return nil
        }
        guard
            let closingIndex = lines.dropFirst().firstIndex(where: {
                isFence($0.text, token: "---") || isFence($0.text, token: "...")
            })
        else {
            return nil
        }

        let content = Array(lines[1..<closingIndex])
        let raw = rawText(of: content)
        let remainder = rebuiltText(of: Array(lines[(closingIndex + 1)...]))
        let result: MarkdownFrontmatterParseResult

        if let entries = parseEntries(content) {
            let titleEntry = entries.first { isTitleKey($0.key) }
            let descriptionEntry = entries.first { isDescriptionKey($0.key) }
            let liftedKeys = Set(
                entries.filter { isTitleKey($0.key) || isDescriptionKey($0.key) }
                    .map { $0.key.lowercased() }
            )
            let fields =
                entries
                .filter { !liftedKeys.contains($0.key.lowercased()) }
                .map { MarkdownFrontmatter.Field(key: $0.key, value: $0.value) }

            result = .parsed(
                MarkdownFrontmatter(
                    title: titleEntry.map { stringValue($0.value) },
                    description: descriptionEntry.map { stringValue($0.value) },
                    fields: fields,
                    raw: raw,
                    fieldCount: entries.count))
        } else {
            result = .unparsed(raw: raw)
        }

        return (result: result, remainder: remainder)
    }

    private func makeLines(from source: String) -> [Line] {
        // Foundation splits CRLF at the LF code unit. `String.split` works on
        // grapheme clusters, where CRLF is one Character on this toolchain.
        let rawLines = source.components(separatedBy: "\n")
        return rawLines.enumerated().map {
            index,
            rawLine in
            var text = rawLine
            let hadCarriageReturn = text.last == "\r"
            if hadCarriageReturn { text.removeLast() }
            let lineEnding: String
            if index < rawLines.count - 1 {
                lineEnding = hadCarriageReturn ? "\r\n" : "\n"
            } else {
                lineEnding = ""
            }
            return Line(text: text, lineEnding: lineEnding)
        }
    }

    private func isFence(_ text: String, token: String) -> Bool {
        guard text.hasPrefix(token) else { return false }
        return text.dropFirst(token.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private func rawText(of lines: [Line]) -> String {
        lines.enumerated().map { index, line in
            line.text + (index + 1 < lines.count ? line.lineEnding : "")
        }.joined()
    }

    private func rebuiltText(of lines: [Line]) -> String {
        lines.map { $0.text + $0.lineEnding }.joined()
    }

    private func parseEntries(_ lines: [Line]) -> [Entry]? {
        var entries: [Entry] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].text
            if isIgnorable(line) {
                index += 1
                continue
            }
            guard !hasLeadingWhitespace(line), let separator = line.firstIndex(of: ":") else {
                return nil
            }

            let key = String(line[..<separator])
            guard isValidKey(key) else { return nil }
            let valueText = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)

            if valueText.isEmpty {
                guard
                    let continuation = nextMeaningfulLine(after: index, in: lines),
                    hasLeadingWhitespace(continuation.text)
                else {
                    return nil
                }
                guard let list = parseList(from: index + 1, in: lines) else {
                    return nil
                }
                entries.append((key: key, value: .list(list.items)))
                index = list.nextIndex
                continue
            }

            if let blockStyle = blockStyle(for: valueText) {
                guard let block = parseBlock(from: index + 1, style: blockStyle, in: lines) else {
                    return nil
                }
                entries.append((key: key, value: .block(block.value)))
                index = block.nextIndex
                continue
            }

            guard let value = parseValue(valueText) else { return nil }
            entries.append((key: key, value: value))
            index += 1
        }

        return entries
    }

    private func parseValue(_ text: String) -> MarkdownFrontmatter.Value? {
        guard !hasUnsupportedPrefix(text) else { return nil }
        if text.hasPrefix("[") {
            return parseFlowList(text).map(MarkdownFrontmatter.Value.list)
        }
        guard !text.contains("[") && !text.contains("]") else { return nil }
        return .scalar(unquoted(text))
    }

    private func parseFlowList(_ text: String) -> [String]? {
        guard text.hasSuffix("]"), text.count >= 2 else { return nil }
        let inner = String(text.dropFirst().dropLast())
        guard !inner.contains("[") && !inner.contains("]") else { return nil }
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

        let items = inner.split(separator: ",", omittingEmptySubsequences: false).map {
            unquoted(String($0).trimmingCharacters(in: .whitespaces))
        }
        guard items.allSatisfy({ !$0.isEmpty && !hasUnsupportedPrefix($0) }) else {
            return nil
        }
        guard !items.contains(where: { $0.hasPrefix("\"") || $0.hasPrefix("'") }) else {
            return nil
        }
        return items
    }

    private func parseList(from startIndex: Int, in lines: [Line]) -> (
        items: [String], nextIndex: Int
    )? {
        guard let first = nextMeaningfulLine(after: startIndex - 1, in: lines) else {
            return nil
        }
        let indent = leadingSpaceCount(first.text)
        guard indent > 0, !hasTabIndentation(first.text) else { return nil }

        var items: [String] = []
        var index = startIndex
        while index < lines.count {
            let line = lines[index].text
            if isIgnorable(line) {
                index += 1
                continue
            }
            guard !hasTabIndentation(line) else { return nil }
            let currentIndent = leadingSpaceCount(line)
            guard
                currentIndent == indent,
                line.dropFirst(indent).hasPrefix("- ")
            else {
                break
            }
            let item = String(line.dropFirst(indent + 2)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, !hasUnsupportedPrefix(item) else { return nil }
            items.append(unquoted(item))
            index += 1
        }

        guard !items.isEmpty else { return nil }
        return (items: items, nextIndex: index)
    }

    private func parseBlock(
        from startIndex: Int,
        style: BlockStyle,
        in lines: [Line]
    ) -> (value: String, nextIndex: Int)? {
        var index = startIndex
        var indent: Int?
        var values: [String] = []

        while index < lines.count {
            let line = lines[index].text
            if isIgnorable(line) {
                index += 1
                continue
            }
            guard !hasTabIndentation(line) else { return nil }
            let currentIndent = leadingSpaceCount(line)
            guard currentIndent > 0 else { break }
            if let indent, currentIndent < indent { return nil }
            if indent == nil { indent = currentIndent }
            values.append(String(line.dropFirst(indent!)))
            index += 1
        }

        guard !values.isEmpty else { return nil }
        let separator = style == .folded ? " " : "\n"
        return (value: values.joined(separator: separator), nextIndex: index)
    }

    private func nextMeaningfulLine(after index: Int, in lines: [Line]) -> Line? {
        var cursor = index + 1
        while cursor < lines.count {
            if !isIgnorable(lines[cursor].text) { return lines[cursor] }
            cursor += 1
        }
        return nil
    }

    private func blockStyle(for text: String) -> BlockStyle? {
        switch text {
        case ">", ">-", ">+": .folded
        case "|", "|-", "|+": .literal
        default: nil
        }
    }

    private func isTitleKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "name" || normalized == "title"
    }

    private func isDescriptionKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "description" || normalized == "summary" || normalized == "subtitle"
    }

    private func stringValue(_ value: MarkdownFrontmatter.Value) -> String {
        switch value {
        case .scalar(let value), .block(let value): value
        case .list(let values): values.joined(separator: ", ")
        }
    }

    private func isIgnorable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespaces) else { return false }
        return !key.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func hasLeadingWhitespace(_ line: String) -> Bool {
        line.first == " " || line.first == "\t"
    }

    private func leadingSpaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private func hasTabIndentation(_ line: String) -> Bool {
        line.prefix { $0 == " " || $0 == "\t" }.contains("\t")
    }

    private func hasUnsupportedPrefix(_ text: String) -> Bool {
        text.first == "&" || text.first == "*" || text.first == "!"
    }

    /// Strips one matched pair of surrounding single or double quotes.
    private func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        guard first == "\"" || first == "'", value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
}
