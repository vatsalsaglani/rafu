import Foundation

/// Pure Markdown helpers for Canvas notes (review 7.8). Everything here works
/// on a value snapshot of the source and returns UTF-16 offsets, so results
/// apply directly to the TextKit buffer that owns the live text. Nothing is
/// retained.
///
/// This is deliberately not a full CommonMark parser. It finds top-level block
/// boundaries, fenced code, and task markers well enough to split a note into
/// independently rendered chunks, to map a rendered block back to a source line,
/// and to flip a task marker in the source.
nonisolated enum CanvasNoteMarkdown {
    /// One source line as UTF-16 offsets. `end` includes the line terminator.
    struct Line: Equatable, Sendable {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    enum FenceRole: Equatable, Sendable {
        case none, open, body, close
    }

    enum BlockKind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case list
        case quote
        case code(language: String?)
        case table
        case rule
    }

    /// A top-level block. `id` is the first source line, which is stable while
    /// the text above the block does not change.
    struct Block: Equatable, Identifiable, Sendable {
        var id: Int { startLine }
        let kind: BlockKind
        let startLine: Int
        /// Exclusive.
        let endLine: Int
        let range: NSRange
        let text: String
        let firstTaskIndex: Int
        let taskCount: Int
    }

    struct TaskMarker: Equatable, Sendable {
        let index: Int
        let line: Int
        /// UTF-16 offset of the single character between the brackets.
        let checkOffset: Int
        let isChecked: Bool
    }

    struct Edit: Equatable, Sendable {
        let range: NSRange
        let replacement: String
    }

    struct Summary: Equatable, Sendable {
        var title: String?
        var excerpt: String?
        var tasksDone: Int
        var tasksTotal: Int
    }

    // MARK: Lines

    static func lines(in text: [UInt16]) -> [Line] {
        var result: [Line] = []
        var start = 0
        var index = 0
        let count = text.count
        while index < count {
            let unit = text[index]
            if unit == 10 {
                result.append(Line(start: start, contentEnd: index, end: index + 1))
                index += 1
                start = index
            } else if unit == 13 {
                let end = (index + 1 < count && text[index + 1] == 10) ? index + 2 : index + 1
                result.append(Line(start: start, contentEnd: index, end: end))
                index = end
                start = end
            } else {
                index += 1
            }
        }
        if start < count { result.append(Line(start: start, contentEnd: count, end: count)) }
        return result
    }

    /// UTF-16 offset of the start of `line`; the text length when `line` is
    /// past the last line (the empty line after a trailing newline).
    static func offset(ofLine line: Int, in source: String) -> Int {
        let text = Array(source.utf16)
        let all = lines(in: text)
        guard line >= 0 else { return 0 }
        return line < all.count ? all[line].start : text.count
    }

    /// The line that contains UTF-16 `offset`. Offsets at or past the end map to
    /// the last line, or to the empty line after a trailing terminator.
    static func line(containing offset: Int, in source: String) -> Int {
        let text = Array(source.utf16)
        let all = lines(in: text)
        guard let last = all.last else { return 0 }
        if offset >= text.count { return last.end > last.contentEnd ? all.count : all.count - 1 }
        for (index, line) in all.enumerated() where offset < line.end { return index }
        return all.count - 1
    }

    // MARK: Fences

    private struct Fence {
        let marker: UInt16
        let length: Int
    }

    private static func isBlank(_ text: [UInt16], _ line: Line) -> Bool {
        var index = line.start
        while index < line.contentEnd {
            if text[index] != 32 && text[index] != 9 { return false }
            index += 1
        }
        return true
    }

    private static func indent(_ text: [UInt16], _ line: Line) -> Int {
        var width = 0
        var index = line.start
        while index < line.contentEnd {
            if text[index] == 32 {
                width += 1
            } else if text[index] == 9 {
                width += 4
            } else {
                break
            }
            index += 1
        }
        return width
    }

    private static func firstNonSpace(_ text: [UInt16], _ line: Line) -> Int {
        var index = line.start
        while index < line.contentEnd, text[index] == 32 || text[index] == 9 { index += 1 }
        return index
    }

    private static func fenceOpener(_ text: [UInt16], _ line: Line) -> Fence? {
        let first = firstNonSpace(text, line)
        guard first < line.contentEnd, text[first] == 96 || text[first] == 126 else { return nil }
        let marker = text[first]
        var index = first
        while index < line.contentEnd, text[index] == marker { index += 1 }
        let length = index - first
        guard length >= 3 else { return nil }
        if marker == 96 {
            var rest = index
            while rest < line.contentEnd {
                if text[rest] == 96 { return nil }
                rest += 1
            }
        }
        return Fence(marker: marker, length: length)
    }

    private static func closes(_ fence: Fence, _ text: [UInt16], _ line: Line) -> Bool {
        let first = firstNonSpace(text, line)
        var index = first
        while index < line.contentEnd, text[index] == fence.marker { index += 1 }
        guard index - first >= fence.length else { return false }
        while index < line.contentEnd {
            if text[index] != 32 && text[index] != 9 { return false }
            index += 1
        }
        return true
    }

    static func fenceRoles(in text: [UInt16], lines: [Line]) -> [FenceRole] {
        var roles = [FenceRole](repeating: .none, count: lines.count)
        var current: Fence?
        for (index, line) in lines.enumerated() {
            if let fence = current {
                if closes(fence, text, line) {
                    roles[index] = .close
                    current = nil
                } else {
                    roles[index] = .body
                }
            } else if let fence = fenceOpener(text, line) {
                roles[index] = .open
                current = fence
            }
        }
        return roles
    }

    // MARK: Tasks

    /// Finds `- [ ] text` style markers outside fenced code. Ordered lists and
    /// quote prefixes count; a marker needs text after it, as in GitHub's
    /// task-list rule.
    static func tasks(in source: String) -> [TaskMarker] {
        let text = Array(source.utf16)
        let all = lines(in: text)
        let roles = fenceRoles(in: text, lines: all)
        return tasks(in: text, lines: all, roles: roles)
    }

    private static func tasks(in text: [UInt16], lines: [Line], roles: [FenceRole]) -> [TaskMarker] {
        var result: [TaskMarker] = []
        for (index, line) in lines.enumerated() where roles[index] == .none {
            guard let found = taskMarker(text, line) else { continue }
            result.append(
                TaskMarker(
                    index: result.count, line: index, checkOffset: found.offset,
                    isChecked: found.checked))
        }
        return result
    }

    private static func taskMarker(_ text: [UInt16], _ line: Line) -> (offset: Int, checked: Bool)? {
        var position = line.start
        let end = line.contentEnd
        while position < end, text[position] == 32 || text[position] == 9 || text[position] == 62 {
            position += 1
        }
        guard position < end else { return nil }
        if text[position] == 45 || text[position] == 42 || text[position] == 43 {
            position += 1
        } else {
            var digits = 0
            while position < end, text[position] >= 48, text[position] <= 57 {
                position += 1
                digits += 1
            }
            guard digits >= 1, digits <= 9, position < end,
                text[position] == 46 || text[position] == 41
            else { return nil }
            position += 1
        }
        var spaces = 0
        while position < end, text[position] == 32 || text[position] == 9 {
            position += 1
            spaces += 1
        }
        guard spaces >= 1, position + 2 < end, text[position] == 91, text[position + 2] == 93
        else { return nil }
        let mark = text[position + 1]
        guard mark == 32 || mark == 120 || mark == 88 else { return nil }
        var after = position + 3
        var gap = 0
        while after < end, text[after] == 32 || text[after] == 9 {
            after += 1
            gap += 1
        }
        guard gap >= 1, after < end else { return nil }
        return (position + 1, mark != 32)
    }

    /// The edit that flips the `index`th task marker, or nil when there is none.
    static func toggledTask(in source: String, at index: Int) -> Edit? {
        let found = tasks(in: source)
        guard found.indices.contains(index) else { return nil }
        let marker = found[index]
        return Edit(
            range: NSRange(location: marker.checkOffset, length: 1),
            replacement: marker.isChecked ? " " : "x")
    }

    static func taskProgress(in source: String) -> (done: Int, total: Int) {
        let found = tasks(in: source)
        return (found.filter(\.isChecked).count, found.count)
    }

    // MARK: Blocks

    static func blocks(in source: String) -> [Block] {
        let text = Array(source.utf16)
        let all = lines(in: text)
        let roles = fenceRoles(in: text, lines: all)
        let markers = tasks(in: text, lines: all, roles: roles)
        var result: [Block] = []
        var index = 0
        while index < all.count {
            if isBlank(text, all[index]) {
                index += 1
                continue
            }
            let start = index
            let (kind, end) = scanBlock(from: start, text: text, lines: all, roles: roles)
            index = max(end, start + 1)
            let range = NSRange(
                location: all[start].start, length: all[index - 1].contentEnd - all[start].start)
            let slice = text[range.location..<(range.location + range.length)]
            let inside = markers.filter { $0.line >= start && $0.line < index }
            result.append(
                Block(
                    kind: kind, startLine: start, endLine: index, range: range,
                    text: String(decoding: slice, as: UTF16.self),
                    firstTaskIndex: inside.first?.index ?? 0, taskCount: inside.count))
        }
        return result
    }

    private static func scanBlock(
        from start: Int, text: [UInt16], lines: [Line], roles: [FenceRole]
    ) -> (BlockKind, Int) {
        let count = lines.count
        let line = lines[start]
        if roles[start] == .open {
            var end = start + 1
            while end < count {
                if roles[end] == .close {
                    end += 1
                    break
                }
                end += 1
            }
            return (.code(language: language(text, line)), end)
        }
        if let level = headingLevel(text, line) { return (.heading(level: level), start + 1) }
        if isRule(text, line) { return (.rule, start + 1) }
        if isQuote(text, line) {
            var end = start + 1
            while end < count, !isBlank(text, lines[end]), roles[end] == .none,
                isQuote(text, lines[end]) || !startsBlock(text, lines[end])
            {
                end += 1
            }
            return (.quote, end)
        }
        if isListItem(text, line) {
            return (.list, scanList(from: start, text: text, lines: lines, roles: roles))
        }
        if start + 1 < count, containsPipe(text, line), isTableDelimiter(text, lines[start + 1]) {
            var end = start + 2
            while end < count, !isBlank(text, lines[end]), roles[end] == .none,
                containsPipe(text, lines[end])
            {
                end += 1
            }
            return (.table, end)
        }
        var end = start + 1
        while end < count, !isBlank(text, lines[end]), roles[end] == .none {
            if let level = setextLevel(text, lines[end]) { return (.heading(level: level), end + 1) }
            if startsBlock(text, lines[end]) { break }
            end += 1
        }
        return (.paragraph, end)
    }

    private static func scanList(
        from start: Int, text: [UInt16], lines: [Line], roles: [FenceRole]
    ) -> Int {
        let count = lines.count
        var end = start + 1
        while end < count {
            if roles[end] == .body || roles[end] == .close {
                end += 1
                continue
            }
            let line = lines[end]
            if isBlank(text, line) {
                var next = end
                while next < count, isBlank(text, lines[next]) { next += 1 }
                guard next < count else { break }
                let nextLine = lines[next]
                let nested = indent(text, nextLine) >= 2
                if nested || (isListItem(text, nextLine) && !isRule(text, nextLine)) {
                    end = next
                    continue
                }
                break
            }
            let nested = indent(text, line) >= 2
            if !nested {
                if roles[end] == .open || headingLevel(text, line) != nil || isRule(text, line)
                    || isQuote(text, line)
                {
                    break
                }
            }
            end += 1
        }
        // A block never ends on blank lines.
        while end > start + 1, isBlank(text, lines[end - 1]) { end -= 1 }
        return end
    }

    private static func language(_ text: [UInt16], _ line: Line) -> String? {
        var index = firstNonSpace(text, line)
        let marker = text[index]
        while index < line.contentEnd, text[index] == marker { index += 1 }
        let info = String(decoding: text[index..<line.contentEnd], as: UTF16.self)
            .trimmingCharacters(in: .whitespaces)
        guard let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        else { return nil }
        return String(word)
    }

    private static func headingLevel(_ text: [UInt16], _ line: Line) -> Int? {
        guard indent(text, line) <= 3 else { return nil }
        var index = firstNonSpace(text, line)
        var level = 0
        while index < line.contentEnd, text[index] == 35 {
            index += 1
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        guard index == line.contentEnd || text[index] == 32 || text[index] == 9 else { return nil }
        return level
    }

    private static func isRule(_ text: [UInt16], _ line: Line) -> Bool {
        guard indent(text, line) <= 3 else { return false }
        let first = firstNonSpace(text, line)
        guard first < line.contentEnd else { return false }
        let marker = text[first]
        guard marker == 45 || marker == 42 || marker == 95 else { return false }
        var count = 0
        var index = first
        while index < line.contentEnd {
            if text[index] == marker {
                count += 1
            } else if text[index] != 32 && text[index] != 9 {
                return false
            }
            index += 1
        }
        return count >= 3
    }

    private static func setextLevel(_ text: [UInt16], _ line: Line) -> Int? {
        guard indent(text, line) <= 3 else { return nil }
        let first = firstNonSpace(text, line)
        guard first < line.contentEnd, text[first] == 61 || text[first] == 45 else { return nil }
        let marker = text[first]
        var index = first
        while index < line.contentEnd, text[index] == marker { index += 1 }
        while index < line.contentEnd, text[index] == 32 || text[index] == 9 { index += 1 }
        guard index == line.contentEnd else { return nil }
        return marker == 61 ? 1 : 2
    }

    private static func isQuote(_ text: [UInt16], _ line: Line) -> Bool {
        guard indent(text, line) <= 3 else { return false }
        let first = firstNonSpace(text, line)
        return first < line.contentEnd && text[first] == 62
    }

    private static func isListItem(_ text: [UInt16], _ line: Line) -> Bool {
        guard indent(text, line) <= 3, !isRule(text, line) else { return false }
        var index = firstNonSpace(text, line)
        let end = line.contentEnd
        guard index < end else { return false }
        if text[index] == 45 || text[index] == 42 || text[index] == 43 {
            index += 1
        } else {
            var digits = 0
            while index < end, text[index] >= 48, text[index] <= 57 {
                index += 1
                digits += 1
            }
            guard digits >= 1, digits <= 9, index < end, text[index] == 46 || text[index] == 41
            else { return false }
            index += 1
        }
        return index == end || text[index] == 32 || text[index] == 9
    }

    /// Lines that end a running paragraph without a blank line.
    private static func startsBlock(_ text: [UInt16], _ line: Line) -> Bool {
        headingLevel(text, line) != nil || isRule(text, line) || isQuote(text, line)
            || isListItem(text, line) || fenceOpener(text, line) != nil
    }

    private static func containsPipe(_ text: [UInt16], _ line: Line) -> Bool {
        text[line.start..<line.contentEnd].contains(124)
    }

    private static func isTableDelimiter(_ text: [UInt16], _ line: Line) -> Bool {
        var dashes = 0
        var pipes = 0
        for unit in text[line.start..<line.contentEnd] {
            switch unit {
            case 45: dashes += 1
            case 124: pipes += 1
            case 58, 32, 9: break
            default: return false
            }
        }
        return dashes >= 1 && pipes >= 1
    }

    // MARK: Code collapsing

    /// `block.text` with a fenced code body cut to `maxBodyLines` lines plus an
    /// ellipsis line. Other blocks, and short code, are returned unchanged.
    static func text(of block: Block, collapsingCodeTo maxBodyLines: Int) -> String {
        guard case .code = block.kind else { return block.text }
        let text = Array(block.text.utf16)
        let all = lines(in: text)
        guard all.count >= 2 else { return block.text }
        let roles = fenceRoles(in: text, lines: all)
        let hasCloser = roles.last == .close
        let bodyEnd = hasCloser ? all.count - 1 : all.count
        let bodyCount = bodyEnd - 1
        guard bodyCount > maxBodyLines else { return block.text }
        func slice(_ line: Line) -> String {
            String(decoding: text[line.start..<line.contentEnd], as: UTF16.self)
        }
        var out = [slice(all[0])]
        out.append(contentsOf: all[1...maxBodyLines].map(slice))
        out.append("…")
        if hasCloser { out.append(slice(all[all.count - 1])) }
        return out.joined(separator: "\n")
    }

    // MARK: Summary

    static func summary(of source: String) -> Summary {
        let blocks = blocks(in: source)
        let progress = taskProgress(in: source)
        var title: String?
        var excerpt: String?
        for block in blocks {
            switch block.kind {
            case .heading:
                if title == nil { title = headingText(of: block) }
            case .paragraph:
                if excerpt == nil {
                    let joined = block.text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    excerpt = plainText(joined)
                }
            default: break
            }
            if title != nil && excerpt != nil { break }
        }
        if excerpt == nil {
            for block in blocks {
                switch block.kind {
                case .list, .quote:
                    let first = block.text.components(separatedBy: .newlines).first ?? ""
                    let stripped = stripLineMarker(first)
                    if !stripped.isEmpty {
                        excerpt = plainText(stripped)
                    }
                default: break
                }
                if excerpt != nil { break }
            }
        }
        return Summary(
            title: title.flatMap { $0.isEmpty ? nil : $0 },
            excerpt: excerpt.flatMap { $0.isEmpty ? nil : $0 },
            tasksDone: progress.done, tasksTotal: progress.total)
    }

    private static func headingText(of block: Block) -> String {
        let first = (block.text.components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        var text = Substring(first)
        if text.hasPrefix("#") {
            text = text.drop { $0 == "#" }
            var trimmed = text.trimmingCharacters(in: .whitespaces)
            // Optional closing sequence: "Title ##".
            while trimmed.hasSuffix("#") { trimmed.removeLast() }
            return plainText(trimmed.trimmingCharacters(in: .whitespaces))
        }
        return plainText(first)
    }

    private static func stripLineMarker(_ line: String) -> String {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        while text.hasPrefix(">") { text = text.dropFirst().drop { $0 == " " } }
        if let first = text.first, "-*+".contains(first), text.dropFirst().first == " " {
            text = text.dropFirst(2)
        } else {
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            let rest = text.dropFirst(digits.count)
            if !digits.isEmpty, let mark = rest.first, mark == "." || mark == ")",
                rest.dropFirst().first == " "
            {
                text = rest.dropFirst(2)
            }
        }
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = text.dropFirst(box.count)
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Inline Markdown reduced to readable text: links and images keep their
    /// label, emphasis and code markers disappear.
    static func plainText(_ markdown: String) -> String {
        let chars = Array(markdown)
        var out = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "[" || (char == "!" && index + 1 < chars.count && chars[index + 1] == "[") {
                let open = char == "!" ? index + 1 : index
                if let close = chars[open...].firstIndex(of: "]"), close + 1 < chars.count,
                    chars[close + 1] == "(", let end = chars[(close + 1)...].firstIndex(of: ")")
                {
                    out += String(chars[(open + 1)..<close])
                    index = end + 1
                    continue
                }
            }
            if char == "`" || char == "*" {
                index += 1
                continue
            }
            if (char == "_" || char == "~") && index + 1 < chars.count && chars[index + 1] == char {
                index += 2
                continue
            }
            out.append(char)
            index += 1
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
