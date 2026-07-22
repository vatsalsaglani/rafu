import Foundation
import Testing

@testable import RafuApp

/// terminal-notch-hud.md NC-C: the companion model's attention feed —
/// `pushFeedItem`/`clearFeedItem`'s ordering/dedup/cap rules, the
/// feed-vs-drop-down arbitration as driven through the model's own headless
/// `clicked()` path, and the reply/reveal routes' sanitize-then-deliver
/// contract via injected spies (mirroring `NotchHUDControllerTests.swift`'s
/// `LockedDeliveries` pattern exactly). Each test constructs its OWN
/// `NotchCompanionModel()` (never `.shared`) and never calls
/// `activateIfEnabled()`, so no panel is ever created — `pushFeedItem`,
/// `clearFeedItem`, and `sendReply`/`revealFeedSession` are all reachable
/// with `panel == nil` (their geometry/key-status side effects guard on it,
/// same discipline as `refreshEditorRows()`).

@MainActor
private func feedItem(
    sessionID: UUID = UUID(), title: String = "zsh 1", editorName: String = "rafu",
    snippet: String = "s", timestamp: Date = Date(), color: TerminalSessionColor? = nil
) -> CompanionFeedItem {
    CompanionFeedItem(
        id: UUID(), sessionID: sessionID, title: title, editorName: editorName,
        snippet: snippet, timestamp: timestamp, color: color)
}

// MARK: - pushFeedItem

@MainActor
@Test("pushFeedItem: newest-first ordering across distinct sessions")
func pushFeedItemNewestFirst() {
    let model = NotchCompanionModel()
    let now = Date()
    model.pushFeedItem(feedItem(title: "older", timestamp: now.addingTimeInterval(-30)))
    model.pushFeedItem(feedItem(title: "newer", timestamp: now))
    #expect(model.feedItems.map(\.title) == ["newer", "older"])
}

@MainActor
@Test("pushFeedItem: a second bell from the same session replaces its card, never duplicates")
func pushFeedItemReplacesSameSession() {
    let model = NotchCompanionModel()
    let session = UUID()
    model.pushFeedItem(feedItem(sessionID: session, title: "first bell", snippet: "s1"))
    model.pushFeedItem(feedItem(sessionID: session, title: "second bell", snippet: "s2"))
    #expect(model.feedItems.count == 1)
    #expect(model.feedItems.first?.title == "second bell")
    #expect(model.feedItems.first?.snippet == "s2")
}

@MainActor
@Test("pushFeedItem: replacing a session's card does not disturb other sessions' ordering")
func pushFeedItemReplaceKeepsOthers() {
    let model = NotchCompanionModel()
    let now = Date()
    let session = UUID()
    model.pushFeedItem(
        feedItem(sessionID: session, title: "a", timestamp: now.addingTimeInterval(-10)))
    model.pushFeedItem(feedItem(title: "b", timestamp: now))
    model.pushFeedItem(
        feedItem(sessionID: session, title: "a-again", timestamp: now.addingTimeInterval(-5)))
    #expect(model.feedItems.count == 2)
    #expect(model.feedItems.map(\.title) == ["b", "a-again"])
}

@MainActor
@Test("pushFeedItem: caps stored items at 20, dropping the oldest")
func pushFeedItemCapsAt20() {
    let model = NotchCompanionModel()
    let now = Date()
    for index in 0..<25 {
        model.pushFeedItem(
            feedItem(
                title: "session-\(index)",
                timestamp: now.addingTimeInterval(Double(index))))
    }
    #expect(model.feedItems.count == 20)
    // Newest 20 survive (indices 5...24); the oldest 5 (0...4) are dropped.
    #expect(model.feedItems.first?.title == "session-24")
    #expect(model.feedItems.last?.title == "session-5")
}

// MARK: - clearFeedItem

@MainActor
@Test("clearFeedItem: removes only the matching session's card")
func clearFeedItemRemovesMatch() {
    let model = NotchCompanionModel()
    let keep = UUID()
    let drop = UUID()
    model.pushFeedItem(feedItem(sessionID: keep, title: "keep"))
    model.pushFeedItem(feedItem(sessionID: drop, title: "drop"))
    #expect(model.feedItems.count == 2)

    model.clearFeedItem(sessionID: drop)
    #expect(model.feedItems.map(\.title) == ["keep"])
}

