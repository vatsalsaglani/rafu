import Foundation
import Observation
import RafuCore

/// Agent requests that wait for an answer, per terminal controller. Rafu
/// keeps them in memory only, never saves them and never logs their text.
///
/// The supervisor opens a request (`approvalOpen`), polls for the user's
/// answer (`approvalPoll`) and closes it when the agent has its answer from
/// any side (`approvalClose`). A chosen answer stays available to the poll
/// until the close, so a lost IPC reply does not lose it; the supervisor
/// sends each key's answer at most once.
@Observable @MainActor
final class AgentRequestStore {
    static let shared = AgentRequestStore()

    /// At most this many requests wait for one terminal.
    static let perTerminalLimit = 8

    enum OpenResult: Equatable {
        case opened
        /// The same request is already open (a retried IPC call).
        case alreadyOpen
        /// Another request already uses this key.
        case conflict
        /// The terminal already has `perTerminalLimit` requests.
        case full
    }

    enum ChooseResult: Equatable {
        case chosen
        /// The request was answered or closed already.
        case stale
        /// An answer was already chosen for this request.
        case alreadyChosen
        /// The answer is not valid for this request.
        case invalid
    }

    /// Requests in arrival order (first shown first), by controller id.
    private(set) var pending: [UUID: [CanvasAgentRequest]] = [:]
    /// Chosen answers that the supervisor did not close yet, by controller id.
    private(set) var chosen: [UUID: [UUID: CanvasAgentRequestDecision]] = [:]

    /// The request the row shows for a terminal: the oldest one.
    func current(for controllerID: UUID) -> CanvasAgentRequest? {
        pending[controllerID]?.first
    }

    func requests(for controllerID: UUID) -> [CanvasAgentRequest] {
        pending[controllerID] ?? []
    }

    /// The answer chosen for `key`, while it waits for the supervisor.
    func decision(for controllerID: UUID, key: UUID) -> CanvasAgentRequestDecision? {
        chosen[controllerID]?[key]
    }

    func open(_ approval: CanvasAgentRequest, controllerID: UUID) -> OpenResult {
        if let existing = pending.values.lazy.flatMap({ $0 }).first(where: {
            $0.key == approval.key
        }) {
            let sameTerminal = pending[controllerID]?.contains { $0.key == approval.key } ?? false
            return sameTerminal && existing == approval ? .alreadyOpen : .conflict
        }
        var queue = pending[controllerID] ?? []
        guard queue.count < Self.perTerminalLimit else { return .full }
        queue.append(approval)
        pending[controllerID] = queue
        return .opened
    }

    /// Records the user's answer. Only a request that is still open, and an
    /// answer valid for its kind, is accepted.
    func choose(
        controllerID: UUID, key: UUID, decision: CanvasAgentRequestDecision
    ) -> ChooseResult {
        guard let approval = pending[controllerID]?.first(where: { $0.key == key }) else {
            return .stale
        }
        guard chosen[controllerID]?[key] == nil else { return .alreadyChosen }
        guard approval.permits(decision) else { return .invalid }
        chosen[controllerID, default: [:]][key] = decision
        return .chosen
    }

    /// The oldest chosen answer for a terminal, or nil. It stays until
    /// `close`, so the next poll returns it again.
    func pendingDecision(for controllerID: UUID) -> CanvasAgentRequestAnswer? {
        guard let answers = chosen[controllerID], !answers.isEmpty else { return nil }
        for approval in pending[controllerID] ?? [] {
            if let decision = answers[approval.key] {
                return CanvasAgentRequestAnswer(key: approval.key, decision: decision)
            }
        }
        return nil
    }

    /// Removes a request at once. An unknown or stale key does nothing.
    @discardableResult
    func close(controllerID: UUID, key: UUID) -> Bool {
        guard var queue = pending[controllerID],
            let index = queue.firstIndex(where: { $0.key == key })
        else { return false }
        queue.remove(at: index)
        pending[controllerID] = queue.isEmpty ? nil : queue
        chosen[controllerID]?[key] = nil
        if chosen[controllerID]?.isEmpty == true { chosen[controllerID] = nil }
        return true
    }

    /// Removes every request of a terminal: its route ended or changed.
    func clear(controllerID: UUID) {
        if pending[controllerID] != nil { pending[controllerID] = nil }
        if chosen[controllerID] != nil { chosen[controllerID] = nil }
    }
}
