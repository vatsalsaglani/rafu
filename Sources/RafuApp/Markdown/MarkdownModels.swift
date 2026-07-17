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

nonisolated enum MermaidParseResult: Sendable {
    case flow(MermaidFlow)
    case sequence(MermaidSequence)
    case unsupported(type: String, raw: String)
    case malformed(type: String, raw: String, reason: String)
}

nonisolated struct MermaidFlow: Sendable {
    nonisolated enum Direction: Sendable, Equatable {
        case topToBottom, bottomToTop, leftToRight, rightToLeft
    }
    nonisolated enum NodeShape: Sendable, Equatable {
        case rectangle  // [ ]
        case round  // ( )   (round / stadium)
        case diamond  // { }
        case circle  // (( ))
        case subroutine  // [[ ]]
        case parallelogram  // [/ /]
        case flag  // > ]   (asymmetric)
    }
    nonisolated enum EdgeLine: Sendable, Equatable { case solid, dotted, thick }
    nonisolated enum EdgeHead: Sendable, Equatable { case none, arrow, circle, cross }

    nonisolated struct Node: Sendable {
        let id: String
        var label: String
        var shape: NodeShape
    }
    nonisolated struct Edge: Sendable {
        let id = UUID()
        let from: String
        let to: String
        let label: String
        var line: EdgeLine = .solid
        var startHead: EdgeHead = .none
        var endHead: EdgeHead = .arrow
    }
    nonisolated struct Subgraph: Identifiable, Sendable {
        let id = UUID()
        let name: String
        var title: String
        var nodeIDs: [String]
        var children: [Subgraph]
    }

    let raw: String
    let direction: Direction
    let nodesByID: [String: Node]
    let nodes: [String: String]  // M4-compat: id -> label, derived once from nodesByID
    let edges: [Edge]
    let subgraphs: [Subgraph]  // root-level; nested subgraphs live in `.children`
}

