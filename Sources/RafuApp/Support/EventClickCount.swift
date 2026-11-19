import AppKit

/// Reads `NSEvent.clickCount` only from an event type that has one.
///
/// `-[NSEvent clickCount]` raises `NSInternalInconsistencyException`
/// ("Invalid message sent to event") for every other type: a key, a scroll,
/// a menu action, and a finger on a touch screen
/// (`NSEvent.EventType.directTouch`). On a Mac with a touch screen
/// (macOS 27), AppKit sends a touch to SwiftUI's gesture recognizers while
/// the direct-touch event is `NSApp.currentEvent`, so a gesture callback that
/// reads the click count of that current event raises. AppKit catches the
/// exception, but it has already unwound through SwiftUI's update: the window
/// stops updating while the app keeps running, and the user must force quit.
/// Never call `clickCount` directly on an event you did not type-check; use
/// this. See `docs/references/direct-touch-events.md`.
nonisolated enum EventClickCount {
    /// The count for an event that has none: a missing event, a key, a
    /// touch. One click.
    static let fallback = 1

    /// Whether AppKit answers `clickCount` for `type`. The mouse button,
    /// move and drag types. AppKit 27.2 also answers for
    /// `.mouseCancelled`; it is left out because no click reads it.
    static func carriesClickCount(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
            .otherMouseDragged:
            true
        default:
            false
        }
    }

    /// The click count of `event`, or `fallback` when it is missing or has no
    /// click count. Never raises.
    static func of(_ event: NSEvent?) -> Int {
        guard let event, carriesClickCount(event.type) else { return fallback }
        return event.clickCount
    }

    /// The click count of the event AppKit handles now.
    @MainActor
    static func current() -> Int {
        of(NSApp?.currentEvent)
    }
}
