import Foundation

nonisolated struct CanvasNavigatorOpenBoard: Equatable, Sendable {
    let id: CanvasID
    let title: String
    let cardCount: Int
    var filePath: String?
}

nonisolated struct CanvasNavigatorBoardRow: Identifiable, Equatable, Sendable {
    let id: CanvasID
    let title: String
    let caption: String
    let cardCount: Int
    let isOpen: Bool
    let isCurrent: Bool
    let isOpenElsewhere: Bool
    let summary: CanvasSummary?
    let isFileBound: Bool

    var trailing: String? {
        if isOpen { return "Open" }
        return isOpenElsewhere ? "In another window" : nil
    }
}

nonisolated struct CanvasNavigatorNodeRow: Identifiable, Equatable, Sendable {
    let id: CanvasCardID
    let title: String
    let symbol: String
    let caption: String
    let kind: String
    let providerName: String?
    let terminalGroupID: TerminalGroupID?
}

nonisolated enum CanvasNavigatorModel {
    static func boardRows(
        library: [CanvasSummary], open: [CanvasID: CanvasNavigatorOpenBoard],
        current: CanvasID?, openElsewhere: Set<CanvasID>, now: Date = Date()
    ) -> [CanvasNavigatorBoardRow] {
        let saved = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(saved.keys).union(open.keys)
        return ids.compactMap { id -> CanvasNavigatorBoardRow? in
            let board = open[id]
            let summary = saved[id]
            guard let title = board?.title ?? summary?.title else { return nil }
            let count = board?.cardCount ?? summary?.cardCount ?? 0
            return CanvasNavigatorBoardRow(
                id: id, title: title,
                caption: board?.filePath
                    ?? CanvasCardSummaryText.libraryDetail(
                        cardCount: count, modified: summary?.modified, now: now),
                cardCount: count, isOpen: board != nil, isCurrent: id == current,
                isOpenElsewhere: openElsewhere.contains(id), summary: summary,
                isFileBound: board?.filePath != nil)
        }.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        }
    }

    static func nodeRows(
        items: [CanvasSearchItem], terminalGroups: [CanvasCardID: TerminalGroupID] = [:]
    ) -> [CanvasNavigatorNodeRow] {
        items.compactMap { item in
            guard item.category != .drawing else { return nil }
            return CanvasNavigatorNodeRow(
                id: item.id, title: item.title, symbol: item.symbol, caption: item.subtitle,
                kind: item.kindName, providerName: item.providerName,
                terminalGroupID: terminalGroups[item.id])
        }
    }

    static func statusWord(_ status: AgentCardStatus?) -> String? {
        switch status {
        case .needsYou, .failed, .stopped: status?.word
        default: nil
        }
    }

    static func boardAccessibilityValue(_ row: CanvasNavigatorBoardRow) -> String {
        if !row.isOpen, row.isOpenElsewhere { return "Open in another window" }
        let count = CanvasCardSummaryText.libraryDetail(cardCount: row.cardCount, modified: nil)
        let state = row.isCurrent ? "Current, open" : row.isOpen ? "Open" : "Saved"
        return "\(state), \(count)"
    }

    static func nodeAccessibilityValue(
        _ row: CanvasNavigatorNodeRow, status: AgentCardStatus?
    ) -> String {
        [row.kind, row.providerName, status?.word].compactMap { $0 }.joined(separator: ", ")
    }

    static func selectionID(board: CanvasID) -> String { "board:\(board.rawValue.uuidString)" }
    static func selectionID(node: CanvasCardID) -> String { "node:\(node.rawValue.uuidString)" }
}
