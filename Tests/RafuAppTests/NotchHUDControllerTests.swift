import Foundation
import Testing

@testable import RafuApp

/// terminal-notch-hud.md: the HUD controller's reply path and dismissal
/// state — headless (each test constructs its OWN controller, never the
/// shared singleton, and installs events via the test seam, so no panel is
/// ever created). The delivery seam is a spy closure; production wires it
/// to `TerminalAttentionCenter.shared.deliverReply`, which is covered
/// separately in `TerminalAttentionTests`.

@MainActor
private func makeReplyRig() -> (
    controller: NotchHUDController, event: NotchHUDEvent, delivered: LockedDeliveries
) {
    let controller = NotchHUDController()
    let deliveries = LockedDeliveries()
    controller.deliverReply = { text, sessionID in
        deliveries.append(text, sessionID)
    }
    let event = NotchHUDEvent(sessionID: UUID(), title: "zsh 1", snippet: "s", color: nil)
    controller.installEventForTesting(event)
    return (controller, event, deliveries)
}

/// Delivery records cross from the controller's closure into test
/// assertions; a small reference box keeps that hand-off explicit.
@MainActor
private final class LockedDeliveries {
    private(set) var items: [(String, UUID)] = []
    func append(_ text: String, _ sessionID: UUID) {
        items.append((text, sessionID))
    }
}

@MainActor
@Test("sendReply delivers the sanitized reply exactly once to the shown session, then dismisses")
func sendReplyDeliversSanitizedOnce() {
    let (controller, event, delivered) = makeReplyRig()

    controller.replyText = "  continue with the fix\n"
    controller.sendReply()

    #expect(delivered.items.count == 1)
    #expect(delivered.items.first?.0 == "continue with the fix")
    #expect(delivered.items.first?.1 == event.sessionID)
    // Dismissed: the event (and its snippet) is dropped.
    #expect(controller.event == nil)
    #expect(controller.replyText.isEmpty)
}

@MainActor
@Test(
    "sendReply with an empty or whitespace-only reply is a no-op — nothing delivered, HUD stays up")
func sendReplyEmptyIsNoOp() {
    let (controller, _, delivered) = makeReplyRig()

    controller.replyText = "   "
    controller.sendReply()
    #expect(delivered.items.isEmpty)
    #expect(controller.event != nil)

    controller.replyText = ""
    controller.sendReply()
    #expect(delivered.items.isEmpty)
    #expect(controller.event != nil)
}

@MainActor
@Test("sendReply strips control characters through the one approved sanitizer before delivery")
func sendReplySanitizesThroughPolicy() {
    let (controller, _, delivered) = makeReplyRig()

    controller.replyText = "run\u{1B}[0m tests\nnow"
    controller.sendReply()

    #expect(delivered.items.count == 1)
    // Same contract as the notification reply: one line, controls dropped.
    #expect(delivered.items.first?.0 == "run[0m tests now")
}
