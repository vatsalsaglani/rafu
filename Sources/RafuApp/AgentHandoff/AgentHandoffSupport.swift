import Foundation
import Observation
import RafuCore

extension AgentHistoryProvider {
    /// The History provider that matches an agent CLI, if Rafu can read its
    /// transcripts.
    nonisolated init?(cli: ConductorCLIID?) {
        switch cli {
        case .claudeCode?: self = .claudeCode
        case .codex?: self = .codex
        default: return nil
        }
    }
}

extension AgentHistoryStore {
    /// Starts a scan when History was never loaded, then returns once no
    /// scan is running. It waits on the store's own observation, not on a
    /// timer.
    func ensureIndexLoaded() async {
        if lastScanDate == nil, phase != .scanning { refresh() }
        while phase == .scanning {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = self.phase
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
