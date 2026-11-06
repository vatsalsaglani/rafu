import Foundation

/// One prop on an MDX component tag (ADR 0034). Values are parsed, never
/// evaluated: a `{expression}` that is not JSON stays `.expression(raw)`.
nonisolated struct MDXProp: Sendable, Equatable {
    let name: String
    let value: MDXPropValue
}

nonisolated enum MDXPropValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    /// `{[…]}` or `{{…}}` whose inner text parses as JSON.
    case json(MDXJSONValue)
    /// Any other `{…}` text, kept literally. Rafu runs no JavaScript.
    case expression(String)

    /// The value as display text, used for titles, tones, and the fallback
    /// block's prop line.
    var text: String {
        switch self {
        case .string(let value): value
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15
                ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .json(let value): value.compactText
        case .expression(let raw): "{\(raw)}"
        }
    }
}

/// A JSON value from a prop. Plain data only.
nonisolated indirect enum MDXJSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([MDXJSONValue])
    case object([String: MDXJSONValue])

    init?(any value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case is NSNull: self = .null
        case let value as [Any]:
            var items: [MDXJSONValue] = []
            for item in value {
                guard let converted = MDXJSONValue(any: item) else { return nil }
                items.append(converted)
            }
            self = .array(items)
        case let value as [String: Any]:
            var fields: [String: MDXJSONValue] = [:]
            for (key, item) in value {
                guard let converted = MDXJSONValue(any: item) else { return nil }
                fields[key] = converted
            }
            self = .object(fields)
        default: return nil
        }
    }

    var compactText: String {
        switch self {
        case .string(let value): "\"\(value)\""
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15
                ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .array(let items): "[" + items.map(\.compactText).joined(separator: ", ") + "]"
        case .object(let fields):
            "{"
                + fields.keys.sorted().map { "\($0): \(fields[$0]!.compactText)" }
                .joined(separator: ", ") + "}"
        }
    }
}

/// A top-level component block and its children, as written in the source.
nonisolated struct MDXComponentNode: Sendable, Equatable {
    let name: String
    let props: [MDXProp]
    let children: [MDXContent]
    let isSelfClosing: Bool

    func prop(_ name: String) -> MDXPropValue? {
        props.first { $0.name == name }?.value
    }
}

nonisolated enum MDXContent: Sendable, Equatable {
    case markdown(String)
    case component(MDXComponentNode)
}

