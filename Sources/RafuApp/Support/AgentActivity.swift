import Foundation

/// How many agent sessions are running right now, for the titlebar capsule
/// and the status bar. Pure value type: the views build entries from the live
/// terminals (see `AgentActivitySummary.init(sessions:)` in
/// `AgentIdentity.swift`) and this type only counts and words them.
nonisolated struct AgentActivitySummary: Equatable, Sendable {
    /// One terminal, reduced to what the summary needs.
    nonisolated struct Entry: Equatable, Sendable {
        var provider: ConductorCLIID?
        var isLive: Bool
        var needsAttention: Bool

        init(provider: ConductorCLIID?, isLive: Bool, needsAttention: Bool = false) {
            self.provider = provider
            self.isLive = isLive
            self.needsAttention = needsAttention
        }
    }

    /// Distinct providers of the running agents, in first-seen order.
    let providers: [ConductorCLIID]
    let runningCount: Int
    let attentionCount: Int

    init(entries: [Entry]) {
        var seen: [ConductorCLIID] = []
        var running = 0
        var attention = 0
        for entry in entries {
            guard let provider = entry.provider, entry.isLive else { continue }
            running += 1
            if entry.needsAttention { attention += 1 }
            if !seen.contains(provider) { seen.append(provider) }
        }
        providers = seen
        runningCount = running
        attentionCount = attention
    }

    /// Nothing to show when no agent is running.
    var isActive: Bool { runningCount > 0 }

    /// "1 agent running", "3 agents running".
    var label: String {
        "\(runningCount) \(runningCount == 1 ? "agent" : "agents") running"
    }

    /// Words for the attention state, so it is never colour alone.
    /// `nil` when no running agent needs attention.
    var attentionLabel: String? {
        guard attentionCount > 0 else { return nil }
        return attentionCount == 1 ? "1 needs attention" : "\(attentionCount) need attention"
    }

    /// One sentence for help text and VoiceOver.
    var accessibilityLabel: String {
        guard let attentionLabel else { return label }
        return "\(label), \(attentionLabel)"
    }
}

/// What a double-click on empty titlebar space does. macOS lets the user pick
/// Zoom (older name: Maximize), Minimize, or nothing in System Settings; the
/// choice lives in the global domain under `AppleActionOnDoubleClick`, and
/// very old systems used the boolean `AppleMiniaturizeOnDoubleClick`.
nonisolated enum TitlebarDoubleClickAction: Equatable, Sendable {
    case zoom
    case minimize
    case none

    /// Pure mapping. An unset preference means Zoom, the system default.
    static func resolve(actionPreference: String?, miniaturizePreference: Bool?) -> Self {
        if let actionPreference {
            switch actionPreference.lowercased() {
            case "minimize": return .minimize
            case "none": return .none
            default: return .zoom
            }
        }
        return miniaturizePreference == true ? .minimize : .zoom
    }

    /// Reads the user's setting. `UserDefaults.standard` searches the global
    /// domain, so no private suite is needed.
    static func current(defaults: UserDefaults = .standard) -> Self {
        resolve(
            actionPreference: defaults.string(forKey: "AppleActionOnDoubleClick"),
            miniaturizePreference: defaults.object(forKey: "AppleMiniaturizeOnDoubleClick")
                as? Bool)
    }
}
