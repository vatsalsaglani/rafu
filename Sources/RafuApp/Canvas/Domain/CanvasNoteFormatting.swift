import Foundation

/// Markdown formatting actions for a Canvas note in Edit mode (review 7.8).
nonisolated enum CanvasNoteFormatCommand: Hashable, CaseIterable, Sendable {
    case bold, italic, code, link
    case bullets, numbers, task
    case heading1, heading2, heading3, body

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .code: "Code"
        case .link: "Link"
        case .bullets: "Bulleted List"
        case .numbers: "Numbered List"
        case .task: "Task Item"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .body: "Body Text"
        }
    }

    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .bullets: "list.bullet"
        case .numbers: "list.number"
        case .task: "checklist"
        case .heading1, .heading2, .heading3: "textformat.size"
        case .body: "textformat"
        }
    }

    /// Symbols for the five-icon compact bar.
    static let compactBar: [CanvasNoteFormatCommand] = [.bold, .italic, .code, .link, .task]
}

/// What a keystroke means inside a note in Edit mode. Key codes are the
/// physical ANSI positions, so the mapping does not depend on modifier-altered
/// characters (Shift-7 types "&", Option-1 types "¡").
nonisolated enum CanvasNoteShortcuts {
    static func command(
        keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool
    ) -> CanvasNoteFormatCommand? {
        guard command, !control else { return nil }
        switch (keyCode, shift, option) {
        case (11, false, false): return .bold
        case (34, false, false): return .italic
        case (40, false, false): return .link
        case (14, false, false): return .code
        case (26, true, false): return .bullets
        case (25, true, false): return .numbers
        case (37, true, false): return .task
        case (18, false, true): return .heading1
        case (19, false, true): return .heading2
        case (20, false, true): return .heading3
        case (29, false, true): return .body
        default: return nil
        }
    }

    /// Escape, or Command-Return (main or keypad), leaves Edit mode.
    static func exitsEditing(
        keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool
    ) -> Bool {
        if keyCode == 53 { return !command && !shift && !option && !control }
        if keyCode == 36 || keyCode == 76 { return command && !shift && !option && !control }
        return false
    }
}

