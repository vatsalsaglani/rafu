import Foundation
import Observation
import RafuCore
import Synchronization

/// Settings > Ensemble > "Allow Full access agents". Off by default. While
/// it is Off, Rafu refuses every request to start or switch a Codex agent to
/// full access (`CanvasAgentFullAccess`).
nonisolated enum CanvasFullAccessPreference {
    static let key = "ensemble.allowFullAccessAgents"

    /// A switch a test can flip while a question waits, without user defaults.
    final class TestSwitch: Sendable {
        private let value: Mutex<Bool>
        init(_ isOn: Bool) { value = Mutex(isOn) }
        var isOn: Bool {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    /// Tests set this for one task tree instead of writing user defaults.
    @TaskLocal static var override: TestSwitch?

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        override?.isOn ?? (defaults.object(forKey: key) as? Bool ?? false)
    }
}

/// The "Full access" badge of a terminal node: words and a symbol, never
/// colour alone.
nonisolated struct CanvasFullAccessBadge: Equatable, Sendable {
    let text: String
    let symbol: String
    let accessibilityLabel: String
    let help: String

    static let full = CanvasFullAccessBadge(
        text: CanvasAgentFullAccess.badgeText, symbol: CanvasAgentFullAccess.badgeSymbol,
        accessibilityLabel: CanvasAgentFullAccess.accessibilityLabel,
        help:
            "Codex in this node was started with full access: it runs commands with no approval prompts and no sandbox."
    )

    /// The badge for a card: only a terminal node marked full access.
    static func badge(for card: CanvasCard) -> CanvasFullAccessBadge? {
        guard case .terminal = card.content, card.fullAccess == true else { return nil }
        return .full
    }
}

/// Full-access terminals, in memory only.
///
/// - `groupIDs`: terminal groups marked full access, from an approved request
///   or from a loaded board's node flag. The Up next and Agents rows read it,
///   so they never read board cards.
/// - Grants: one per approved request, for the node's next Codex start. The
///   launcher asks for it over the terminal's private token
///   (`CanvasAgentFullAccess.grantOperation`); the answer consumes it. With no
///   grant the launcher starts Codex with its usual approvals. A saved board
///   keeps only the node's badge flag, never a grant or a start.
@Observable @MainActor
final class CanvasFullAccessTerminals {
    static let shared = CanvasFullAccessTerminals()
    /// Same as a queued launch line (`CanvasBoardState.pendingTerminalLineLifetime`).
    static let grantLifetime: TimeInterval = 15 * 60

    private(set) var groupIDs: Set<TerminalGroupID> = []
    @ObservationIgnored private var grants: [CanvasCardID: Date] = [:]

    func insert(_ groupID: TerminalGroupID) {
        if !groupIDs.contains(groupID) { groupIDs.insert(groupID) }
    }

    /// Marks the groups of a loaded board's full-access nodes, so the row
    /// badge survives an app restart.
    func adopt(_ cards: [CanvasCard]) {
        for card in cards where card.fullAccess == true {
            if case .terminal(let groupID) = card.content { insert(groupID) }
        }
    }

    /// One grant for the node's next Codex start, after the user approved it.
    func grant(_ card: CanvasCardID, now: Date = Date()) {
        grants = grants.filter { now.timeIntervalSince($0.value) < Self.grantLifetime }
        if grants.count >= 64, let oldest = grants.min(by: { $0.value < $1.value }) {
            grants.removeValue(forKey: oldest.key)
        }
        grants[card] = now
    }

    /// True once per grant, while it is fresh.
    func consumeGrant(_ card: CanvasCardID, now: Date = Date()) -> Bool {
        guard let date = grants.removeValue(forKey: card) else { return false }
        return now.timeIntervalSince(date) < Self.grantLifetime
    }

    func hasGrant(_ card: CanvasCardID) -> Bool { grants[card] != nil }

    func revokeGrant(_ card: CanvasCardID) { grants.removeValue(forKey: card) }

    /// Whether the terminal session runs in a full-access group.
    func contains(sessionID: UUID, in terminal: WorkspaceTerminalManager) -> Bool {
        guard !groupIDs.isEmpty,
            let groupID = terminal.terminalGroupAndPane(containing: sessionID)?.0
        else { return false }
        return groupIDs.contains(groupID)
    }
}
