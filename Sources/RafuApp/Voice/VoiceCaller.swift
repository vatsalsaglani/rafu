import Foundation
import RafuCore

extension CanvasAgentCaller {
    /// The provider id that marks a voice call: "Rafu (voice)" on the badge,
    /// the notice and the activity log.
    static let voiceProvider = "voice"

    /// The voice actor. Its card is synthetic and never on the board, so
    /// placement falls back to the selection (set by the executor) or the
    /// board's default spot, and `node_remove` can never refuse a real card
    /// as "the caller". It has no message link.
    static func voice(session: WorkspaceSession, board: CanvasBoardState, callerID: UUID)
        -> CanvasAgentCaller
    {
        CanvasAgentCaller(
            session: session, board: board,
            card: CanvasCard(
                id: CanvasCardID(rawValue: callerID), title: "Rafu (voice)",
                content: .note(snapshot: "")),
            controllerID: callerID, provider: voiceProvider,
            sendMessage: { _, _ in CanvasBridgeResponse(error: "Not available by voice.") })
    }
}
