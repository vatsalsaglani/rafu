import Foundation

/// Fuzzy, ranked icon search over every installed pack. Build the index once
/// per pack change; each query is a linear pass over pre-normalized entries.
nonisolated struct CanvasIconSearchIndex: Sendable {
    struct Item: Sendable {
        let packID: String
        let packName: String
        let packOrder: Int
        let entry: CanvasIconPackEntry
        let name: String
        let compactName: String
        let nameWords: [String]
        let initials: String
        /// Initials without vendor words: "Amazon Simple Queue Service" -> "sqs".
        let serviceInitials: String
        let keywords: [String]
        let categoryWords: [String]
    }

    let items: [Item]

    init(packs: [CanvasIconPack]) {
        var items: [Item] = []
        for (order, pack) in packs.enumerated() {
            for entry in pack.entries {
                let name = CanvasIconSearch.normalized(entry.name)
                let words = CanvasIconSearch.words(name)
                items.append(
                    Item(
                        packID: pack.id, packName: pack.name, packOrder: order, entry: entry,
                        name: name, compactName: words.joined(), nameWords: words,
                        initials: String(words.compactMap(\.first)),
                        serviceInitials: String(
                            words.filter { !CanvasIconSearch.vendorWords.contains($0) }
                                .compactMap(\.first)),
                        keywords: entry.keywords.flatMap {
                            CanvasIconSearch.words(CanvasIconSearch.normalized($0))
                        },
                        categoryWords: CanvasIconSearch.words(
                            CanvasIconSearch.normalized(entry.category))))
            }
        }
        self.items = items
    }

    /// Up to `limit` matches, best first. Every query word must match the
    /// name, a keyword or the category, exactly, by prefix, as a substring or
    /// as an in-order subsequence of the name. An empty query lists the packs
    /// in order.
    func search(_ query: String, limit: Int = 40) -> [CanvasServiceIconMatch] {
        let bounded = max(0, min(limit, 500))
        guard bounded > 0 else { return [] }
        let normalizedQuery = CanvasIconSearch.normalized(String(query.prefix(200)))
        let tokens = CanvasIconSearch.words(normalizedQuery)
        guard !tokens.isEmpty else {
            return items.prefix(bounded).map {
                CanvasServiceIconMatch(
                    packID: $0.packID, packName: $0.packName, entry: $0.entry, score: 0)
            }
        }
        let phrase = tokens.joined(separator: " ")
        var scored: [(item: Item, score: Int)] = []
        for item in items {
            var total = 0
            var matchedAll = true
            for token in tokens {
                let value = CanvasIconSearch.score(token: token, item: item)
                if value == 0 {
                    matchedAll = false
                    break
                }
                total += value
            }
            guard matchedAll else { continue }
            let wordsName = item.nameWords.joined(separator: " ")
            if wordsName == phrase {
                total += 300
            } else if wordsName.hasPrefix(phrase) {
                total += 120
            }
            scored.append((item, total))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.name.count != rhs.item.name.count {
                return lhs.item.name.count < rhs.item.name.count
            }
            if lhs.item.packOrder != rhs.item.packOrder {
                return lhs.item.packOrder < rhs.item.packOrder
            }
            return lhs.item.name < rhs.item.name
        }
        return scored.prefix(bounded).map {
            CanvasServiceIconMatch(
                packID: $0.item.packID, packName: $0.item.packName, entry: $0.item.entry,
                score: $0.score)
        }
    }
}

nonisolated enum CanvasIconSearch {
    static let vendorWords: Set<String> = [
        "amazon", "aws", "azure", "microsoft", "google", "cloud",
    ]

    /// Lowercased, diacritics folded.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    /// Alphanumeric runs. Camel case is not split ("BigQuery" is one word).
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func score(token: String, item: CanvasIconSearchIndex.Item) -> Int {
        var best = 0
        for word in item.nameWords {
            if word == token {
                best = max(best, 100)
            } else if word.hasPrefix(token) {
                best = max(best, 70)
            }
        }
        if best < 100 {
            for keyword in item.keywords {
                if keyword == token {
                    best = max(best, 60)
                } else if keyword.hasPrefix(token) {
                    best = max(best, 45)
                }
            }
        }
        if best < 55, token.count >= 2,
            (item.initials.count >= 2 && item.initials == token)
                || (item.serviceInitials.count >= 2 && item.serviceInitials == token)
        {
            best = 55
        }
        if best < 40, token.count >= 2, item.compactName.contains(token) {
            best = 40
        }
        if best < 25 {
            for word in item.categoryWords where word == token || word.hasPrefix(token) {
                best = max(best, word == token ? 25 : 20)
            }
        }
        if best == 0, token.count >= 2,
            let gaps = subsequenceGaps(of: token, in: item.compactName),
            gaps <= 2 * token.count
        {
            best = max(1, 15 - min(gaps, 14))
        }
        return best
    }

    /// The number of skipped characters when `token` is an in-order
    /// subsequence of `text`, or nil when it is not.
    static func subsequenceGaps(of token: String, in text: String) -> Int? {
        var gaps = 0
        var started = false
        var iterator = text.makeIterator()
        for character in token {
            var found = false
            while let next = iterator.next() {
                if next == character {
                    found = true
                    started = true
                    break
                }
                if started { gaps += 1 }
            }
            if !found { return nil }
        }
        return gaps
    }
}