nonisolated struct CanvasNoteFormatResult: Equatable, Sendable {
    /// Replace this range of the source with `replacement`, then select
    /// `selection` (UTF-16, in the new text).
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

/// Pure text transformations behind the Format menu and shortcuts. Each one is
/// a single replacement, so the TextKit buffer can apply it as one undo step.
nonisolated enum CanvasNoteFormatting {
    static func apply(
        _ command: CanvasNoteFormatCommand, to text: String, selection: NSRange
    ) -> CanvasNoteFormatResult? {
        let length = text.utf16.count
        guard selection.location >= 0, selection.length >= 0,
            selection.location + selection.length <= length
        else { return nil }
        switch command {
        case .bold: return wrapInline("**", in: text, selection: selection, italic: false)
        case .italic: return wrapInline("*", in: text, selection: selection, italic: true)
        case .code: return wrapInline("`", in: text, selection: selection, italic: false)
        case .link: return link(in: text, selection: selection)
        case .bullets: return restyleLines(.bullets, in: text, selection: selection)
        case .numbers: return restyleLines(.numbers, in: text, selection: selection)
        case .task: return restyleLines(.task, in: text, selection: selection)
        case .heading1: return restyleLines(.heading1, in: text, selection: selection)
        case .heading2: return restyleLines(.heading2, in: text, selection: selection)
        case .heading3: return restyleLines(.heading3, in: text, selection: selection)
        case .body: return restyleLines(.body, in: text, selection: selection)
        }
    }

    // MARK: Inline

    private static func wrapInline(
        _ marker: String, in text: String, selection: NSRange, italic: Bool
    ) -> CanvasNoteFormatResult {
        let source = NSString(string: text)
        let width = marker.utf16.count
        let selected = source.substring(with: selection)
        func piece(_ location: Int, _ length: Int) -> String? {
            guard location >= 0, location + length <= source.length else { return nil }
            return source.substring(with: NSRange(location: location, length: length))
        }
        let doubled =
            piece(selection.location - 2, 2) == "**"
            && piece(selection.location + selection.length, 2) == "**"
        let tripled =
            doubled && piece(selection.location - 3, 1) == "*"
            && piece(selection.location + selection.length + 2, 1) == "*"
        let before = piece(selection.location - width, width) == marker
        let after = piece(selection.location + selection.length, width) == marker
        let surrounded = before && after && !(italic && doubled && !tripled)

        if selection.length == 0 {
            if surrounded {
                return CanvasNoteFormatResult(
                    range: NSRange(location: selection.location - width, length: width * 2),
                    replacement: "",
                    selection: NSRange(location: selection.location - width, length: 0))
            }
            return CanvasNoteFormatResult(
                range: selection, replacement: marker + marker,
                selection: NSRange(location: selection.location + width, length: 0))
        }
        if selected.utf16.count >= width * 2, selected.hasPrefix(marker),
            selected.hasSuffix(marker)
        {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            let ambiguous =
                italic && inner.hasPrefix("*") && !(selected.hasPrefix("***")
                    && selected.hasSuffix("***"))
            if !ambiguous {
                return CanvasNoteFormatResult(
                    range: selection, replacement: inner,
                    selection: NSRange(location: selection.location, length: inner.utf16.count))
            }
        }
        if surrounded {
            return CanvasNoteFormatResult(
                range: NSRange(
                    location: selection.location - width, length: selection.length + width * 2),
                replacement: selected,
                selection: NSRange(location: selection.location - width, length: selection.length))
        }
        return CanvasNoteFormatResult(
            range: selection, replacement: marker + selected + marker,
            selection: NSRange(location: selection.location + width, length: selection.length))
    }

    private static func link(in text: String, selection: NSRange) -> CanvasNoteFormatResult {
        let selected = NSString(string: text).substring(with: selection)
        if selection.length == 0 {
            return CanvasNoteFormatResult(
                range: selection, replacement: "[](url)",
                selection: NSRange(location: selection.location + 1, length: 0))
        }
        let lowered = selected.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return CanvasNoteFormatResult(
                range: selection, replacement: "[link](" + selected + ")",
                selection: NSRange(location: selection.location + 1, length: 4))
        }
        return CanvasNoteFormatResult(
            range: selection, replacement: "[" + selected + "](url)",
            selection: NSRange(
                location: selection.location + 1 + selected.utf16.count + 2, length: 3))
    }

    // MARK: Line prefixes

    private enum Marker: Equatable {
        case none
        case heading(Int)
        case bullet
        case task(Bool)
        case number
    }

    private struct Parts {
        var indent: String
        var marker: Marker
        var body: String
        var isBlank: Bool { body.isEmpty && marker == .none }
    }

    private static func parse(_ line: String) -> Parts {
        let chars = Array(line)
        var index = 0
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        let indent = String(chars[..<index])
        let rest = Array(chars[index...])
        func body(from offset: Int) -> String {
            var start = offset
            while start < rest.count, rest[start] == " " { start += 1 }
            return String(rest[start...])
        }
        if rest.first == "#" {
            var count = 0
            while count < rest.count, rest[count] == "#" { count += 1 }
            if (1...6).contains(count), count == rest.count || rest[count] == " " {
                return Parts(indent: indent, marker: .heading(count), body: body(from: count))
            }
        }
        if rest.count >= 2, "-*+".contains(rest[0]), rest[1] == " " {
            let after = body(from: 2)
            for (box, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
                if after == box {
                    return Parts(indent: indent, marker: .task(checked), body: "")
                }
                if after.hasPrefix(box + " ") {
                    return Parts(
                        indent: indent, marker: .task(checked),
                        body: String(after.dropFirst(box.count + 1)))
                }
            }
            return Parts(indent: indent, marker: .bullet, body: after)
        }
        var digits = 0
        while digits < rest.count, rest[digits].isASCII, rest[digits].isNumber { digits += 1 }
        if (1...9).contains(digits), digits + 1 < rest.count,
            rest[digits] == "." || rest[digits] == ")", rest[digits + 1] == " "
        {
            return Parts(indent: indent, marker: .number, body: body(from: digits + 1))
        }
        return Parts(indent: indent, marker: .none, body: String(rest))
    }

    private static func render(_ parts: Parts, number: Int) -> String {
        let prefix: String
        switch parts.marker {
        case .none: prefix = ""
        case .heading(let level): prefix = String(repeating: "#", count: level) + " "
        case .bullet: prefix = "- "
        case .task(let checked): prefix = checked ? "- [x] " : "- [ ] "
        case .number: prefix = "\(number). "
        }
        return parts.indent + prefix + parts.body
    }

    private enum LineCommand {
        case bullets, numbers, task, heading1, heading2, heading3, body
    }

    private static func affectedLines(
        _ text: [UInt16], _ lines: [CanvasNoteMarkdown.Line], selection: NSRange
    ) -> ArraySlice<CanvasNoteMarkdown.Line> {
        let synthetic = CanvasNoteMarkdown.Line(
            start: text.count, contentEnd: text.count, end: text.count)
        var all = lines
        if all.isEmpty || all[all.count - 1].end > all[all.count - 1].contentEnd {
            all.append(synthetic)
        }
        func index(containing offset: Int) -> Int {
            for (position, line) in all.enumerated() where offset < line.end { return position }
            return all.count - 1
        }
        let first = index(containing: selection.location)
        let last =
            selection.length > 0 ? index(containing: selection.location + selection.length - 1)
            : first
        return all[first...max(first, last)]
    }

    private static func restyleLines(
        _ command: LineCommand, in text: String, selection: NSRange
    ) -> CanvasNoteFormatResult {
        let units = Array(text.utf16)
        let covered = affectedLines(units, CanvasNoteMarkdown.lines(in: units), selection: selection)
        let pieces = covered.map { line -> (parts: Parts, terminator: String) in
            let content = String(decoding: units[line.start..<line.contentEnd], as: UTF16.self)
            let terminator = String(decoding: units[line.contentEnd..<line.end], as: UTF16.self)
            return (parse(content), terminator)
        }
        var targets = pieces.indices.filter { !pieces[$0].parts.isBlank }
        if targets.isEmpty { targets = Array(pieces.indices) }

        func allMatch(_ test: (Marker) -> Bool) -> Bool {
            targets.allSatisfy { test(pieces[$0].parts.marker) }
        }
        var updated = pieces.map(\.parts)
        switch command {
        case .bullets:
            let remove = allMatch { $0 == .bullet }
            for index in targets { updated[index].marker = remove ? .none : .bullet }
        case .numbers:
            let remove = allMatch { $0 == .number }
            for index in targets { updated[index].marker = remove ? .none : .number }
        case .task:
            let remove = allMatch {
                if case .task = $0 { return true }
                return false
            }
            for index in targets {
                if remove {
                    updated[index].marker = .none
                } else if case .task = updated[index].marker {
                    continue
                } else {
                    updated[index].marker = .task(false)
                }
            }
        case .heading1, .heading2, .heading3:
            let level = command == .heading1 ? 1 : (command == .heading2 ? 2 : 3)
            let remove = allMatch { $0 == .heading(level) }
            for index in targets { updated[index].marker = remove ? .none : .heading(level) }
        case .body:
            for index in targets {
                if case .heading = updated[index].marker { updated[index].marker = .none }
            }
        }

        var number = 0
        var output = ""
        for index in pieces.indices {
            if targets.contains(index), updated[index].marker == .number { number += 1 }
            output += render(updated[index], number: max(number, 1))
            if index < pieces.count - 1 { output += pieces[index].terminator }
        }
        let first = covered.first!
        let last = covered.last!
        let range = NSRange(location: first.start, length: last.contentEnd - first.start)
        let newLength = output.utf16.count
        let newSelection: NSRange
        if selection.length == 0 && pieces.count == 1 {
            let delta = newLength - range.length
            let caret = min(max(selection.location + delta, range.location), range.location + newLength)
            newSelection = NSRange(location: caret, length: 0)
        } else {
            newSelection = NSRange(location: range.location, length: newLength)
        }
        return CanvasNoteFormatResult(range: range, replacement: output, selection: newSelection)
    }
}
