import Foundation

/// The kind filters of Ensemble search. A terminal that runs an agent CLI
/// belongs to `.agent`; any other terminal belongs to `.terminal`.
nonisolated enum CanvasSearchCategory: String, CaseIterable, Sendable {
    case terminal
    case agent
    case note
    case file
    case image
    case diagram
    case web
    case frame
    case drawing

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .agent: "Agent"
        case .note: "Note"
        case .file: "File"
        case .image: "Image"
        case .diagram: "Diagram"
        case .web: "Local Web App"
        case .frame: "Frame"
        case .drawing: "Shape & Text"
        }
    }

    static func of(_ content: CanvasCardContent, isAgent: Bool) -> Self {
        switch content {
        case .terminal: isAgent ? .agent : .terminal
        case .note: .note
        case .file: .file
        case .image: .image
        case .mermaid: .diagram
        case .web: .web
        case .frame: .frame
        case .shape, .stroke, .text, .serviceIcon: .drawing
        }
    }
}

/// What the live terminal pane tells the search about a terminal card. The
/// card stores only a group id, so the provider and the shown name are runtime
/// facts that the caller injects. Nothing here is terminal output.
nonisolated struct CanvasSearchTerminalInfo: Equatable, Sendable {
    /// The agent CLI's display name ("Claude Code"), or `nil` for a shell.
    var providerName: String?
    /// The name the card header shows when it differs from the stored title.
    var shownTitle: String?

    init(providerName: String? = nil, shownTitle: String? = nil) {
        self.providerName = providerName
        self.shownTitle = shownTitle
    }
}

/// One searchable card. Built once per board change, never in a view body.
nonisolated struct CanvasSearchItem: Identifiable, Equatable, Sendable {
    let id: CanvasCardID
    let title: String
    let kindName: String
    let symbol: String
    let category: CanvasSearchCategory
    /// A short second line source: path, host, bundle id, label, count.
    let detail: String
    let providerName: String?
    /// How many connections end at this card.
    let linkCount: Int
    /// The second line of a result row, for example "Terminal · Claude Code · 2 links".
    let subtitle: String
    /// Short fields that are searched beside the title. Each is scored alone,
    /// so a match never runs across two fields.
    let searchFields: [String]

    var isLinked: Bool { linkCount > 0 }
}

/// Which results to keep. Kinds and providers form one "or" group: an empty
/// group keeps every card; otherwise a card stays when its kind or its
/// provider is picked. `linkedOnly` is a second, "and" condition.
nonisolated struct CanvasSearchFilter: Hashable, Sendable {
    var categories: Set<CanvasSearchCategory> = []
    var providers: Set<String> = []
    var linkedOnly = false

    var isEmpty: Bool { categories.isEmpty && providers.isEmpty && !linkedOnly }

    func admits(_ item: CanvasSearchItem) -> Bool {
        if linkedOnly, !item.isLinked { return false }
        if categories.isEmpty, providers.isEmpty { return true }
        if categories.contains(item.category) { return true }
        if let name = item.providerName, providers.contains(name) { return true }
        return false
    }
}