/// Splits `.mdx` source into Markdown and component blocks (ADR 0034).
///
/// The grammar is deliberately small:
/// - top-level `import`/`export` lines are dropped;
/// - a component block starts on a line that begins with `<Name` (an upper
///   case first letter) and ends at the matching `</Name>` (same-name depth
///   is counted) or at `/>`;
/// - text inside fenced code (``` or ~~~) is never scanned for tags;
/// - children are scanned again, so components nest;
/// - an unterminated or malformed tag stays as literal Markdown text.
///
/// `{expressions}` are never evaluated. A component inside a list item or a
/// block quote is not at line start, so it stays as text.
nonisolated struct MDXBlockScanner: Sendable {
    /// Deeper nesting stays as literal Markdown in the deepest node.
    static let maxDepth = 8
    /// An opening tag longer than this is treated as text.
    static let maxTagLength = 16 * 1024

    func scan(_ source: String) -> [MDXContent] {
        let scalars = Array(source.unicodeScalars)
        return scan(scalars, range: 0..<scalars.count, depth: 0)
    }

    // MARK: - Block level

    private func scan(_ s: [Unicode.Scalar], range: Range<Int>, depth: Int) -> [MDXContent] {
        var result: [MDXContent] = []
        var markdown = String.UnicodeScalarView()
        var fence: Fence?
        var i = range.lowerBound
        let end = range.upperBound

        func flush() {
            let text = String(markdown)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(text))
            }
            markdown = String.UnicodeScalarView()
        }

        while i < end {
            let lineEnd = Self.lineEnd(s, from: i, limit: end)
            let next = min(lineEnd + 1, end)

            if let open = fence {
                markdown.append(contentsOf: s[i..<next])
                if Self.closesFence(s, i..<lineEnd, open) { fence = nil }
                i = next
                continue
            }
            if let opened = Self.opensFence(s, i..<lineEnd) {
                fence = opened
                markdown.append(contentsOf: s[i..<next])
                i = next
                continue
            }
            if depth == 0, Self.isModuleLine(s, i..<lineEnd) {
                i = Self.skipModuleStatement(s, from: i, limit: end)
                continue
            }
            if depth < Self.maxDepth, Self.startsComponent(s, at: i, limit: lineEnd),
                let parsed = parseComponent(s, at: i, limit: end, depth: depth)
            {
                let (node, after) = parsed
                flush()
                result.append(.component(node))
                let restEnd = Self.lineEnd(s, from: after, limit: end)
                if !Self.isBlank(s, after..<restEnd) {
                    markdown.append(contentsOf: s[after..<restEnd])
                    markdown.append("\n")
                }
                i = min(restEnd + 1, end)
                continue
            }
            markdown.append(contentsOf: s[i..<next])
            i = next
        }
        flush()
        return result
    }

    /// Parses `<Name …>children</Name>` or `<Name … />` starting at `start`.
    /// Returns the node and the index just after the block, or nil.
    private func parseComponent(
        _ s: [Unicode.Scalar], at start: Int, limit: Int, depth: Int
    ) -> (MDXComponentNode, Int)? {
        guard let tag = Self.parseOpenTag(s, at: start, limit: limit) else { return nil }
        if tag.isSelfClosing {
            let node = MDXComponentNode(
                name: tag.name, props: tag.props, children: [], isSelfClosing: true)
            return (node, tag.end)
        }
        guard let close = Self.findClose(s, name: tag.name, from: tag.end, limit: limit) else {
            return nil
        }
        var childStart = tag.end
        var childEnd = close.start
        // Drop the line break after `>` and the whitespace before `</Name>`.
        while childStart < childEnd, s[childStart] == " " || s[childStart] == "\t" {
            childStart += 1
        }
        if childStart < childEnd, s[childStart] == "\n" { childStart += 1 }
        while childEnd > childStart, Self.isWhitespace(s[childEnd - 1]) { childEnd -= 1 }
        let children = scan(s, range: childStart..<childEnd, depth: depth + 1)
        let node = MDXComponentNode(
            name: tag.name, props: tag.props, children: children, isSelfClosing: false)
        return (node, close.end)
    }

    // MARK: - Tags

    struct OpenTag {
        let name: String
        let props: [MDXProp]
        let isSelfClosing: Bool
        /// Index just after `>` or `/>`.
        let end: Int
    }

    static func startsComponent(_ s: [Unicode.Scalar], at i: Int, limit: Int) -> Bool {
        i + 1 < limit && s[i] == "<" && isUpper(s[i + 1])
    }

    static func parseOpenTag(_ s: [Unicode.Scalar], at start: Int, limit: Int) -> OpenTag? {
        let cap = min(limit, start + maxTagLength)
        guard start + 1 < cap, s[start] == "<", isUpper(s[start + 1]) else { return nil }
        var i = start + 1
        var name = String.UnicodeScalarView()
        while i < cap, isNameScalar(s[i]) || s[i] == "." {
            name.append(s[i])
            i += 1
        }
        guard i < cap, isWhitespace(s[i]) || s[i] == ">" || s[i] == "/" else { return nil }

        var props: [MDXProp] = []
        while i < cap {
            while i < cap, isWhitespace(s[i]) { i += 1 }
            guard i < cap else { return nil }
            if s[i] == ">" {
                return OpenTag(name: String(name), props: props, isSelfClosing: false, end: i + 1)
            }
            if s[i] == "/" {
                guard i + 1 < cap, s[i + 1] == ">" else { return nil }
                return OpenTag(name: String(name), props: props, isSelfClosing: true, end: i + 2)
            }
            guard isNameScalar(s[i]) else { return nil }
            var propName = String.UnicodeScalarView()
            while i < cap, isNameScalar(s[i]) || s[i] == "-" || s[i] == ":" {
                propName.append(s[i])
                i += 1
            }
            var j = i
            while j < cap, isWhitespace(s[j]) { j += 1 }
            guard j < cap, s[j] == "=" else {
                props.append(MDXProp(name: String(propName), value: .bool(true)))
                continue
            }
            j += 1
            while j < cap, isWhitespace(s[j]) { j += 1 }
            guard j < cap else { return nil }
            if s[j] == "\"" || s[j] == "'" {
                let quote = s[j]
                var k = j + 1
                while k < cap, s[k] != quote { k += 1 }
                guard k < cap else { return nil }
                let text = String(String.UnicodeScalarView(s[(j + 1)..<k]))
                props.append(MDXProp(name: String(propName), value: .string(text)))
                i = k + 1
            } else if s[j] == "{" {
                guard let close = matchingBrace(s, open: j, limit: cap) else { return nil }
                let raw = String(String.UnicodeScalarView(s[(j + 1)..<close]))
                props.append(MDXProp(name: String(propName), value: expressionValue(raw)))
                i = close + 1
            } else {
                return nil
            }
        }
        return nil
    }

    /// Interprets the text inside `{…}` without evaluating it.
    static func expressionValue(_ raw: String) -> MDXPropValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        if let first = trimmed.unicodeScalars.first,
            first == "-" || first == "." || (first >= "0" && first <= "9"),
            let number = Double(trimmed)
        {
            return .number(number)
        }
        if let first = trimmed.first, first == "\"" || first == "[" || first == "{",
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]),
            let value = MDXJSONValue(any: object)
        {
            if case .string(let text) = value { return .string(text) }
            return .json(value)
        }
        return .expression(trimmed)
    }

    /// Finds the `}` that closes the `{` at `open`, skipping quoted strings.
    private static func matchingBrace(_ s: [Unicode.Scalar], open: Int, limit: Int) -> Int? {
        var depth = 0
        var quote: Unicode.Scalar?
        var i = open
        while i < limit {
            let c = s[i]
            if let q = quote {
                if c == "\\" {
                    i += 2
                    continue
                }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Finds the `</name>` that closes a block opened just before `from`,
    /// counting nested same-name opens and skipping fenced code.
    private static func findClose(
        _ s: [Unicode.Scalar], name: String, from: Int, limit: Int
    ) -> (start: Int, end: Int)? {
        let nameScalars = Array(name.unicodeScalars)
        var depth = 1
        var fence: Fence?
        var i = from
        var atLineStart = false
        while i < limit {
            let lineEnd = lineEnd(s, from: i, limit: limit)
            if atLineStart {
                if let open = fence {
                    if closesFence(s, i..<lineEnd, open) { fence = nil }
                    i = lineEnd + 1
                    continue
                }
                if let opened = opensFence(s, i..<lineEnd) {
                    fence = opened
                    i = lineEnd + 1
                    continue
                }
            }
            var j = i
            var resumeAt: Int?
            while j < lineEnd {
                guard s[j] == "<" else {
                    j += 1
                    continue
                }
                if j + 1 < lineEnd, s[j + 1] == "/",
                    matches(s, at: j + 2, nameScalars, limit: lineEnd)
                {
                    var k = j + 2 + nameScalars.count
                    while k < lineEnd, s[k] == " " || s[k] == "\t" { k += 1 }
                    if k < lineEnd, s[k] == ">" {
                        depth -= 1
                        if depth == 0 { return (j, k + 1) }
                        j = k + 1
                        continue
                    }
                } else if matches(s, at: j + 1, nameScalars, limit: lineEnd),
                    let tag = parseOpenTag(s, at: j, limit: limit), tag.name == name
                {
                    if !tag.isSelfClosing { depth += 1 }
                    if tag.end > lineEnd {
                        resumeAt = tag.end
                        break
                    }
                    j = tag.end
                    continue
                }
                j += 1
            }
            if let resumeAt {
                i = resumeAt
                atLineStart = false
            } else {
                i = lineEnd + 1
                atLineStart = true
            }
        }
        return nil
    }

    private static func matches(
        _ s: [Unicode.Scalar], at i: Int, _ name: [Unicode.Scalar], limit: Int
    ) -> Bool {
        guard i + name.count <= limit else { return false }
        for (offset, scalar) in name.enumerated() where s[i + offset] != scalar { return false }
        let after = i + name.count
        return after >= limit || !(isNameScalar(s[after]) || s[after] == ".")
    }

    // MARK: - Lines

    struct Fence {
        let marker: Unicode.Scalar
        let count: Int
    }

    static func lineEnd(_ s: [Unicode.Scalar], from i: Int, limit: Int) -> Int {
        var j = i
        while j < limit, s[j] != "\n" { j += 1 }
        return j
    }

    /// A fence opener: up to three spaces, then three or more ` or ~.
    static func opensFence(_ s: [Unicode.Scalar], _ line: Range<Int>) -> Fence? {
        var i = line.lowerBound
        var indent = 0
        while i < line.upperBound, s[i] == " ", indent < 4 {
            i += 1
            indent += 1
        }
        guard indent < 4, i < line.upperBound, s[i] == "`" || s[i] == "~" else { return nil }
        let marker = s[i]
        var count = 0
        while i < line.upperBound, s[i] == marker {
            count += 1
            i += 1
        }
        guard count >= 3 else { return nil }
        if marker == "`", s[i..<line.upperBound].contains("`") { return nil }
        return Fence(marker: marker, count: count)
    }

    static func closesFence(_ s: [Unicode.Scalar], _ line: Range<Int>, _ fence: Fence) -> Bool {
        var i = line.lowerBound
        var indent = 0
        while i < line.upperBound, s[i] == " ", indent < 4 {
            i += 1
            indent += 1
        }
        guard indent < 4 else { return false }
        var count = 0
        while i < line.upperBound, s[i] == fence.marker {
            count += 1
            i += 1
        }
        return count >= fence.count && isBlank(s, i..<line.upperBound)
    }

    /// An ESM line as MDX defines it. Prose that starts with the word
    /// "import" or "export" does not match, so it stays visible.
    static func isModuleLine(_ s: [Unicode.Scalar], _ line: Range<Int>) -> Bool {
        guard line.count >= 7, s[line.lowerBound] == "i" || s[line.lowerBound] == "e" else {
            return false
        }
        let text = String(String.UnicodeScalarView(s[line]))
        let range = NSRange(text.startIndex..., in: text)
        return moduleLinePattern?.firstMatch(in: text, range: range) != nil
    }

    private static let moduleLinePattern = try? NSRegularExpression(
        pattern:
            #"^(import\s*(\{|\*|["']|[A-Za-z_$][\w$]*\s*(,|from\b))|export\s+(\{|\*|default\b|const\b|let\b|var\b|function\b|async\b|class\b))"#
    )

    /// Skips one `import`/`export` statement. A statement with an unclosed
    /// `{` continues to the line that closes it, so multi-line imports go
    /// too. Returns the index after the statement.
    static func skipModuleStatement(_ s: [Unicode.Scalar], from start: Int, limit: Int) -> Int {
        var depth = 0
        var i = start
        var lines = 0
        while i < limit {
            let lineEnd = lineEnd(s, from: i, limit: limit)
            for c in s[i..<lineEnd] {
                if c == "{" || c == "(" || c == "[" { depth += 1 }
                if c == "}" || c == ")" || c == "]" { depth -= 1 }
            }
            i = min(lineEnd + 1, limit)
            lines += 1
            if depth <= 0 || lines >= 200 { break }
        }
        return i
    }

    static func isBlank(_ s: [Unicode.Scalar], _ range: Range<Int>) -> Bool {
        guard range.lowerBound < range.upperBound else { return true }
        return s[range].allSatisfy(isWhitespace)
    }

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    static func isUpper(_ c: Unicode.Scalar) -> Bool { c >= "A" && c <= "Z" }

    static func isNameScalar(_ c: Unicode.Scalar) -> Bool {
        (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_"
    }
}
