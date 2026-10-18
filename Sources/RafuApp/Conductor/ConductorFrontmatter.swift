import Foundation

/// Why a SKILL.md frontmatter block could not be read. Every case carries the
/// 1-based line number so the user can jump straight to it; no case ever
/// carries file CONTENT beyond the short token that was rejected.
nonisolated enum ConductorParseError: Error, Equatable, LocalizedError, Sendable {
    /// The file does not start with a `---` frontmatter fence.
    case missingFrontmatter(line: Int)
    /// The opening `---` is never closed.
    case unterminatedFrontmatter(line: Int)
    /// A frontmatter line is neither `key: value` nor a list item.
    case malformedFrontmatterLine(line: Int)

    var errorDescription: String? {
        switch self {
        case .missingFrontmatter(let line):
            "Line \(line): expected a \"---\" frontmatter fence."
        case .unterminatedFrontmatter(let line):
            "Line \(line): the frontmatter opened here is never closed with \"---\"."
        case .malformedFrontmatterLine(let line):
            "Line \(line): expected \"key: value\"."
        }
    }
}

/// Dependency-free frontmatter scanning. Rafu ships no YAML dependency and
/// does not want one for this: the accepted grammar is deliberately a tiny,
/// documented subset (`---` fences and `key: value` scalars), so a full YAML
/// engine would promise far more than the format defines.
nonisolated enum ConductorFrontmatter {
    /// One physical line plus its 1-based number.
    nonisolated struct Line: Equatable, Sendable {
        let number: Int
        let text: String
    }

    /// The fence contents and where the body starts.
    nonisolated struct Block: Equatable, Sendable {
        let lines: [Line]
        /// Index into `allLines` of the first body line after the closing
        /// fence.
        let bodyStart: Int
        /// 1-based line number of the closing fence, for error reporting.
        let closingLineNumber: Int
    }

    static let fence = "---"

    /// Splits on newlines, tolerating CRLF, and numbers every line from 1.
    static func lines(of text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, raw in
                var value = String(raw)
                if value.hasSuffix("\r") { value.removeLast() }
                return Line(number: index + 1, text: value)
            }
    }

    /// Locates the leading `---` … `---` block. Leading blank lines are
    /// allowed; anything else before the fence is a `missingFrontmatter`.
    static func block(in allLines: [Line]) throws -> Block {
        guard
            let openIndex = allLines.firstIndex(where: {
                !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
            })
        else {
            throw ConductorParseError.missingFrontmatter(line: 1)
        }
        let open = allLines[openIndex]
        guard open.text.trimmingCharacters(in: .whitespaces) == fence else {
            throw ConductorParseError.missingFrontmatter(line: open.number)
        }
        guard
            let closeIndex = allLines[(openIndex + 1)...].firstIndex(where: {
                $0.text.trimmingCharacters(in: .whitespaces) == fence
            })
        else {
            throw ConductorParseError.unterminatedFrontmatter(line: open.number)
        }
        return Block(
            lines: Array(allLines[(openIndex + 1)..<closeIndex]),
            bodyStart: closeIndex + 1,
            closingLineNumber: allLines[closeIndex].number)
    }

    /// Splits `key: value`, or `nil` for a blank line or a `#` comment.
    /// Keys are matched case-INSENSITIVELY (these are hand-written files);
    /// values keep their case because they are contract raw values.
    static func scalar(_ line: Line) throws -> (key: String, value: String)? {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        guard let separator = trimmed.firstIndex(of: ":") else {
            throw ConductorParseError.malformedFrontmatterLine(line: line.number)
        }
        let key = String(trimmed[trimmed.startIndex..<separator])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !key.isEmpty else {
            throw ConductorParseError.malformedFrontmatterLine(line: line.number)
        }
        let value = unquoted(
            String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces))
        return (key, value)
    }

    /// Strips ONE matched pair of surrounding single or double quotes.
    static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        guard first == "\"" || first == "'", value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Drops leading and trailing whitespace-only lines while preserving
    /// internal blank lines.
    static func trimmedBody(_ lines: ArraySlice<Line>) -> String {
        var body = Array(lines)
        while let first = body.first, first.text.trimmingCharacters(in: .whitespaces).isEmpty {
            body.removeFirst()
        }
        while let last = body.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
            body.removeLast()
        }
        return body.map(\.text).joined(separator: "\n")
    }
}
