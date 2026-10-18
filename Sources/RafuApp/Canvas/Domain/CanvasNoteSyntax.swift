import Foundation

/// Light Markdown syntax runs for a note in Edit mode (review 7.8). The caller
/// maps each style to attributes on the TextKit storage. Only the lines that an
/// edit touched are scanned, so typing stays cheap.
nonisolated enum CanvasNoteSyntax {
    enum Style: Equatable, Sendable {
        case heading(Int)
        /// `**`, `*`, backticks, heading hashes, fence lines: shown in `textMuted`.
        case marker
        case strong
        case emphasis
        case code
        case fencedCode
        case link
        case quote
    }

    struct Run: Equatable, Sendable {
        let range: NSRange
        let style: Style
    }

    struct Result: Equatable, Sendable {
        /// Whole lines the runs were computed for. Reset attributes here first.
        let covered: NSRange
        let runs: [Run]
    }

    /// Line numbers of fence lines. When an edit changes this list, every line
    /// after it changes meaning and the whole note must be restyled.
    static func fenceSignature(of source: String) -> [Int] {
        let text = Array(source.utf16)
        let lines = CanvasNoteMarkdown.lines(in: text)
        let roles = CanvasNoteMarkdown.fenceRoles(in: text, lines: lines)
        return roles.indices.filter { roles[$0] == .open || roles[$0] == .close }
    }

    /// Styles the lines that intersect `range`, or every line when `range` is nil.
    static func runs(in source: String, restrictedTo range: NSRange?) -> Result {
        let text = Array(source.utf16)
        let lines = CanvasNoteMarkdown.lines(in: text)
        guard !lines.isEmpty else {
            return Result(covered: NSRange(location: 0, length: 0), runs: [])
        }
        let roles = CanvasNoteMarkdown.fenceRoles(in: text, lines: lines)
        var first = 0
        var last = lines.count - 1
        if let range {
            let probeEnd = range.location + max(range.length - 1, 0)
            first = lines.firstIndex { range.location < $0.end } ?? lines.count - 1
            last = lines.firstIndex { probeEnd < $0.end } ?? lines.count - 1
            last = max(first, last)
        }
        var runs: [Run] = []
        for index in first...last {
            let line = lines[index]
            let whole = NSRange(location: line.start, length: line.contentEnd - line.start)
            switch roles[index] {
            case .open, .close:
                if whole.length > 0 { runs.append(Run(range: whole, style: .marker)) }
            case .body:
                if whole.length > 0 { runs.append(Run(range: whole, style: .fencedCode)) }
            case .none:
                runs.append(contentsOf: lineRuns(text, line))
            }
        }
        let covered = NSRange(
            location: lines[first].start, length: lines[last].end - lines[first].start)
        return Result(covered: covered, runs: runs)
    }

    // MARK: One line

    private static func lineRuns(_ text: [UInt16], _ line: CanvasNoteMarkdown.Line) -> [Run] {
        var runs: [Run] = []
        var position = line.start
        let end = line.contentEnd
        while position < end, text[position] == 32 || text[position] == 9 { position += 1 }
        guard position < end else { return [] }

        var inlineStart = position
        var isHeading = false
        if text[position] == 35 {
            var hashes = 0
            while position + hashes < end, text[position + hashes] == 35 { hashes += 1 }
            let next = position + hashes
            if (1...6).contains(hashes), next == end || text[next] == 32 {
                runs.append(
                    Run(
                        range: NSRange(location: line.start, length: end - line.start),
                        style: .heading(hashes)))
                runs.append(Run(range: NSRange(location: position, length: hashes), style: .marker))
                inlineStart = min(next + 1, end)
                isHeading = true
            }
        } else if text[position] == 62 {
            runs.append(
                Run(range: NSRange(location: position, length: end - position), style: .quote))
        }
        let inline = inlineRuns(text, from: inlineStart, to: end)
        if isHeading {
            // A heading keeps its own size; only the markers inside it are muted.
            runs.append(contentsOf: inline.filter { $0.style == .marker })
        } else {
            runs.append(contentsOf: inline)
        }
        return runs
    }

    private static func inlineRuns(_ text: [UInt16], from start: Int, to end: Int) -> [Run] {
        var runs: [Run] = []
        var index = start
        while index < end {
            let unit = text[index]
            if unit == 96 {
                var open = 0
                while index + open < end, text[index + open] == 96 { open += 1 }
                if let close = findRun(text, of: 96, length: open, from: index + open, to: end) {
                    runs.append(Run(range: NSRange(location: index, length: open), style: .marker))
                    if close > index + open {
                        runs.append(
                            Run(
                                range: NSRange(
                                    location: index + open, length: close - index - open),
                                style: .code))
                    }
                    runs.append(Run(range: NSRange(location: close, length: open), style: .marker))
                    index = close + open
                } else {
                    index += open
                }
            } else if unit == 42 {
                let double = index + 1 < end && text[index + 1] == 42
                let width = double ? 2 : 1
                let contentStart = index + width
                guard contentStart < end, text[contentStart] != 32, text[contentStart] != 9
                else {
                    index += width
                    continue
                }
                if let close = findEmphasisClose(text, width: width, from: contentStart, to: end) {
                    runs.append(Run(range: NSRange(location: index, length: width), style: .marker))
                    runs.append(
                        Run(
                            range: NSRange(location: contentStart, length: close - contentStart),
                            style: double ? .strong : .emphasis))
                    runs.append(Run(range: NSRange(location: close, length: width), style: .marker))
                    index = close + width
                } else {
                    index += width
                }
            } else if unit == 91 {
                if let finish = linkEnd(text, from: index, to: end) {
                    runs.append(
                        Run(range: NSRange(location: index, length: finish - index), style: .link))
                    index = finish
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return runs
    }

    /// Start of the next run of exactly `length` copies of `unit`.
    private static func findRun(
        _ text: [UInt16], of unit: UInt16, length: Int, from start: Int, to end: Int
    ) -> Int? {
        var index = start
        while index < end {
            if text[index] == unit {
                var run = 0
                while index + run < end, text[index + run] == unit { run += 1 }
                if run == length { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func findEmphasisClose(
        _ text: [UInt16], width: Int, from start: Int, to end: Int
    ) -> Int? {
        var index = start
        while index < end {
            if text[index] == 96 {
                // Skip code spans so `*` inside them does not close emphasis.
                var open = 0
                while index + open < end, text[index + open] == 96 { open += 1 }
                if let close = findRun(text, of: 96, length: open, from: index + open, to: end) {
                    index = close + open
                } else {
                    index += open
                }
            } else if text[index] == 42 {
                var run = 0
                while index + run < end, text[index + run] == 42 { run += 1 }
                if run == width, index > start, text[index - 1] != 32, text[index - 1] != 9 {
                    return index
                }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    /// End (exclusive) of a `[label](target)` link that starts at `start`.
    private static func linkEnd(_ text: [UInt16], from start: Int, to end: Int) -> Int? {
        var index = start + 1
        while index < end, text[index] != 93 { index += 1 }
        guard index + 1 < end, index > start + 1, text[index + 1] == 40 else { return nil }
        index += 2
        while index < end, text[index] != 41 { index += 1 }
        return index < end ? index + 1 : nil
    }
}