@MainActor
@Test("clearFeedItem: a no-op for a session id never in the feed")
func clearFeedItemNoOpForUnknown() {
    let model = NotchCompanionModel()
    model.pushFeedItem(feedItem(title: "only"))
    model.clearFeedItem(sessionID: UUID())
    #expect(model.feedItems.map(\.title) == ["only"])
}

// MARK: - Feed-vs-drop-down arbitration (driven through the model's own state)

@MainActor
@Test("arbitration: resting routes to the drop-down; a click-pinned panel routes to the feed")
func arbitrationFollowsModelHoverState() {
    let model = NotchCompanionModel()
    #expect(model.hoverState == .resting)
    let resting = CompanionHoverPolicy.companionArbitration(hoverState: model.hoverState)
    #expect(resting == (routeToFeed: false, showDropDown: true))

    // `clicked()` is headless-safe: its `refreshTheme()`/`reposition()` side
    // effects both guard on `panel != nil` (see their doc comments).
    model.clicked()
    #expect(model.hoverState == .pinned)
    let pinned = CompanionHoverPolicy.companionArbitration(hoverState: model.hoverState)
    #expect(pinned == (routeToFeed: true, showDropDown: false))

    // What `WorkspaceSession.notifyIfNeeded(for:)` would do given that
    // arbitration result: push a feed card rather than showing the HUD.
    if pinned.routeToFeed {
        model.pushFeedItem(feedItem(title: "bell while pinned"))
    }
    #expect(model.feedItems.map(\.title) == ["bell while pinned"])
}

// MARK: - sendReply (mirrors NotchHUDControllerTests' LockedDeliveries pattern)

@MainActor
private final class LockedDeliveries {
    private(set) var items: [(String, UUID)] = []
    func append(_ text: String, _ sessionID: UUID) {
        items.append((text, sessionID))
    }
}

@MainActor
private func makeReplyRig() -> (
    model: NotchCompanionModel, sessionID: UUID, delivered: LockedDeliveries
) {
    let model = NotchCompanionModel()
    let deliveries = LockedDeliveries()
    model.deliverReply = { text, sessionID in
        deliveries.append(text, sessionID)
    }
    let sessionID = UUID()
    model.pushFeedItem(feedItem(sessionID: sessionID, title: "zsh 1"))
    return (model, sessionID, deliveries)
}

@MainActor
@Test("sendReply: sanitizes through TerminalAttentionPolicy before delivery, then clears the card")
func sendReplySanitizesAndClears() {
    let (model, sessionID, delivered) = makeReplyRig()

    model.sendReply("run\u{1B}[0m tests\nnow", to: sessionID)

    #expect(delivered.items.count == 1)
    #expect(delivered.items.first?.0 == "run[0m tests now")
    #expect(delivered.items.first?.1 == sessionID)
    #expect(model.feedItems.isEmpty)
}

@MainActor
@Test("sendReply: an empty or whitespace-only reply is a no-op — nothing delivered, card stays up")
func sendReplyEmptyReplyIsNoOp() {
    let (model, sessionID, delivered) = makeReplyRig()

    model.sendReply("   ", to: sessionID)
    #expect(delivered.items.isEmpty)
    #expect(model.feedItems.count == 1)
}

// MARK: - revealFeedSession

@MainActor
@Test("revealFeedSession: reveals through the injected route, then clears the card")
func revealFeedSessionRevealsAndClears() {
    let model = NotchCompanionModel()
    var revealed: [UUID] = []
    model.revealSession = { sessionID in revealed.append(sessionID) }
    let sessionID = UUID()
    model.pushFeedItem(feedItem(sessionID: sessionID, title: "zsh 1"))

    model.revealFeedSession(sessionID)

    #expect(revealed == [sessionID])
    #expect(model.feedItems.isEmpty)
}

// MARK: - engageReply / disengageReply (panel-free guard)

@MainActor
@Test("engageReply: a no-op with no panel showing — isReplyEngaged stays false")
func engageReplyNoOpWithoutPanel() {
    let model = NotchCompanionModel()
    model.engageReply()
    #expect(model.isReplyEngaged == false)
}

@MainActor
@Test("disengageReply: always safe to call, even when never engaged")
func disengageReplyAlwaysSafe() {
    let model = NotchCompanionModel()
    model.disengageReply()
    #expect(model.isReplyEngaged == false)
}
