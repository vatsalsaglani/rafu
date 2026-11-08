import Foundation
import JSONRenderCompose
import JSONRenderCore
import RafuCore

/// The board facts a composed view may show. Built from what the voice
/// backend already receives (`ensemble_describe` nodes, and the scrubbed
/// terminal tail only in Allow mode with "Share terminal output" on).
nonisolated struct GeneratedViewComposeFacts: Sendable, Equatable {
    struct Terminal: Sendable, Equatable {
        var title: String
        /// "running", "idle", "exited", "stopped" or "unavailable".
        var state: String
        var agent: String?
    }

    struct File: Sendable, Equatable {
        var title: String
        var path: String
    }

    struct TailLine: Sendable, Equatable {
        var terminal: String
        var line: String
    }

    var ensemble: String
    var cards: Int
    var links: Int
    var agentControl: String
    var terminals: [Terminal]
    var files: [File]
    /// Scrubbed terminal lines. `nil` unless the terminal tail may be shared.
    /// These lines go only into the spec's state, never to the evaluator.
    var tail: [TailLine]?

    var runningTerminals: Int { terminals.count(where: { $0.state == "running" }) }
    var agents: Int { terminals.count(where: { $0.agent != nil }) }

    static let maximumFiles = 6
    static let maximumTailLines = 20

    /// Facts from the describe nodes and the scrubbed tails (node id → text).
    static func make(
        ensemble: String, links: Int, agentControl: String,
        nodes: [CanvasAgentNodeSummary], tails: [String: String]?
    ) -> GeneratedViewComposeFacts {
        let terminals = nodes.filter { $0.kind == "terminal" }.map {
            Terminal(
                title: CanvasAgentText.singleLine($0.title, limit: 60),
                state: $0.state ?? "unavailable", agent: $0.agent)
        }
        let files = nodes.filter { $0.kind == "file" }.compactMap { node -> File? in
            guard let path = node.path, !path.isEmpty else { return nil }
            return File(title: CanvasAgentText.singleLine(node.title, limit: 60), path: path)
        }
        var tail: [TailLine]?
        if let tails {
            var lines: [TailLine] = []
            for node in nodes where node.kind == "terminal" {
                guard let text = tails[node.id] else { continue }
                let title = CanvasAgentText.singleLine(node.title, limit: 60)
                for line in text.split(separator: "\n") where !line.isEmpty {
                    lines.append(TailLine(terminal: title, line: String(line)))
                }
            }
            tail = lines
        }
        return GeneratedViewComposeFacts(
            ensemble: CanvasAgentText.singleLine(ensemble, limit: 80), cards: nodes.count,
            links: links, agentControl: agentControl, terminals: terminals,
            files: Array(files.prefix(maximumFiles)), tail: tail)
    }
}

