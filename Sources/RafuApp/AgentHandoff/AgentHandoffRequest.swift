import Foundation
import RafuCore

/// One "Continue in …" request: which session to hand off, to which agent,
/// and where the click came from. It holds no transcript text.
struct AgentHandoffRequest: Identifiable, Equatable {
    enum Origin: Equatable {
        /// The History panel, an Agent Session tab, or the palette.
        case history
        /// A terminal card on an Ensemble board. The new agent starts in a
        /// new terminal card next to it.
        case ensembleCard(boardID: CanvasID, cardID: CanvasCardID)
    }

    let id = UUID()
    let summary: AgentHistorySessionSummary
    let target: AgentHistoryProvider
    let origin: Origin
}

/// What is needed to start the target agent after the files are written.
struct AgentHandoffLaunchRequest {
    let target: AgentHistoryProvider
    let source: AgentHistoryProvider
    let title: String
    let result: AgentHandoffWriteResult
    /// The folder the source session ran in, when it recorded one.
    let sessionFolder: String?
    let origin: AgentHandoffRequest.Origin
}