nonisolated struct MermaidSequence: Sendable {
    nonisolated enum ParticipantKind: Sendable, Equatable {
        case participant, actor
    }
    /// `->` `->>` `-->` `-->>`, in order of increasing token length.
    nonisolated enum Arrow: Sendable, Equatable {
        case solid, solidArrow, dotted, dottedArrow
    }
    nonisolated struct Message: Sendable {
        let id = UUID()
        let from: String
        let to: String
        let label: String
        let arrow: Arrow
        let activatesTarget: Bool
        let deactivatesSource: Bool
        var isSelfMessage: Bool { from == to }
    }
    nonisolated enum NotePlacement: Sendable, Equatable {
        case over([String])
        case leftOf(String)
        case rightOf(String)
    }
    nonisolated struct Note: Sendable {
        let id = UUID()
        let placement: NotePlacement
        let text: String
    }
    nonisolated enum BlockKind: Sendable, Equatable {
        case alt, opt, loop, par
    }
    nonisolated struct Block: Sendable {
        let id = UUID()
        let kind: BlockKind
        let title: String
    }
    nonisolated enum Event: Sendable {
        case message(Message)
        case note(Note)
        case blockStart(Block)
        case blockDivider(blockID: UUID, label: String)
        case blockEnd(blockID: UUID)
        case activate(String)
        case deactivate(String)
    }
    let raw: String
    let participants: [String]
    let participantKinds: [String: ParticipantKind]
    let participantDisplay: [String: String]
    let messages: [Message]
    let events: [Event]
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

    private static let unsupportedTypes: Set<String> = [
        "classdiagram", "statediagram", "statediagram-v2", "erdiagram", "gantt", "pie", "journey",
        "gitgraph", "mindmap", "timeline", "quadrantchart", "requirement", "requirementdiagram",
        "c4context", "c4container", "c4component", "c4dynamic", "c4deployment", "sankey",
        "sankey-beta", "xychart", "xychart-beta", "block", "block-beta", "packet", "packet-beta",
        "kanban", "architecture", "architecture-beta",
    ]

    func parseMermaid(_ raw: String) -> MermaidParseResult {
        guard let header = firstHeaderLine(raw), !header.isEmpty else {
            return .malformed(type: "", raw: raw, reason: "empty diagram")
        }
        let token = header.prefix { !$0.isWhitespace }
        let key = String(token).lowercased()
        switch key {
        case "flowchart", "graph":
            return .flow(parseFlow(raw))
        case "sequencediagram":
            return .sequence(parseSequence(raw))
        case _ where Self.unsupportedTypes.contains(key):
            return .unsupported(type: String(token), raw: raw)
        default:
            return .malformed(
                type: String(token), raw: raw, reason: "unknown diagram type '\(token)'")
        }
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

    /// Body lines after the header, skipping blank lines and `%%` comments.
    private func bodyLines(_ raw: String) -> [String] {
        let lines = raw.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let index = headerIndex(lines) else { return [] }
        guard index + 1 < lines.count else { return [] }
        return lines[(index + 1)...].filter { !$0.isEmpty && !$0.hasPrefix("%%") }
    }

    /// Longest-match-first sequence-diagram arrow tokens; `-->>`/`->>` must precede the
    /// two-dash/one-dash prefixes they would otherwise be mistaken for.
    private static let sequenceArrowTable: [(token: String, arrow: MermaidSequence.Arrow)] = [
        ("-->>", .dottedArrow),
        ("->>", .solidArrow),
        ("-->", .dotted),
        ("->", .solid),
    ]

    /// Finds the leftmost sequence-diagram arrow token (and its range) in `text`, so a
    /// trailing `+`/`-` activation marker is always resolved from the text after the arrow.
    private func firstSequenceArrow(in text: String) -> (
        arrow: MermaidSequence.Arrow, range: Range<String.Index>
    )? {
        let chars = Array(text)
        for index in 0..<chars.count {
            for candidate in Self.sequenceArrowTable
            where matchesToken(candidate.token, in: chars, at: index) {
                let start = text.index(text.startIndex, offsetBy: index)
                let end = text.index(start, offsetBy: candidate.token.count)
                return (candidate.arrow, start..<end)
            }
        }
        return nil
    }

    /// Parses a `Note over A,B: text` / `Note left of A: text` / `Note right of A: text` line.
    private func parseSequenceNote(_ line: String) -> MermaidSequence.Note? {
        guard line.lowercased().hasPrefix("note ") else { return nil }
        let rest = String(line.dropFirst("note ".count))
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let head = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let headLower = head.lowercased()
        if headLower.hasPrefix("over ") {
            let names =
                head.dropFirst("over ".count)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !names.isEmpty else { return nil }
            return MermaidSequence.Note(placement: .over(names), text: text)
        }
        if headLower.hasPrefix("left of ") {
            let name = head.dropFirst("left of ".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return MermaidSequence.Note(placement: .leftOf(name), text: text)
        }
        if headLower.hasPrefix("right of ") {
            let name = head.dropFirst("right of ".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return MermaidSequence.Note(placement: .rightOf(name), text: text)
        }
        return nil
    }

    private func parseSequence(_ raw: String) -> MermaidSequence {
        var participants: [String] = []
        var kinds: [String: MermaidSequence.ParticipantKind] = [:]
        var display: [String: String] = [:]
        var events: [MermaidSequence.Event] = []
        var blockStack: [UUID] = []

        func ensure(_ name: String, kind: MermaidSequence.ParticipantKind = .participant) {
            guard !name.isEmpty, !participants.contains(name) else { return }
            participants.append(name)
            kinds[name] = kind
            display[name] = name
        }

        for line in bodyLines(raw) {
            let first = String(line.prefix { !$0.isWhitespace }).lowercased()

            if first == "participant" || first == "actor" {
                let kind: MermaidSequence.ParticipantKind = first == "actor" ? .actor : .participant
                let rest = String(line.dropFirst(first.count)).trimmingCharacters(
                    in: .whitespaces)
                let idName: String
                let displayName: String
                if let range = rest.range(of: " as ") {
                    idName = String(rest[..<range.lowerBound]).trimmingCharacters(
                        in: .whitespaces)
                    displayName = String(rest[range.upperBound...]).trimmingCharacters(
                        in: .whitespaces)
                } else {
                    idName = rest
                    displayName = rest
                }
                guard !idName.isEmpty else { continue }
                ensure(idName, kind: kind)
                kinds[idName] = kind
                display[idName] = displayName.isEmpty ? idName : displayName
                continue
            }

            if first == "alt" || first == "opt" || first == "loop" || first == "par" {
                let blockKind: MermaidSequence.BlockKind
                switch first {
                case "alt": blockKind = .alt
                case "opt": blockKind = .opt
                case "loop": blockKind = .loop
                default: blockKind = .par
                }
                let title = String(line.dropFirst(first.count)).trimmingCharacters(
                    in: .whitespaces)
                let block = MermaidSequence.Block(kind: blockKind, title: title)
                events.append(.blockStart(block))
                blockStack.append(block.id)
                continue
            }

            if first == "else" || first == "and" {
                if let top = blockStack.last {
                    let label = String(line.dropFirst(first.count)).trimmingCharacters(
                        in: .whitespaces)
                    events.append(.blockDivider(blockID: top, label: label))
                }
                continue
            }

            if line == "end" {
                if let id = blockStack.popLast() {
                    events.append(.blockEnd(blockID: id))
                }
                continue
            }

            if first == "note" {
                if let note = parseSequenceNote(line) {
                    switch note.placement {
                    case .over(let names): for name in names { ensure(name) }
                    case .leftOf(let name): ensure(name)
                    case .rightOf(let name): ensure(name)
                    }
                    events.append(.note(note))
                }
                continue
            }

            if first == "activate" {
                let name = String(line.dropFirst(first.count)).trimmingCharacters(
                    in: .whitespaces)
                guard !name.isEmpty else { continue }
                ensure(name)
                events.append(.activate(name))
                continue
            }

            if first == "deactivate" {
                let name = String(line.dropFirst(first.count)).trimmingCharacters(
                    in: .whitespaces)
                guard !name.isEmpty else { continue }
                ensure(name)
                events.append(.deactivate(name))
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let routePart = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = String(line[line.index(after: colon)...]).trimmingCharacters(
                in: .whitespaces)
            guard let (arrow, range) = firstSequenceArrow(in: routePart) else { continue }

            let from = String(routePart[..<range.lowerBound]).trimmingCharacters(
                in: .whitespaces)
            var targetSide = String(routePart[range.upperBound...]).trimmingCharacters(
                in: .whitespaces)
            var activates = false
            var deactivates = false
            if targetSide.hasPrefix("+") {
                activates = true
                targetSide.removeFirst()
            } else if targetSide.hasPrefix("-") {
                deactivates = true
                targetSide.removeFirst()
            }
            let to = targetSide.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { continue }
            ensure(from)
            ensure(to)
            let message = MermaidSequence.Message(
                from: from, to: to, label: label, arrow: arrow, activatesTarget: activates,
                deactivatesSource: deactivates)
            events.append(.message(message))
            if activates { events.append(.activate(to)) }
            if deactivates { events.append(.deactivate(from)) }
        }

        while let id = blockStack.popLast() {
            events.append(.blockEnd(blockID: id))
        }

        let messages: [MermaidSequence.Message] = events.compactMap {
            if case .message(let message) = $0 { return message }
            return nil
        }

        return MermaidSequence(
            raw: raw, participants: participants, participantKinds: kinds,
            participantDisplay: display, messages: messages, events: events)
    }

    // MARK: - Flow parsing

    /// Depth-0-matched edge connector metadata (line style + start/end arrowheads).
    private struct Connector {
        let line: MermaidFlow.EdgeLine
        let startHead: MermaidFlow.EdgeHead
        let endHead: MermaidFlow.EdgeHead
    }

    /// Longest-match-first connector table. Order matters: any token that is a prefix of a
    /// longer token (e.g. "-.-" is a prefix of "-.->") must appear after that longer token.
    private static let connectorTable: [(token: String, connector: Connector)] = [
        ("<-->", Connector(line: .solid, startHead: .arrow, endHead: .arrow)),
        ("-.->", Connector(line: .dotted, startHead: .none, endHead: .arrow)),
        ("-->", Connector(line: .solid, startHead: .none, endHead: .arrow)),
        ("--o", Connector(line: .solid, startHead: .none, endHead: .circle)),
        ("--x", Connector(line: .solid, startHead: .none, endHead: .cross)),
        ("-.-", Connector(line: .dotted, startHead: .none, endHead: .none)),
        ("==>", Connector(line: .thick, startHead: .none, endHead: .arrow)),
        ("---", Connector(line: .solid, startHead: .none, endHead: .none)),
        ("===", Connector(line: .thick, startHead: .none, endHead: .none)),
    ]

    private func matchesToken(_ token: String, in chars: [Character], at index: Int) -> Bool {
        let tokenChars = Array(token)
        guard index + tokenChars.count <= chars.count else { return false }
        for offset in 0..<tokenChars.count where chars[index + offset] != tokenChars[offset] {
            return false
        }
        return true
    }

    /// Splits a flow-diagram statement line into chunks separated by depth-0, out-of-quote
    /// edge connectors, so that connector-like text inside `[...]`/`(...)`/`{...}` node labels
    /// or quoted strings is never mistaken for a real edge.
    private func tokenizeEdgeLine(_ line: String) -> (chunks: [String], connectors: [Connector]) {
        var chunks: [String] = []
        var connectors: [Connector] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                i += 1
                continue
            }
            if !inQuotes {
                if "[({".contains(ch) {
                    depth += 1
                } else if "])}".contains(ch) {
                    depth = max(0, depth - 1)
                }
            }
            if depth == 0 && !inQuotes {
                if let match = Self.connectorTable.first(where: {
                    matchesToken($0.token, in: chars, at: i)
                }) {
                    chunks.append(current)
                    connectors.append(match.connector)
                    current = ""
                    i += match.token.count
                    continue
                }
            }
            current.append(ch)
            i += 1
        }
        chunks.append(current)
        return (chunks, connectors)
    }

    /// Splits `text` on `separator` at bracket depth 0 and outside quotes.
    private func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if !inQuotes {
                if "[({".contains(ch) {
                    depth += 1
                } else if "])}".contains(ch) {
                    depth = max(0, depth - 1)
                }
            }
            if ch == separator && depth == 0 && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Expands an `&`-joined node group (e.g. `A & B`) into individual nodes.
    private func parseNodeGroup(_ text: String) -> [MermaidFlow.Node] {
        splitTopLevel(text, on: "&").map { node(from: $0) }
    }

    /// If `chunk` begins (depth-0) with `|label|`, returns the remainder and the label text.
    private func stripLeadingPipeLabel(_ chunk: String) -> (remainder: String, label: String?) {
        let trimmed = chunk.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return (chunk, nil) }
        let withoutFirst = trimmed.dropFirst()
        guard let closeIndex = withoutFirst.firstIndex(of: "|") else { return (chunk, nil) }
        let label = String(withoutFirst[..<closeIndex])
        let remainder = String(withoutFirst[withoutFirst.index(after: closeIndex)...])
        return (remainder, label)
    }

    /// Solid-line-only inline mid-label: `A -- label` (before a trailing connector was
    /// already stripped by `tokenizeEdgeLine`). Dotted/thick inline mid-labels are not
    /// supported in M2.
    private func stripInlineTrailingLabel(_ chunk: String) -> (node: String, label: String?) {
        let marker = " -- "
        let chars = Array(chunk)
        var depth = 0
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                inQuotes.toggle()
                i += 1
                continue
            }
            if !inQuotes {
                if "[({".contains(ch) {
                    depth += 1
                } else if "])}".contains(ch) {
                    depth = max(0, depth - 1)
                }
            }
            if depth == 0 && !inQuotes && matchesToken(marker, in: chars, at: i) {
                let node = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                let label = String(chars[(i + marker.count)...]).trimmingCharacters(
                    in: .whitespaces)
                return (node, label)
            }
            i += 1
        }
        return (chunk, nil)
    }

    private func parseDirection(_ header: String) -> MermaidFlow.Direction {
        let tokens = header.split { $0.isWhitespace }
        guard tokens.count > 1 else { return .topToBottom }
        var token = String(tokens[1])
        if token.hasSuffix(";") { token.removeLast() }
        switch token {
        case "LR": return .leftToRight
        case "RL": return .rightToLeft
        case "BT": return .bottomToTop
        case "TB", "TD": return .topToBottom
        default: return .topToBottom
        }
    }

    private func parseSubgraphHeader(_ line: String) -> (name: String, title: String) {
        let rest = String(line.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return ("subgraph", "subgraph") }
        if let openBracket = rest.firstIndex(of: "["), rest.hasSuffix("]") {
            let name = String(rest[..<openBracket]).trimmingCharacters(in: .whitespaces)
            let titleRaw = String(
                rest[rest.index(after: openBracket)..<rest.index(before: rest.endIndex)]
            ).trimmingCharacters(in: .whitespaces)
            let resolvedName = name.isEmpty ? titleRaw : name
            let resolvedTitle = titleRaw.isEmpty ? resolvedName : titleRaw
            return (resolvedName, resolvedTitle)
        }
        return (rest, rest)
    }

    /// Mutable accumulator for a `subgraph`/`end` block while its body is being parsed.
    /// Kept as a class so nested scopes on the parse stack can be mutated in place.
    private final class SubgraphBuilder {
        let name: String
        var title: String
        var nodeIDs: [String] = []
        var children: [MermaidFlow.Subgraph] = []

        init(name: String, title: String) {
            self.name = name
            self.title = title
        }

        func addNode(_ id: String) {
            if !nodeIDs.contains(id) { nodeIDs.append(id) }
        }

        func build() -> MermaidFlow.Subgraph {
            MermaidFlow.Subgraph(name: name, title: title, nodeIDs: nodeIDs, children: children)
        }
    }

    private func parseFlow(_ raw: String) -> MermaidFlow {
        let header = firstHeaderLine(raw) ?? ""
        let direction = parseDirection(header)
        let body = bodyLines(raw)

        var nodesByID: [String: MermaidFlow.Node] = [:]
        var edges: [MermaidFlow.Edge] = []
        var stack: [SubgraphBuilder] = []
        var roots: [MermaidFlow.Subgraph] = []

        func register(_ candidate: MermaidFlow.Node) {
            if var existing = nodesByID[candidate.id] {
                let existingIsPlain = existing.shape == .rectangle && existing.label == existing.id
                let candidateIsRicher =
                    candidate.shape != .rectangle || candidate.label != candidate.id
                if existingIsPlain && candidateIsRicher {
                    existing.label = candidate.label
                    existing.shape = candidate.shape
                    nodesByID[candidate.id] = existing
                }
            } else {
                nodesByID[candidate.id] = candidate
            }
            stack.last?.addNode(candidate.id)
        }

        func attach(_ subgraph: MermaidFlow.Subgraph) {
            if let parent = stack.last {
                parent.children.append(subgraph)
            } else {
                roots.append(subgraph)
            }
        }

        for line in body {
            if line.hasPrefix("subgraph") {
                let (name, title) = parseSubgraphHeader(line)
                stack.append(SubgraphBuilder(name: name, title: title))
                continue
            }
            if line == "end" {
                guard let finished = stack.popLast() else { continue }
                attach(finished.build())
                continue
            }
            if line.hasPrefix("direction ") || line == "direction" {
                // Per-subgraph direction overrides are not modeled in M2.
                continue
            }

            let (chunks, connectors) = tokenizeEdgeLine(line)
            if connectors.isEmpty {
                for n in parseNodeGroup(chunks[0]) { register(n) }
                continue
            }

            var reusableChunks = chunks
            for i in 0..<connectors.count {
                let connector = connectors[i]
                let (leftGroup, midLabel): (String, String?) =
                    connector.line == .solid
                    ? stripInlineTrailingLabel(reusableChunks[i])
                    : (reusableChunks[i], nil)
                let (rightGroup, pipeLabel) = stripLeadingPipeLabel(reusableChunks[i + 1])
                reusableChunks[i + 1] = rightGroup

                let label = pipeLabel ?? midLabel ?? ""
                let lefts = parseNodeGroup(leftGroup)
                let rights = parseNodeGroup(rightGroup)
                for l in lefts {
                    for r in rights {
                        register(l)
                        register(r)
                        edges.append(
                            MermaidFlow.Edge(
                                from: l.id, to: r.id, label: label,
                                line: connector.line, startHead: connector.startHead,
                                endHead: connector.endHead))
                    }
                }
            }
        }

        while let finished = stack.popLast() {
            attach(finished.build())
        }

        let nodes = nodesByID.mapValues(\.label)
        return MermaidFlow(
            raw: raw, direction: direction, nodesByID: nodesByID, nodes: nodes, edges: edges,
            subgraphs: roots)
    }

    /// Parses a node reference (with optional shape delimiters) into an id/label/shape triple.
    /// Double/compound delimiters (`((`, `[[`, `[/`) are checked before their single-character
    /// prefixes so `((` is never mistaken for `(`.
    private func node(from raw: String) -> MermaidFlow.Node {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "|- "))
        guard let openIndex = cleaned.firstIndex(where: { "[({>".contains($0) }) else {
            return MermaidFlow.Node(id: cleaned, label: cleaned, shape: .rectangle)
        }
        let id = String(cleaned[..<openIndex]).trimmingCharacters(in: .whitespaces)
        let remainder = cleaned[openIndex...]
        let shapeMarkers: [(open: String, shape: MermaidFlow.NodeShape)] = [
            ("((", .circle),
            ("[[", .subroutine),
            ("[/", .parallelogram),
            ("[", .rectangle),
            ("{", .diamond),
            ("(", .round),
            (">", .flag),
        ]
        for marker in shapeMarkers where remainder.hasPrefix(marker.open) {
            let inner = remainder.dropFirst(marker.open.count)
            let label = String(inner).trimmingCharacters(in: CharacterSet(charactersIn: "])}\"/"))
            return MermaidFlow.Node(id: id, label: label, shape: marker.shape)
        }
        return MermaidFlow.Node(id: cleaned, label: cleaned, shape: .rectangle)
    }
}
