import Foundation

nonisolated struct MarkdownBlock: Identifiable, Sendable {
    enum Content: Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case quote(String)
        case code(language: String?, text: String)
        case mermaid(MermaidDiagram)
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
    static func mermaid(_ diagram: MermaidDiagram) -> Self { Self(.mermaid(diagram)) }
    static var divider: Self { Self(.divider) }
}

nonisolated struct MermaidDiagram: Sendable {
    enum Kind: Equatable, Sendable { case flow, sequence }
    struct Edge: Sendable {
        let id: UUID = UUID()
        let from: String
        let to: String
        let label: String
    }
    struct Message: Sendable {
        let id: UUID = UUID()
        let from: String
        let to: String
        let label: String
    }

    let raw: String
    let kind: Kind
    let nodes: [String: String]
    let edges: [Edge]
    let participants: [String]
    let messages: [Message]
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

    func parseMermaid(_ raw: String) -> MermaidDiagram {
        let lines = raw.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if lines.first?.lowercased().hasPrefix("sequenceDiagram".lowercased()) == true {
            var participants: [String] = []
            var messages: [MermaidDiagram.Message] = []
            for line in lines.dropFirst() {
                if line.hasPrefix("participant ") {
                    let name =
                        String(line.dropFirst("participant ".count)).components(separatedBy: " as ")
                        .last ?? ""
                    if !name.isEmpty { participants.append(name) }
                } else if let arrow = ["->>", "-->>", "->", "-->"].first(where: line.contains),
                    let colon = line.firstIndex(of: ":")
                {
                    let route = String(line[..<colon]).components(separatedBy: arrow)
                    if route.count == 2 {
                        let from = route[0].trimmingCharacters(in: .whitespaces)
                        let to = route[1].trimmingCharacters(in: .whitespaces)
                        if !participants.contains(from) { participants.append(from) }
                        if !participants.contains(to) { participants.append(to) }
                        messages.append(
                            .init(
                                from: from, to: to,
                                label: String(line[line.index(after: colon)...]).trimmingCharacters(
                                    in: .whitespaces)))
                    }
                }
            }
            return MermaidDiagram(
                raw: raw, kind: .sequence, nodes: [:], edges: [], participants: participants,
                messages: messages)
        }

        var nodes: [String: String] = [:]
        var edges: [MermaidDiagram.Edge] = []
        for line in lines.dropFirst() {
            guard let (arrowRange, arrow) = flowArrow(in: line) else { continue }
            var left = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            var right = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label = ""
            if right.hasPrefix("|"), let closingPipe = right.dropFirst().firstIndex(of: "|") {
                label = String(right[right.index(after: right.startIndex)..<closingPipe])
                right = String(right[right.index(after: closingPipe)...]).trimmingCharacters(
                    in: .whitespaces)
            } else if arrow == "-->", let labelRange = left.range(of: " -- ") {
                label = String(left[labelRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                left = String(left[..<labelRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let from = node(from: left)
            let to = node(from: right)
            nodes[from.id] = from.label
            nodes[to.id] = to.label
            edges.append(.init(from: from.id, to: to.id, label: label))
        }
        return MermaidDiagram(
            raw: raw, kind: .flow, nodes: nodes, edges: edges, participants: [], messages: [])
    }

    private func flowArrow(in line: String) -> (Range<String.Index>, String)? {
        for arrow in ["-.->", "==>", "-->", "---"] {
            if let range = line.range(of: arrow) { return (range, arrow) }
        }
        return nil
    }

    private func node(from raw: String) -> (id: String, label: String) {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "|- "))
        if let open = cleaned.firstIndex(where: { $0 == "[" || $0 == "(" || $0 == "{" }) {
            let id = String(cleaned[..<open])
            let label = String(cleaned[cleaned.index(after: open)...]).trimmingCharacters(
                in: CharacterSet(charactersIn: "])}\""))
            return (id, label)
        }
        return (cleaned, cleaned)
    }
}
