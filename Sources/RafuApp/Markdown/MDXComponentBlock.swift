import Foundation
import JSONRenderCore
import os

/// Inputs the segment parser needs to resolve MDX components (ADR 0034).
nonisolated struct MDXParseContext: Sendable {
    var registry: MDXComponentRegistry = .builtIn
    /// The document's directory. `Svg src` resolves against it.
    var baseURL: URL?
}

/// A component resolved to a native renderer, with all derived data
/// computed off the main actor so the view only lays it out.
nonisolated struct MDXBlock: Sendable, Identifiable {
    let id: Int
    let name: String
    /// `title` prop, when present.
    let title: String?
    /// Every prop as `name="value"`, joined for the fallback block.
    let propsLine: String
    let body: Body
    let children: [MDXBlockChild]
    /// The json-render spec for this block and everything inside it, built
    /// off the main actor with the block (`MDXCatalogBridge`). Set only on a
    /// block that is drawn by itself: a top-level block, or a block inside an
    /// unbridged fallback. Nil for a nested block (its parent's spec holds it),
    /// for a fallback block, and for a block whose spec failed validation.
    var catalogSpec: Spec?

    enum Body: Sendable {
        case callout(MDXCalloutTone)
        case card(status: String?)
        case checklist(done: Int, total: Int)
        /// Empty when the children are not a plain question list; the view
        /// then shows the children as Markdown.
        case questions([MDXQuestion])
        /// Empty when the children are not a plain list.
        case fileTree([MDXFileTreeEntry])
        case svg(MDXImageSource, caption: String?)
        /// A single figure: label, value, and optional change (`<Stat>`).
        case stat(MDXStatProps)
        /// `<Matrix>` / `<Compare>`: the first GFM table in the children, or
        /// nil when there is none (the view then shows the children).
        case matrix(MDXTable?)
        /// No renderer: a labelled block that still shows the children.
        case fallback
    }
}

/// The props of a `<Stat>` component, as display text.
nonisolated struct MDXStatProps: Sendable, Equatable {
    let label: String
    let value: String
    let delta: String?
    let unit: String?
    /// `neutral`, `good`, `warning`, or `critical`; nil when absent or unknown.
    let intent: String?
}

/// A GFM pipe table lifted out of a component's Markdown children.
nonisolated struct MDXTable: Sendable, Equatable {
    let columns: [String]
    let rows: [[String]]
}

nonisolated struct MDXBlockChild: Sendable, Identifiable {
    enum Content: Sendable {
        case markdown(String)
        case mermaid(MermaidParseResult)
        case component(MDXBlock)
    }

    let id: Int
    let content: Content
}

nonisolated enum MDXCalloutTone: String, Sendable, Equatable {
    case note, tip, info, warning, risk, decision

    init(typeName: String?) {
        switch typeName?.lowercased() {
        case "tip", "success": self = .tip
        case "info": self = .info
        case "warning", "warn", "caution": self = .warning
        case "risk", "danger", "error", "important": self = .risk
        case "decision": self = .decision
        default: self = .note
        }
    }

    var label: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .info: "Info"
        case .warning: "Warning"
        case .risk: "Risk"
        case .decision: "Decision"
        }
    }

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .tip: "lightbulb"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .risk: "exclamationmark.octagon"
        case .decision: "checkmark.seal"
        }
    }
}

nonisolated struct MDXQuestion: Sendable, Equatable, Identifiable {
    let id: Int
    let text: String
    let options: [String]
}

nonisolated struct MDXFileTreeEntry: Sendable, Equatable, Identifiable {
    let id: Int
    let depth: Int
    /// `add`, `modify`, `delete`, `rename`, `move`, or nil.
    let action: String?
    let path: String
    let note: String?
}

nonisolated enum MDXImageSource: Sendable, Equatable {
    case local(URL)
    /// Rafu never fetches a remote `Svg src`.
    case remote(String)
    case missing
}

