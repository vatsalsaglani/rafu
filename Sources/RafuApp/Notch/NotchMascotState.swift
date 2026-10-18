import Foundation

/// The four moods of the Rafu mascot, one per `Resources/Mascot/rafu-*.svg`
/// pair (animated and still).
nonisolated enum RafuMascotMood: String, CaseIterable, Sendable {
    case idle
    case working
    case needsYou
    case replyReady

    /// Basename of the SVG design asset for this mood. `still` is the
    /// Reduce Motion variant.
    func assetName(still: Bool) -> String {
        let base: String
        switch self {
        case .idle: base = "rafu-idle"
        case .working: base = "rafu-working"
        case .needsYou: base = "rafu-needs-you"
        case .replyReady: base = "rafu-reply-ready"
        }
        return still ? base + "-still" : base
    }
}

/// What the mascot shows. Pure: the same agents always give the same mood.
///
/// Priority is the order a person should react in: an agent that needs you
/// outranks a finished reply, which outranks background work. A reply cue is
/// never a claim that the work is correct, only that an agent went quiet.
nonisolated struct RafuMascotState: Equatable, Sendable {
    let mood: RafuMascotMood
    let label: String
    /// The agent whose reply is ready, so the view can bounce once per reply.
    let replyID: UUID?

    static func resolve(agents: [NotchAgentRow]) -> RafuMascotState {
        if agents.contains(where: { $0.phase == .needsYou }) {
            return RafuMascotState(mood: .needsYou, label: "An agent needs you", replyID: nil)
        }
        if let reply = agents.first(where: { $0.phase == .replyReady }) {
            return RafuMascotState(
                mood: .replyReady, label: "An agent has a reply ready", replyID: reply.id)
        }
        if agents.contains(where: { $0.phase == .working }) {
            return RafuMascotState(mood: .working, label: "Agents are running", replyID: nil)
        }
        let live = agents.contains { $0.phase.isLive }
        return RafuMascotState(
            mood: .idle, label: live ? "Agents are waiting" : "No agents running", replyID: nil)
    }
}

/// Lets a reply cue bounce the mascot once per reply, however many times the
/// view is rebuilt. Bounded so a long session does not grow it.
nonisolated struct MascotBounceLedger: Sendable {
    private(set) var claimed: [UUID] = []
    static let capacity = 16

    init() {}

    /// `true` the first time `id` is claimed.
    mutating func claim(_ id: UUID) -> Bool {
        guard !claimed.contains(id) else { return false }
        claimed.append(id)
        if claimed.count > Self.capacity { claimed.removeFirst(claimed.count - Self.capacity) }
        return true
    }
}