/// Rafu's composition candidates: catalog components whose data sits in the
/// spec's `state` and is bound with `$state`. The evaluator reads only each
/// candidate's id and description (numbers and node titles, never terminal
/// text); props, bindings and state stay in Rafu.
nonisolated enum GeneratedViewCandidates {
    static let maximumCandidates = 24
    static let rootResource = "root-container"
    static let testsResource = "tests"

    /// One card's budget. Depth 2 keeps the layout flat under the root: the
    /// evaluator cannot nest a part into a Table or chart slot.
    static let limits = ComposeLimits(maxElements: 12, maxDepth: 2, maxRounds: 2)

    static let instructions = ComposeInstructions(
        next:
            "The view is a small card on a board. Prefer few parts. Use counts for how many; "
            + "use tables for lists.")

    static func make(facts: GeneratedViewComposeFacts, title: String)
        -> (candidates: [CompositionCandidate], state: JSONRenderCore.JSONValue)
    {
        var candidates: [CompositionCandidate] = []
        var state: [String: JSONRenderCore.JSONValue] = ["title": .string(title)]

        // Roots: one container, chosen once.
        candidates.append(
            CompositionCandidate(
                id: "card-panel", description: "A titled card panel that holds the other parts.",
                element: UIElement(type: "Card", props: ["title": bind("/title")]), root: true,
                resource: rootResource))
        candidates.append(
            CompositionCandidate(
                id: "stack-panel", description: "A plain vertical list of the other parts.",
                element: UIElement(type: "Stack", props: ["direction": "vertical", "gap": "md"]),
                root: true, resource: rootResource))

        candidates.append(
            CompositionCandidate(
                id: "heading", description: "A heading with the view title.",
                element: UIElement(
                    type: "Heading", props: ["text": bind("/title"), "level": "h3"]),
                root: false))

        // Counts.
        let running = facts.runningTerminals
        let agents = facts.agents
        state["counts"] = .object([
            "cards": .number(Double(facts.cards)), "running": .number(Double(running)),
            "agents": .number(Double(agents)), "terminals": .number(Double(facts.terminals.count)),
        ])
        candidates.append(
            stat(
                "stat-cards", label: "Cards", path: "/counts/cards",
                description: "A figure: \(count(facts.cards, "card")) on this Ensemble."))
        candidates.append(
            stat(
                "stat-terminals", label: "Running terminals", path: "/counts/running",
                description:
                    "A figure: \(count(running, "terminal")) running of \(facts.terminals.count)."))
        candidates.append(
            stat(
                "stat-agents", label: "Agents", path: "/counts/agents",
                description: "A figure: \(count(agents, "agent")) working in terminals."))

        // Facts about the Ensemble.
        state["ensemble"] = .object([
            "facts": .array([
                row("Ensemble", .string(facts.ensemble)),
                row("Cards", .number(Double(facts.cards))),
                row("Links", .number(Double(facts.links))),
                row("Agent control", .string(facts.agentControl)),
            ])
        ])
        candidates.append(
            CompositionCandidate(
                id: "keyvalue-ensemble",
                description:
                    "Facts about the Ensemble \"\(facts.ensemble)\": \(count(facts.cards, "card")), "
                    + "\(count(facts.links, "link")), Agent control \(facts.agentControl).",
                element: UIElement(type: "KeyValue", props: ["items": bind("/ensemble/facts")]),
                root: false))

        if !facts.terminals.isEmpty {
            state["terminals"] = .object([
                "rows": .array(
                    facts.terminals.map { terminal in
                        let value =
                            terminal.agent.map { "\(terminal.state), \($0)" } ?? terminal.state
                        return row(terminal.title, .string(value))
                    })
            ])
            candidates.append(
                CompositionCandidate(
                    id: "keyvalue-terminals",
                    description:
                        "Each terminal with its state and agent: \(count(facts.terminals.count, "terminal")), "
                        + "\(running) running, \(count(agents, "agent")).",
                    element: UIElement(type: "KeyValue", props: ["items": bind("/terminals/rows")]),
                    root: false))
        }

        // File links, one candidate per file node.
        state["files"] = .array(
            facts.files.map { .object(["path": .string($0.path), "label": .string($0.title)]) })
        for (index, file) in facts.files.enumerated() {
            candidates.append(
                CompositionCandidate(
                    id: "filelink-\(index + 1)",
                    description:
                        "A link that opens the file \"\(file.title)\" (file \(index + 1) of \(facts.files.count) on the Ensemble).",
                    element: UIElement(
                        type: "FileLink",
                        props: [
                            "path": bind("/files/\(index)/path"),
                            "label": bind("/files/\(index)/label"),
                        ]), root: false))
        }

        // Terminal output, only when it may be shared. One form is chosen.
        if let tail = facts.tail, !tail.isEmpty {
            let tests = TestLines(tail)
            state["tests"] = .object([
                "rows": .array(
                    tests.tableRows.map { .array([.string($0.terminal), .string($0.line)]) }),
                "byResult": .array([
                    .object(["result": "failed", "lines": .number(Double(tests.failed))]),
                    .object(["result": "passed", "lines": .number(Double(tests.passed))]),
                ]),
            ])
            let what =
                tests.failed > 0
                ? "\(count(tests.tableRows.count, "failure line")) from terminal output"
                : "the last \(count(tests.tableRows.count, "terminal output line"))"
            candidates.append(
                CompositionCandidate(
                    id: "table-terminal-lines", description: "A table of \(what).",
                    element: UIElement(
                        type: "Table",
                        props: [
                            "columns": ["Terminal", "Line"], "rows": bind("/tests/rows"),
                        ]), root: false, resource: testsResource))
            if tests.failed + tests.passed > 0 {
                candidates.append(
                    CompositionCandidate(
                        id: "bar-test-results",
                        description:
                            "A bar chart of test output lines: \(tests.failed) failed, \(tests.passed) passed.",
                        element: UIElement(
                            type: "BarChart",
                            props: ["data": bind("/tests/byResult"), "x": "result", "y": "lines"]),
                        root: false, resource: testsResource))
            }
        }
        return (Array(candidates.prefix(maximumCandidates)), .object(state))
    }

    // MARK: Helpers

    private static func bind(_ path: String) -> JSONRenderCore.JSONValue {
        .object(["$state": .string(path)])
    }

    private static func row(_ key: String, _ value: JSONRenderCore.JSONValue)
        -> JSONRenderCore.JSONValue
    {
        .object(["key": .string(key), "value": value])
    }

    private static func stat(_ id: String, label: String, path: String, description: String)
        -> CompositionCandidate
    {
        CompositionCandidate(
            id: id, description: description,
            element: UIElement(
                type: "Stat", props: ["label": .string(label), "value": bind(path)]),
            root: false)
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// A simple reading of scrubbed terminal lines: lines that look like a
    /// failed or a passed test, and the rows a table shows (the failure lines,
    /// else the newest lines).
    struct TestLines {
        var failed = 0
        var passed = 0
        var tableRows: [GeneratedViewComposeFacts.TailLine] = []

        private static let failWords = ["fail", "error", "✘", "✗", "❌"]
        private static let passWords = ["pass", "✓", "✔", "succeeded"]

        init(_ lines: [GeneratedViewComposeFacts.TailLine]) {
            var failures: [GeneratedViewComposeFacts.TailLine] = []
            for line in lines {
                let lower = line.line.lowercased()
                if Self.failWords.contains(where: { lower.contains($0) }) {
                    failed += 1
                    failures.append(line)
                } else if Self.passWords.contains(where: { lower.contains($0) }) {
                    passed += 1
                }
            }
            let limit = GeneratedViewComposeFacts.maximumTailLines
            tableRows =
                failures.isEmpty ? Array(lines.suffix(limit)) : Array(failures.prefix(limit))
        }
    }
}
