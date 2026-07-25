import Foundation

nonisolated struct MarkdownBlock: Identifiable, Sendable {
    enum Content: Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case quote(String)
        case code(language: String?, text: String)
        case mermaid(MermaidParseResult)
        case divider
    }

    let id: UUID
    let content: Content

    private init(_ content: Content) {
        id = UUID()
        self.content = content
    }

    static func heading(level: Int, text: String) -> Self {
        Self(.heading(level: level, text: text))
    }
    static func paragraph(_ text: String) -> Self { Self(.paragraph(text)) }
    static func bullet(_ text: String) -> Self { Self(.bullet(text)) }
    static func quote(_ text: String) -> Self { Self(.quote(text)) }
    static func code(language: String?, text: String) -> Self {
        Self(.code(language: language, text: text))
    }
    static func mermaid(_ result: MermaidParseResult) -> Self { Self(.mermaid(result)) }
    static var divider: Self { Self(.divider) }
}

/// The six Mermaid diagram types BeautifulMermaid renders (ADR 0020). Purely
/// a routing key — no per-diagram parsed model lives on the Rafu side
/// anymore; `BeautifulMermaid` owns parsing, layout, and rendering behind
/// the `MermaidRenderService` actor boundary.
nonisolated enum MermaidDiagramKind: String, Sendable, Hashable {
    case flowchart, stateDiagram, sequenceDiagram, classDiagram, erDiagram, xyChart
}

/// A classified, render-ready Mermaid diagram. `raw` is exactly what the
/// author wrote (shown verbatim in the honest fallback); `source` is `raw`
/// after `normalizeMermaid(_:)` — the compensating rewrite ADR 0020 documents
/// for upstream's stricter header parsing — and is never shown to the user.
nonisolated struct MermaidDiagram: Sendable, Hashable {
    let kind: MermaidDiagramKind
    let declaredType: String
    let raw: String
    let source: String
}

nonisolated enum MermaidParseResult: Sendable {
    case diagram(MermaidDiagram)
    case unsupported(type: String, raw: String)
    case malformed(type: String, raw: String, reason: String)
}

nonisolated struct MarkdownParser: Sendable {
    func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language: String?
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inFence {
                    let text = code.joined(separator: "\n")
                    blocks.append(
                        language == "mermaid"
                            ? .mermaid(parseMermaid(text)) : .code(language: language, text: text))
                    code.removeAll()
                    language = nil
                    inFence = false
                } else {
                    flushParagraph()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    inFence = true
                }
                continue
            }
            if inFence {
                code.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }
            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        if inFence { blocks.append(.code(language: language, text: code.joined(separator: "\n"))) }
        return blocks
    }

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        let count = line.prefix { $0 == "#" }.count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return .heading(level: count, text: String(line.dropFirst(count + 1)))
    }

    /// Mermaid v10 diagram types Rafu does not render natively (23 types).
    /// `classDiagram`, `stateDiagram`/`stateDiagram-v2`, `erDiagram`, and
    /// `xychart`/`xychart-beta` moved out of this set under ADR 0020 — all
    /// six BeautifulMermaid-supported types are enabled unconditionally.
    private static let unsupportedTypes: Set<String> = [
        "gantt", "pie", "journey", "gitgraph", "mindmap", "timeline", "quadrantchart",
        "requirement", "requirementdiagram", "c4context", "c4container", "c4component",
        "c4dynamic", "c4deployment", "sankey", "sankey-beta", "block", "block-beta", "packet",
        "packet-beta", "kanban", "architecture", "architecture-beta",
    ]

    /// Maps a lowercased, semicolon-stripped header token to its
    /// `MermaidDiagramKind`, or `nil` if the token is not one of the six
    /// BeautifulMermaid-supported types.
    private static let supportedKinds: [String: MermaidDiagramKind] = [
        "flowchart": .flowchart,
        "graph": .flowchart,
        "statediagram": .stateDiagram,
        "statediagram-v2": .stateDiagram,
        "sequencediagram": .sequenceDiagram,
        "classdiagram": .classDiagram,
        "erdiagram": .erDiagram,
        "xychart": .xyChart,
        "xychart-beta": .xyChart,
    ]

    func parseMermaid(_ raw: String) -> MermaidParseResult {
        guard let header = firstHeaderLine(raw), !header.isEmpty else {
            return .malformed(type: "", raw: raw, reason: "empty diagram")
        }
        let token = header.prefix { !$0.isWhitespace }
        var key = String(token).lowercased()
        if key.hasSuffix(";") { key.removeLast() }

        if let kind = Self.supportedKinds[key] {
            return .diagram(
                MermaidDiagram(
                    kind: kind, declaredType: String(token), raw: raw,
                    source: normalizeMermaid(raw)))
        }
        if Self.unsupportedTypes.contains(key) {
            return .unsupported(type: String(token), raw: raw)
        }
        return .malformed(type: String(token), raw: raw, reason: "unknown diagram type '\(token)'")
    }

    /// Finds the index of the first significant (non-blank, non-frontmatter, non-`%%`) line.
    private func headerIndex(_ lines: [String]) -> Int? {
        var index = 0
        while index < lines.count, lines[index].isEmpty { index += 1 }
        if index < lines.count, lines[index] == "---" {
            index += 1
            while index < lines.count, lines[index] != "---" { index += 1 }
            if index < lines.count { index += 1 }
        }
        while index < lines.count, lines[index].isEmpty || lines[index].hasPrefix("%%") {
            index += 1
        }
        guard index < lines.count else { return nil }
        return index
    }

    private func firstHeaderLine(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let index = headerIndex(lines) else { return nil }
        return lines[index]
    }

    /// Rewrites `raw` so BeautifulMermaid's stricter header parsing (ADR
    /// 0020, "Compensating work Rafu must carry") accepts sources Rafu
    /// already classified as valid:
    ///
    /// - Locates the header using the same blank-line/frontmatter/`%%`
    ///   skipping logic as classification (`headerIndex`), reused here
    ///   rather than reimplemented, and drops everything before it — the
    ///   dependency has no frontmatter awareness at all.
    /// - A bare `flowchart` or `graph` header (no direction token, only an
    ///   optional trailing `;`) gets a default `TD` appended, since upstream
    ///   requires an explicit direction. Any other spelling — including
    ///   `stateDiagram-v2` and `xychart-beta`, which upstream dispatches on
    ///   `hasPrefix` — is passed through untouched.
    ///
    /// Only ever changes the value handed to BeautifulMermaid
    /// (`MermaidDiagram.source`); `MermaidDiagram.raw`, shown verbatim in
    /// the honest fallback, is never touched.
    private func normalizeMermaid(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = headerIndex(trimmedLines) else { return raw }

        var headerToken = trimmedLines[index]
        if headerToken.hasSuffix(";") { headerToken.removeLast() }
        let needsDirection =
            headerToken.caseInsensitiveCompare("flowchart") == .orderedSame
            || headerToken.caseInsensitiveCompare("graph") == .orderedSame
        let header = needsDirection ? "\(headerToken) TD" : trimmedLines[index]

        let body = lines[(index + 1)...]
        return ([header] + body).joined(separator: "\n")
    }
}
