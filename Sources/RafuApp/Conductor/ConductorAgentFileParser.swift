import Foundation

/// Why a `.rafu/agents/*.md` or `.rafu/workflows/*.md` file could not be
/// read. Every case carries the 1-based line number so the user can jump
/// straight to it; no case ever carries file CONTENT beyond the short token
/// that was rejected.
nonisolated enum ConductorParseError: Error, Equatable, LocalizedError, Sendable {
    /// The file does not start with a `---` frontmatter fence.
    case missingFrontmatter(line: Int)
    /// The opening `---` is never closed.
    case unterminatedFrontmatter(line: Int)
    /// A frontmatter line is neither `key: value` nor a list item.
    case malformedFrontmatterLine(line: Int)
    /// `provider:` is absent — it has no safe default.
    case missingProvider(line: Int)
    /// `provider:` names a CLI this build does not ship an adapter for.
    case unrecognizedProvider(String, line: Int)
    /// A `steps:` entry does not match `- <agent> [<- a, b] [[gate]]`.
    case malformedStep(line: Int)
    /// A workflow declared no steps.
    case workflowHasNoSteps(line: Int)

    var errorDescription: String? {
        switch self {
        case .missingFrontmatter(let line):
            "Line \(line): expected a \"---\" frontmatter fence."
        case .unterminatedFrontmatter(let line):
            "Line \(line): the frontmatter opened here is never closed with \"---\"."
        case .malformedFrontmatterLine(let line):
            "Line \(line): expected \"key: value\"."
        case .missingProvider(let line):
            "Line \(line): frontmatter is missing a required \"provider\" key."
        case .unrecognizedProvider(let raw, let line):
            "Line \(line): \"\(raw)\" is not a supported agent CLI."
        case .malformedStep(let line):
            "Line \(line): expected \"- <agent> [<- artifact, …] [[gate]]\"."
        case .workflowHasNoSteps(let line):
            "Line \(line): the workflow declares no steps."
        }
    }
}

/// Shared, dependency-free frontmatter scanning for both `.rafu/` file
/// parsers. Rafu ships no YAML dependency and does not want one for this:
/// the accepted grammar is deliberately a tiny, documented subset (`---`
/// fences, `key: value` scalars, and — for workflows — one flat list), so a
/// full YAML engine would promise far more than the format defines.
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

/// Parses one `.rafu/agents/<stem>.md` role file (ADR 0018: files are the
/// source of truth). Accepted shape:
///
/// ```
/// ---
/// name: Advisor
/// provider: claudeCode
/// model: claude-sonnet-4-5
/// autonomy: readOnly
/// handoffArtifact: brief.md
/// ---
/// You are the advisor…
/// ```
///
/// UNKNOWN KEYS ARE IGNORED so a file authored for a newer Rafu (or carrying
/// another tool's metadata) still loads. `provider` is the ONE required key.
///
/// That tolerance extends to LIST-shaped foreign metadata — the commonest
/// shape there is (`tags:` followed by `- release`) — whose continuation
/// lines carry no `:` and would otherwise be rejected outright. Rafu reads
/// nothing from them; it just does not fail the whole role file over
/// metadata it was never asked to understand. Workflow files are the
/// opposite case and keep their strict list handling: there, `- ` lines ARE
/// the grammar.
nonisolated enum ConductorAgentFileParser {
    /// Default handoff filename when the file does not name one.
    static let defaultHandoffArtifact = "handoff.md"

    /// - Parameter defaultName: the file's stem, used when frontmatter has
    ///   no `name`.
    static func parse(_ text: String, defaultName: String) throws -> ConductorAgentDefinition {
        let all = ConductorFrontmatter.lines(of: text)
        let block = try ConductorFrontmatter.block(in: all)

        var values: [String: String] = [:]
        for line in block.lines {
            // A list continuation belonging to a key this build does not
            // know (`tags:` / `- release`). Skipped, not parsed: Rafu reads
            // no list-valued key, and throwing here would make the
            // ignore-unknown-keys promise above false for the commonest
            // shape of another tool's metadata.
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed == "-" || trimmed.hasPrefix("- ") { continue }

            guard let scalar = try ConductorFrontmatter.scalar(line) else { continue }
            values[scalar.key] = scalar.value
        }

        guard let rawProvider = values["provider"], !rawProvider.isEmpty else {
            throw ConductorParseError.missingProvider(line: block.closingLineNumber)
        }
        guard let provider = ConductorCLIID(rawValue: rawProvider) else {
            throw ConductorParseError.unrecognizedProvider(
                rawProvider, line: block.closingLineNumber)
        }

        let name = nonEmpty(values["name"]) ?? defaultName
        // LEAST PRIVILEGE: an autonomy value this build cannot parse falls
        // back to `.readOnly`. A typo must never widen a role's write
        // access — the opposite default would let a misspelling hand an
        // agent a writable worktree.
        let autonomy = values["autonomy"].flatMap(ConductorAutonomy.init(rawValue:)) ?? .readOnly

        return ConductorAgentDefinition(
            name: name,
            provider: provider,
            model: nonEmpty(values["model"]) ?? "",
            autonomy: autonomy,
            handoffArtifact: nonEmpty(values["handoffartifact"]) ?? defaultHandoffArtifact,
            promptBody: ConductorFrontmatter.trimmedBody(all[block.bodyStart...]))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
