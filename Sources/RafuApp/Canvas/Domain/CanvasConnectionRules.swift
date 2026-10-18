import Foundation

/// Pure rules for which connections a drag may create (review 7.5, step 3).
nonisolated enum CanvasConnectionRules {
    /// Terminal to terminal is a message link; everything else is a relationship.
    static func behavior(bothTerminals: Bool) -> CanvasConnectionBehavior {
        bothTerminals ? .session : .related
    }

    /// An identical link already exists. Message links carry messages both
    /// ways, so the reverse pair is identical for them; a relationship has a
    /// direction, so only the same direction counts.
    static func isIdentical(
        from: CanvasCardID, to: CanvasCardID, bothTerminals: Bool,
        existing: [CanvasConnection], ignoring ignored: UUID? = nil
    ) -> Bool {
        existing.contains { connection in
            if connection.id == ignored { return false }
            if connection.from == from && connection.to == to { return true }
            return bothTerminals && connection.behavior == .session && connection.from == to
                && connection.to == from
        }
    }

    /// Invalid targets: the source itself, an identical existing link, and any
    /// target once the board is at its connection limit.
    static func canConnect(
        from: CanvasCardID, to: CanvasCardID, bothTerminals: Bool,
        existing: [CanvasConnection], limit: Int = CanvasLimits.connections
    ) -> Bool {
        guard from != to, existing.count < limit else { return false }
        return !isIdentical(from: from, to: to, bothTerminals: bothTerminals, existing: existing)
    }
}
