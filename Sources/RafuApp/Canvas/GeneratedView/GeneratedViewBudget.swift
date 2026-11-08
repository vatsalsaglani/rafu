import Foundation

/// How much of one board file generated views may use.
///
/// A saved board is at most `CanvasLimits.documentBytes` (2 MiB), but 50 views
/// of 256 KiB each would be 12.5 MiB. So all view specs and saved view states
/// on one board share `boardBytes` (1 MiB), counted as the bytes they take in
/// the saved file (a spec is stored as one JSON string, so quotes, slashes and
/// backslashes count twice). The other half of the file stays for notes,
/// layout and links. A create or update that would pass the budget is refused
/// with a clear reason; a state that would pass it is saved smaller (or not
/// at all), and the card says "Some state was not saved".
nonisolated enum GeneratedViewBudget {
    static let boardBytes = 1_024 * 1_024

    /// The bytes `text` takes as a JSON string value in the saved file
    /// (`JSONEncoder` defaults: `/` is escaped).
    static func storedBytes(_ text: String) -> Int {
        var count = 2
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                0x08, 0x09, 0x0A, 0x0C, 0x0D:
                count += 2
            case 0..<0x20:
                count += 6
            default:
                count += 1
            }
        }
        return count
    }

    /// The stored bytes of every view on the board: spec and saved state.
    /// `replacing` swaps in another spec (and no state) for one card.
    static func usedBytes(
        _ cards: [CanvasCard], replacing: (id: CanvasCardID, specJSON: String)? = nil
    ) -> Int {
        cards.reduce(0) { sum, card in
            guard case .generatedView(let view) = card.content else { return sum }
            if let replacing, replacing.id == card.id {
                return sum + storedBytes(replacing.specJSON)
            }
            return sum + storedBytes(view.specJSON)
                + (view.state.map { storedBytes($0.stateJSON) } ?? 0)
        }
    }

    /// The reason a spec does not fit, or `nil` when it does.
    static func refusal(
        specJSON: String, cards: [CanvasCard], replacing card: CanvasCardID? = nil
    ) -> GeneratedViewError? {
        let size = specJSON.utf8.count
        guard size <= CanvasLimits.generatedViewSpecBytes else { return .tooLarge(bytes: size) }
        let used: Int
        if let card {
            used = usedBytes(cards, replacing: (card, specJSON))
        } else {
            used = usedBytes(cards) + storedBytes(specJSON)
        }
        guard used <= boardBytes else { return .tooLarge(bytes: used) }
        return nil
    }

    /// The largest saved state for one card: the 64 KiB cap, or less when the
    /// board's views are close to the budget.
    static func stateCap(for cardID: CanvasCardID, in cards: [CanvasCard]) -> Int {
        var others = 0
        for card in cards {
            guard case .generatedView(let view) = card.content else { continue }
            others += storedBytes(view.specJSON)
            if card.id != cardID { others += view.state.map { storedBytes($0.stateJSON) } ?? 0 }
        }
        return max(0, min(CanvasLimits.generatedViewStateBytes, boardBytes - others))
    }

    /// The agent-facing text for a refused size.
    static func reason(bytes: Int) -> String {
        "\(bytes) bytes is over the view limit: one view holds at most "
            + "\(CanvasLimits.generatedViewSpecBytes / 1_024) KiB, and all views on one "
            + "Ensemble at most \(boardBytes / 1_024) KiB. Remove a view or make this one smaller"
    }
}

extension GeneratedViewBudget {
    @MainActor
    static func stateCap(for cardID: CanvasCardID, on board: CanvasBoardState) -> Int {
        stateCap(for: cardID, in: board.cards)
    }
}
