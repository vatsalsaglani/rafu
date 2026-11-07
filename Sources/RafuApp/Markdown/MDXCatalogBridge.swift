import Foundation
import JSONRenderCore

/// Turns one resolved `MDXBlock` tree into a json-render `Spec` for
/// `RafuCatalog.rafu` (ADR 0034 amendment). Pure and `nonisolated`: it runs
/// off the main actor, beside the scanner and `MDXBlockBuilder`, never in a
/// view body. It reads no files, evaluates no expressions, and never logs
/// document text.
///
/// Element ids are `b<block.id>` for components and `b<block.id>c<child.id>`
/// for Markdown and Mermaid children. A top-level `.fallback` block is not
/// bridged; `MDXComponentView` draws it as `MDXFallbackBlock`.
nonisolated enum MDXCatalogBridge {
    /// Names of the Rafu document components, in registration order.
    static let documentComponents = [
        "Markdown", "Mermaid", "Code", "Callout", "Checklist", "Questions", "FileTree", "Figure",
    ]

    static func spec(for block: MDXBlock, catalog: Catalog = .rafu) -> Spec {
        var emitter = Emitter(hasStat: catalog.component(named: "Stat") != nil)
        let root = emitter.emit(block)
        return Spec(root: root, elements: emitter.elements)
    }

    private struct Emitter {
        let hasStat: Bool
        var elements: [String: UIElement] = [:]

        mutating func emit(_ block: MDXBlock) -> String {
            let id = "b\(block.id)"
            switch block.body {
            case .callout(let tone):
                var props: [String: JSONRenderCore.JSONValue] = ["kind": .string(tone.rawValue)]
                if let title = block.title { props["title"] = .string(title) }
                put(id, "Callout", props, emitChildren(of: block))
            case .card(let status):
                var props: [String: JSONRenderCore.JSONValue] = [
                    "title": .string(block.title ?? block.name)
                ]
                if let status {
                    props["description"] = .string(MDXPresentation.statusLabel(status))
                }
                put(id, "Card", props, emitChildren(of: block))
            case .checklist:
                emitChecklist(block, id: id)
            case .questions(let questions):
                var props = titleProps(block)
                props["items"] = .array(
                    questions.map {
                        .object([
                            "text": .string($0.text),
                            "options": .array($0.options.map { .string($0) }),
                        ])
                    })
                // With no list the children stay as Markdown inside the frame.
                put(id, "Questions", props, questions.isEmpty ? emitChildren(of: block) : [])
            case .fileTree(let entries):
                var props = titleProps(block)
                props["entries"] = .array(entries.map(Self.entryValue))
                put(id, "FileTree", props, entries.isEmpty ? emitChildren(of: block) : [])
            case .svg(let source, let caption):
                var props = titleProps(block)
                switch source {
                case .local(let url): props["src"] = .string(url.absoluteString)
                case .remote(let text): props["src"] = .string(text)
                case .missing: break
                }
                if let caption { props["caption"] = .string(caption) }
                put(id, "Figure", props, [])
            case .stat(let stat):
                emitStat(block, stat: stat, id: id)
            case .matrix(let table):
                emitMatrix(block, table: table, id: id)
            case .fallback:
                // Only reached for a fallback nested in a bridged block.
                var props: [String: JSONRenderCore.JSONValue] = [
                    "title": .string("<\(block.name)>")
                ]
                if !block.propsLine.isEmpty { props["description"] = .string(block.propsLine) }
                put(id, "Card", props, emitChildren(of: block))
            }
            return id
        }

        private mutating func put(
            _ id: String, _ type: String, _ props: [String: JSONRenderCore.JSONValue],
            _ children: [String]
        ) {
            elements[id] = UIElement(
                type: type, props: props, children: children.isEmpty ? nil : children)
        }

        private func titleProps(_ block: MDXBlock) -> [String: JSONRenderCore.JSONValue] {
            block.title.map { ["title": .string($0)] } ?? [:]
        }

        private static func entryValue(_ entry: MDXFileTreeEntry) -> JSONRenderCore.JSONValue {
            var fields: [String: JSONRenderCore.JSONValue] = [
                "depth": .number(Double(entry.depth)), "path": .string(entry.path),
            ]
            if let action = entry.action { fields["action"] = .string(action) }
            if let note = entry.note { fields["note"] = .string(note) }
            return .object(fields)
        }

        // MARK: Children

        /// Markdown and Mermaid children become elements; nested components
        /// recurse. Every list is bounded by the scanner and the builder.
        private mutating func emitChildren(of block: MDXBlock) -> [String] {
            var ids: [String] = []
            for child in block.children {
                switch child.content {
                case .markdown(let text):
                    ids.append(emitMarkdown(text, id: "b\(block.id)c\(child.id)"))
                case .mermaid(let result):
                    let id = "b\(block.id)c\(child.id)"
                    put(id, "Mermaid", ["source": .string(Self.mermaidSource(result))], [])
                    ids.append(id)
                case .component(let nested):
                    ids.append(emit(nested))
                }
            }
            return ids
        }

        private mutating func emitMarkdown(_ text: String, id: String) -> String {
            put(id, "Markdown", ["text": .string(text)], [])
            return id
        }

        private static func mermaidSource(_ result: MermaidParseResult) -> String {
            switch result {
            case .diagram(let diagram): diagram.raw
            case .unsupported(_, let raw): raw
            case .malformed(_, let raw, _): raw
            }
        }

        // MARK: Checklist

        private mutating func emitChecklist(_ block: MDXBlock, id: String) {
            var props = titleProps(block)
            var plain: [MDXContent] = []
            for child in block.children {
                if case .markdown(let text) = child.content { plain.append(.markdown(text)) }
            }
            // Items only when the children are one plain task list; anything
            // else stays Markdown so no text is lost.
            let items =
                block.children.count == plain.count
                ? MDXBlockBuilder.checklistItems(in: MDXBlockBuilder.markdownText(of: plain)) : nil
            if let items {
                props["items"] = .array(
                    items.map { .object(["text": .string($0.text), "done": .bool($0.done)]) })
                put(id, "Checklist", props, [])
            } else {
                props["items"] = .array([])
                put(id, "Checklist", props, emitChildren(of: block))
            }
        }

        // MARK: Stat

        private mutating func emitStat(_ block: MDXBlock, stat: MDXStatProps, id: String) {
            let statID = block.children.isEmpty ? id : "\(id)s"
            if hasStat {
                var props: [String: JSONRenderCore.JSONValue] = [
                    "label": .string(stat.label), "value": .string(stat.value),
                ]
                if let delta = stat.delta { props["delta"] = .string(delta) }
                if let unit = stat.unit { props["unit"] = .string(unit) }
                if let intent = stat.intent { props["intent"] = .string(intent) }
                put(statID, "Stat", props, [])
            } else {
                // The catalog has no Stat: the same facts as plain text.
                let text = [stat.value + (stat.unit.map { " \($0)" } ?? ""), stat.delta]
                    .compactMap { $0 }.joined(separator: "  ")
                put(
                    statID, "Card",
                    ["title": .string(stat.label), "description": .string(text)], [])
            }
            if !block.children.isEmpty {
                put(id, "Card", [:], [statID] + emitChildren(of: block))
            }
        }

        // MARK: Matrix

        private mutating func emitMatrix(_ block: MDXBlock, table: MDXTable?, id: String) {
            let props: [String: JSONRenderCore.JSONValue] = [
                "title": .string(block.title ?? block.name)
            ]
            guard let table else {
                put(id, "Card", props, emitChildren(of: block))
                return
            }
            var ids: [String] = []
            var tableDone = false
            for child in block.children {
                let childID = "b\(block.id)c\(child.id)"
                switch child.content {
                case .markdown(let text):
                    if !tableDone, let parts = MDXTableParser.extractFirstTable(in: text) {
                        tableDone = true
                        if !Self.isBlank(parts.before) {
                            ids.append(emitMarkdown(parts.before, id: "\(childID)a"))
                        }
                        let tableID = "\(childID)t"
                        put(
                            tableID, "Table",
                            Self.tableProps(table), [])
                        ids.append(tableID)
                        if !Self.isBlank(parts.after) {
                            ids.append(emitMarkdown(parts.after, id: "\(childID)b"))
                        }
                    } else {
                        ids.append(emitMarkdown(text, id: childID))
                    }
                case .mermaid(let result):
                    put(childID, "Mermaid", ["source": .string(Self.mermaidSource(result))], [])
                    ids.append(childID)
                case .component(let nested):
                    ids.append(emit(nested))
                }
            }
            if !tableDone {
                // The table spans children; show it first rather than lose it.
                let tableID = "\(id)t"
                put(tableID, "Table", Self.tableProps(table), [])
                ids.insert(tableID, at: 0)
            }
            put(id, "Card", props, ids)
        }

        private static func tableProps(_ table: MDXTable) -> [String: JSONRenderCore.JSONValue] {
            [
                "columns": .array(table.columns.map { .string($0) }),
                "rows": .array(table.rows.map { .array($0.map { .string($0) }) }),
            ]
        }

        private static func isBlank(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