/// Turns scanner nodes into `MDXBlock`s.
nonisolated struct MDXBlockBuilder {
    let context: MDXParseContext
    private var nextID = 0

    init(context: MDXParseContext) {
        self.context = context
    }

    static let maxListEntries = 500

    private static let logger = Logger(
        subsystem: "dev.vatsalsaglani.rafu", category: "MDXCatalogBridge")

    /// Resolves one component and everything inside it, and builds the
    /// block's json-render spec. Blocking work: call it off the main actor.
    mutating func build(_ node: MDXComponentNode) -> MDXBlock {
        build(node, parentIsBridged: false)
    }

    private mutating func build(_ node: MDXComponentNode, parentIsBridged: Bool) -> MDXBlock {
        let id = takeID()
        let title = node.prop("title")?.text
        let renderer = context.registry.renderer(for: node.name)
        let children = buildChildren(node.children, parentIsBridged: renderer != nil)
        let body: MDXBlock.Body
        switch renderer {
        case .callout:
            body = .callout(MDXCalloutTone(typeName: node.prop("type")?.text))
        case .card:
            body = .card(status: node.prop("status")?.text)
        case .checklist:
            let counts = Self.checklistCounts(Self.markdownText(of: node.children))
            body = .checklist(done: counts.done, total: counts.total)
        case .questions:
            body = .questions(Self.questions(in: Self.plainMarkdown(of: node.children)))
        case .fileTree:
            body = .fileTree(Self.fileTree(in: Self.plainMarkdown(of: node.children)))
        case .svg:
            body = .svg(
                Self.imageSource(node.prop("src")?.text, baseURL: context.baseURL),
                caption: node.prop("caption")?.text)
        case .stat:
            body = .stat(Self.statProps(of: node))
        case .matrix:
            body = .matrix(MDXTableParser.firstTable(in: Self.markdownText(of: node.children)))
        case nil:
            body = .fallback
        }
        var block = MDXBlock(
            id: id, name: node.name, title: title,
            propsLine: node.props.map { "\($0.name)=\(Self.quoted($0.value))" }
                .joined(separator: "  "),
            body: body, children: children)
        if renderer != nil, !parentIsBridged {
            block.catalogSpec = Self.validatedSpec(for: block)
        }
        return block
    }

    /// The bridged spec, or nil (after one log line with the block id only)
    /// when it does not validate against `RafuCatalog.rafu`. A failure is a
    /// bridge bug that `MDXCatalogBridgeTests` catches; the view then draws
    /// the plain fallback block.
    private static func validatedSpec(for block: MDXBlock) -> Spec? {
        let spec = MDXCatalogBridge.spec(for: block)
        guard RafuCatalog.rafu.validate(spec).valid else {
            logger.error("An MDX component produced an invalid view spec. block=\(block.id)")
            return nil
        }
        return spec
    }

    private mutating func buildChildren(_ contents: [MDXContent], parentIsBridged: Bool)
        -> [MDXBlockChild]
    {
        var children: [MDXBlockChild] = []
        for content in contents {
            switch content {
            case .markdown(let text):
                for piece in MarkdownPreviewSegmentParser.splitMermaid(text) {
                    switch piece {
                    case .markdown(let markdown):
                        children.append(.init(id: takeID(), content: .markdown(markdown)))
                    case .mermaid(let result):
                        children.append(.init(id: takeID(), content: .mermaid(result)))
                    }
                }
            case .component(let node):
                let block = build(node, parentIsBridged: parentIsBridged)
                children.append(.init(id: takeID(), content: .component(block)))
            }
        }
        return children
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: - Derived data

    private static func quoted(_ value: MDXPropValue) -> String {
        if case .string(let text) = value { return "\"\(text)\"" }
        return value.text
    }

    /// All Markdown text in the children, nested components excluded.
    static func markdownText(of contents: [MDXContent]) -> String {
        contents.compactMap {
            if case .markdown(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// The children as text only when they hold no nested component.
    static func plainMarkdown(of contents: [MDXContent]) -> String? {
        var parts: [String] = []
        for content in contents {
            guard case .markdown(let text) = content else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    static let statIntents: Set<String> = ["neutral", "good", "warning", "critical"]

    /// `label` falls back to `title`, then the component name.
    static func statProps(of node: MDXComponentNode) -> MDXStatProps {
        let intent = node.prop("intent")?.text.lowercased()
        return MDXStatProps(
            label: node.prop("label")?.text ?? node.prop("title")?.text ?? node.name,
            value: node.prop("value")?.text ?? "",
            delta: node.prop("delta")?.text,
            unit: node.prop("unit")?.text,
            intent: intent.flatMap { statIntents.contains($0) ? $0 : nil })
    }

    static func checklistCounts(_ text: String) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+"
            else { continue }
            let rest = trimmed.dropFirst().drop { $0 == " " }
            if rest.hasPrefix("[ ]") {
                total += 1
            } else if rest.hasPrefix("[x]") || rest.hasPrefix("[X]") {
                total += 1
                done += 1
            }
        }
        return (done, total)
    }

    private struct ListLine {
        let indent: Int
        let text: String
    }

    /// Splits a plain Markdown list into (indent, item text). Nil when any
    /// non-blank line is not a list item.
    private static func listLines(_ text: String?) -> [ListLine]? {
        guard let text else { return nil }
        var lines: [ListLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let body = line.drop { $0 == " " }
            if body.isEmpty { continue }
            let indent = line.count - body.count
            if let first = body.first, first == "-" || first == "*" || first == "+",
                body.dropFirst().first == " "
            {
                lines.append(ListLine(indent: indent, text: String(body.dropFirst(2))))
            } else if let dot = body.firstIndex(of: "."),
                body[..<dot].allSatisfy(\.isNumber), !body[..<dot].isEmpty,
                body[body.index(after: dot)...].first == " "
            {
                lines.append(
                    ListLine(
                        indent: indent,
                        text: String(body[body.index(dot, offsetBy: 2)...])))
            } else {
                return nil
            }
            if lines.count > maxListEntries { return nil }
        }
        return lines
    }

    /// Top-level items are questions; deeper items are their options.
    static func questions(in text: String?) -> [MDXQuestion] {
        guard let lines = listLines(text), let base = lines.map(\.indent).min() else {
            return []
        }
        var questions: [(text: String, options: [String])] = []
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if line.indent <= base {
                questions.append((trimmed, []))
            } else if !questions.isEmpty {
                questions[questions.count - 1].options.append(trimmed)
            } else {
                return []
            }
        }
        return questions.enumerated().map {
            MDXQuestion(id: $0.offset, text: $0.element.text, options: $0.element.options)
        }
    }

    static let fileActions: Set<String> = [
        "add", "added", "new", "create", "modify", "modified", "edit", "update", "delete",
        "deleted", "remove", "rename", "move",
    ]

    /// `- add path/to/file -- note` lines, nested by indent.
    static func fileTree(in text: String?) -> [MDXFileTreeEntry] {
        guard let lines = listLines(text), let base = lines.map(\.indent).min() else {
            return []
        }
        return lines.enumerated().map { index, line in
            var rest = Substring(line.text.trimmingCharacters(in: .whitespaces))
            var note: String?
            for separator in [" -- ", " — "] {
                if let range = rest.range(of: separator) {
                    note = rest[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    rest = rest[..<range.lowerBound]
                    break
                }
            }
            var action: String?
            if let space = rest.firstIndex(of: " ") {
                let word = rest[..<space].lowercased()
                if fileActions.contains(word) {
                    action = word
                    rest = rest[rest.index(after: space)...]
                }
            }
            var path = rest.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("`"), path.hasSuffix("`"), path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            return MDXFileTreeEntry(
                id: index, depth: max(0, (line.indent - base) / 2), action: action,
                path: path, note: note)
        }
    }

    /// Local files only. A remote source is reported, never fetched.
    static func imageSource(_ src: String?, baseURL: URL?) -> MDXImageSource {
        guard let src, !src.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing }
        switch MarkdownImageReference.resolve(source: src, relativeTo: baseURL) {
        case .local(let url): return .local(url)
        case .remote(let url): return .remote(url.absoluteString)
        case .invalid: return .missing
        }
    }
}
