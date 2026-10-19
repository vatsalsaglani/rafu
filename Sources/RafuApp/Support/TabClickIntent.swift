import AppKit

/// What a click on a tab or a list row means. One tap handler resolves the
/// intent from the event's click count, so a single click selects at once.
/// Two competing SwiftUI gestures (`onTapGesture(count: 2)` plus
/// `onTapGesture`) make the system wait for the double-click interval before
/// it delivers the single click.
nonisolated enum TabClickIntent: Equatable, Sendable {
    /// Select or reveal the item.
    case select
    /// Select or reveal the item, then start renaming it.
    case selectAndRename

    /// A missing event, or an event that is not a primary-button mouse event
    /// (keyboard, accessibility action, menu), counts as one click.
    static func resolve(clickCount: Int, eventType: NSEvent.EventType?) -> Self {
        guard let eventType, eventType == .leftMouseUp || eventType == .leftMouseDown,
            clickCount >= 2
        else { return .select }
        return .selectAndRename
    }

    /// The intent of the event that is being handled now.
    @MainActor
    static func current() -> Self {
        let event = NSApp?.currentEvent
        return resolve(clickCount: event?.clickCount ?? 1, eventType: event?.type)
    }
}
