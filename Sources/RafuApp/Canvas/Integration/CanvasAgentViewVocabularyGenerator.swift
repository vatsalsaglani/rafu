import JSONRenderCharts
import JSONRenderCore

/// Generates `CanvasAgentViewVocabulary.text` from the Rafu catalog's prompt.
///
/// RafuCore cannot link the json-render package (the `rafu` MCP server links
/// RafuCore), so the text is a constant there and
/// `CanvasAgentViewVocabularyDriftTests` compares it with this output. The
/// output is deterministic: catalog order, fixed summaries, no dates.
nonisolated enum CanvasAgentViewVocabularyGenerator {
    static let maximumBytes = 6 * 1_024

    /// The vocabulary for the current Rafu catalog.
    static func generate() -> String {
        let prompt = RafuCatalog.rafu.prompt(PromptOptions(mode: .inline, includeExtensions: true))
        return trim(
            prompt: prompt, chartNames: Set(ChartEntries.components.map(\.name)),
            catalogVersion: RafuCatalog.version)
    }

    /// Keeps the component lines (charts by name only), the action names and
    /// the `$computed` names from `prompt`, adds two fixed summaries, and cuts
    /// component lines shorter until the whole text fits `maximumBytes`.
    static func trim(prompt: String, chartNames: Set<String>, catalogVersion: String) -> String {
        let lines = prompt.components(separatedBy: "\n")
        let components = section(lines, startingWith: "AVAILABLE COMPONENTS")
            .compactMap(listItem)
        let actions = section(lines, startingWith: "AVAILABLE ACTIONS")
            .compactMap(listItem).map(name)
        let functions = section(lines, startingWith: "   Available functions:")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                return String(trimmed.dropFirst(2).prefix { $0 != " " })
            }
        let charts = components.map(name).filter { chartNames.contains($0) }
        let others = components.filter { !chartNames.contains(name($0)) }

        for limit in stride(from: 200, through: 40, by: -10) {
            var text = [
                "VOCABULARY (Rafu catalog \(catalogVersion)). Use only these component types.",
                "COMPONENTS (type: props):",
            ]
            text += others.map { "- " + shortened($0, limit: limit) }
            if !charts.isEmpty {
                text.append(
                    "CHARTS (props: see the json-render-swift-use skill): "
                        + charts.joined(separator: ", "))
            }
            text.append(
                "ACTIONS (on.<event>: {action, params}): " + actions.joined(separator: ", "))
            text.append(
                "VISIBILITY (visible on the element, never in props): true, false, "
                    + "{\"$state\": \"/path\"} truthy, add one of eq, neq, gt, gte, lt, lte, or "
                    + "\"not\": true; an array is AND; {\"$and\": […]}, {\"$or\": […]}.")
            var dynamic =
                "DYNAMIC PROPS: {\"$state\": \"/path\"} reads, {\"$bindState\": \"/path\"} binds "
                + "an input, {\"$item\": \"field\"}, {\"$index\": true} and {\"$bindItem\": "
                + "\"field\"} inside repeat, {\"$cond\": …, \"$then\": …, \"$else\": …}, "
                + "{\"$template\": \"Hi ${/name}\"}"
            if !functions.isEmpty {
                dynamic +=
                    ", {\"$computed\": name, \"args\": {…}} with "
                    + functions.joined(
                        separator: ", ")
            }
            text.append(dynamic + ".")
            let joined = text.joined(separator: "\n")
            if joined.utf8.count <= maximumBytes { return joined }
        }
        return String(
            decoding: Array(others.joined(separator: "\n").utf8.prefix(maximumBytes)), as: UTF8.self
        )
    }

    /// The lines after the header that starts with `prefix`, up to the next
    /// blank line after at least one item.
    private static func section(_ lines: [String], startingWith prefix: String) -> [String] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return [] }
        var result: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if result.isEmpty { continue }
                break
            }
            result.append(line)
        }
        return result
    }

    /// "- Name: rest" → "Name: rest" without the trailing " [built-in]".
    private static func listItem(_ line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        var item = String(line.dropFirst(2))
        if item.hasSuffix(" [built-in]") { item = String(item.dropLast(" [built-in]".count)) }
        return item
    }

    private static func name(_ item: String) -> String {
        String(item.prefix { $0 != ":" && $0 != " " })
    }

    /// The component line without its prose description (" - …" after the
    /// props), keeping the children/slots and events markers, cut to `limit`
    /// characters.
    private static func shortened(_ item: String, limit: Int) -> String {
        var markers = ""
        var body = item
        while let open = body.range(of: " [", options: .backwards), body.hasSuffix("]") {
            markers = String(body[open.lowerBound...]) + markers
            body = String(body[..<open.lowerBound])
        }
        if let description = body.range(of: " - ") {
            body = String(body[..<description.lowerBound])
        }
        let line = body + markers
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }
}