/// A searchable snapshot of one board. Pure: it reads card titles and small
/// metadata only. It never reads a note body or terminal output. Matching
/// reuses `CommandPaletteMatcher`.
nonisolated struct CanvasBoardSearchIndex: Sendable {
    static let defaultLimit = 50
    /// The longest label prefix of a shape or text card that is indexed.
    static let labelPrefixLimit = 120

    let items: [CanvasSearchItem]
    /// The kinds present on the board, in `CanvasSearchCategory` order.
    let categories: [CanvasSearchCategory]
    /// The agent providers present on the board, sorted by name.
    let providers: [String]
    /// Whether any card is linked.
    let hasLinks: Bool

    init(
        cards: [CanvasCard], connections: [CanvasConnection],
        terminal: (CanvasCard) -> CanvasSearchTerminalInfo? = { _ in nil }
    ) {
        let titles = Dictionary(
            cards.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var peers: [CanvasCardID: [String]] = [:]
        var linkCounts: [CanvasCardID: Int] = [:]
        for connection in connections {
            linkCounts[connection.from, default: 0] += 1
            linkCounts[connection.to, default: 0] += 1
            let label = connection.customLabel
            if let label {
                peers[connection.from, default: []].append(label)
                peers[connection.to, default: []].append(label)
            }
            if let to = titles[connection.to] { peers[connection.from, default: []].append(to) }
            if let from = titles[connection.from] { peers[connection.to, default: []].append(from) }
        }

        var built: [CanvasSearchItem] = []
        built.reserveCapacity(cards.count)
        for card in cards {
            let info: CanvasSearchTerminalInfo? =
                if case .terminal = card.content { terminal(card) } else { nil }
            let provider = info?.providerName
            let category = CanvasSearchCategory.of(card.content, isAgent: provider != nil)
            let title =
                info?.shownTitle
                ?? CanvasCardPresentation.displayTitle(title: card.title, content: card.content)
            let (detail, extra) = Self.detail(of: card.content, provider: provider)
            let links = linkCounts[card.id] ?? 0
            var subtitleParts = [card.content.kindName]
            if !detail.isEmpty, detail != card.content.kindName { subtitleParts.append(detail) }
            if links > 0 { subtitleParts.append(links == 1 ? "1 link" : "\(links) links") }
            var fields = [card.content.kindName, category.title, detail] + extra
            if let provider { fields.append(provider) }
            if card.title != title { fields.append(card.title) }
            fields += peers[card.id] ?? []
            built.append(
                CanvasSearchItem(
                    id: card.id, title: title, kindName: card.content.kindName,
                    symbol: card.content.symbol, category: category, detail: detail,
                    providerName: provider, linkCount: links,
                    subtitle: subtitleParts.joined(separator: " · "),
                    searchFields: fields.filter { !$0.isEmpty }))
        }
        items = built
        let present = Set(built.map(\.category))
        categories = CanvasSearchCategory.allCases.filter(present.contains)
        providers = Array(Set(built.compactMap(\.providerName))).sorted()
        hasLinks = built.contains(where: \.isLinked)
    }

    /// The visible detail and any extra searchable strings for a card.
    private static func detail(of content: CanvasCardContent, provider: String?) -> (
        String, [String]
    ) {
        switch content {
        case .file(let path), .image(let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (path, [name])
        case .terminal:
            return (provider ?? "", [])
        case .web(let destination):
            let host = CanvasCardPresentation.displayTitle(
                title: destination.address, content: content)
            return (host, [destination.address])
        case .mermaid(let source):
            return (CanvasCardSummaryText.firstLine(of: source, limit: 60), [])
        case .shape(let shape):
            return (shape.label.map(Self.labelPrefix) ?? "", [])
        case .text(let text):
            return (Self.labelPrefix(text.text), [])
        case .frame(let frame):
            let count = frame.memberIDs.count
            return (count == 1 ? "1 card" : "\(count) cards", [])
        case .serviceIcon(let icon):
            return (icon.label, [])
        case .note, .stroke:
            // A note body can be 64 KiB and its saved text can be stale.
            return ("", [])
        }
    }

    /// At most `labelPrefixLimit` characters of a label, on one line.
    static func labelPrefix(_ text: String) -> String {
        String(
            text.prefix(labelPrefixLimit)
                .map { $0.isNewline ? " " : $0 }
        ).trimmingCharacters(in: .whitespaces)
    }

    /// The cards that pass `filter` and match `query`, best first. An empty
    /// query keeps board order. Ties break by title, then by id, so the order
    /// is the same on every run.
    func matches(
        _ query: String, filter: CanvasSearchFilter = CanvasSearchFilter(),
        limit: Int = Self.defaultLimit
    ) -> [CanvasSearchItem] {
        let admitted = items.filter(filter.admits)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Array(admitted.prefix(max(0, limit))) }
        var scored: [(score: Int, item: CanvasSearchItem)] = []
        for item in admitted {
            guard let score = Self.score(text, item) else { continue }
            scored.append((score, item))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let order = lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.item.id.rawValue.uuidString < rhs.item.id.rawValue.uuidString
        }
        return scored.prefix(max(0, limit)).map(\.item)
    }

    /// The title counts in full. Every other field counts at half weight, so
    /// a title hit outranks a hit in a detail.
    private static func score(_ query: String, _ item: CanvasSearchItem) -> Int? {
        var best = CommandPaletteMatcher.score(query: query, candidate: item.title)
        for field in item.searchFields {
            guard let value = CommandPaletteMatcher.score(query: query, candidate: field) else {
                continue
            }
            best = max(best ?? Int.min, value / 2)
        }
        return best
    }
}
