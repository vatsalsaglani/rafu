import AppKit
import OSLog

/// TEMPORARY drag-and-drop diagnostics. Revert the one commit that added
/// this file to remove every call site. Logs only event kinds, counts, and
/// booleans — never a path, title, or payload. Read with:
///
///     log stream --level info --style compact \
///       --predicate 'subsystem == "dev.vatsalsaglani.rafu" AND category == "DragDiag"'
enum DragDiag {
    private static let logger = Logger(subsystem: "dev.vatsalsaglani.rafu", category: "DragDiag")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public) \(currentEvent, privacy: .public)")
    }

    /// The event AppKit is dispatching right now: its type, and for a mouse
    /// event its click count and pressed buttons. `clickCount` raises for a
    /// non-mouse event, so it is read only for mouse types.
    private static var currentEvent: String {
        // `NSApp` is nil in a test process that never created the app.
        guard let event = NSApp?.currentEvent else { return "[event=none]" }
        let mouseTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        guard mouseTypes.contains(event.type) else { return "[event=\(event.type.rawValue)]" }
        return "[event=\(event.type.rawValue) clicks=\(event.clickCount) "
            + "buttons=\(NSEvent.pressedMouseButtons)]"
    }
}
