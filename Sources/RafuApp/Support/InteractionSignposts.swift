import AppKit
import OSLog
import QuartzCore

/// Signposts for interactive latency, readable in Instruments (os_signpost,
/// subsystem `dev.vatsalsaglani.rafu`, category `Interaction`).
///
/// - `TabClickQueued` (event): the time between the mouse event and the
///   moment the app handled it (`inputLatencyMs`). A large value means the
///   main thread was busy before the click was dispatched, not that the tab
///   switch itself was slow.
/// - `TabSwitch` (interval): from the model change to the Core Animation
///   transaction that carries the resulting SwiftUI/AppKit update. A long
///   interval means layout or drawing after the switch is slow.
///
/// Security (AGENTS.md): payloads carry numbers only. Never add a path, file
/// name, tab title, or document text here.
nonisolated enum InteractionSignpost {
    static let subsystem = "dev.vatsalsaglani.rafu"
    static let category = "Interaction"
    static let signposter = OSSignposter(subsystem: subsystem, category: category)
    static let logger = Logger(subsystem: subsystem, category: category)

    /// Input latency above this value is also written to the log, so that a
    /// slow click is visible without a trace.
    static let slowInputLatencyMilliseconds = 100.0

    /// The delay between a hardware event and now, in milliseconds. Event
    /// timestamps and `systemUptime` share one clock (time since boot).
    static func inputLatencyMilliseconds(
        eventTimestamp: TimeInterval, now: TimeInterval
    ) -> Double {
        max(0, (now - eventTimestamp) * 1000)
    }

    static func isMouseEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp:
            true
        default:
            false
        }
    }

    /// Emits `TabClickQueued` when a mouse event is being handled, then opens
    /// a `TabSwitch` interval that ends when the current Core Animation
    /// transaction completes.
    @MainActor
    static func beginTabSwitch() {
        if let event = NSApp?.currentEvent, isMouseEvent(event.type) {
            let latency = inputLatencyMilliseconds(
                eventTimestamp: event.timestamp,
                now: ProcessInfo.processInfo.systemUptime)
            signposter.emitEvent(
                "TabClickQueued",
                "inputLatencyMs=\(latency, format: .fixed(precision: 1))")
            if latency >= slowInputLatencyMilliseconds {
                logger.notice(
                    "Tab click handled late: \(latency, format: .fixed(precision: 1)) ms after the event"
                )
            }
        }
        let state = signposter.beginInterval("TabSwitch")
        // The implicit transaction commits at the end of this run-loop turn,
        // after SwiftUI and AppKit have applied the switch.
        CATransaction.setCompletionBlock {
            signposter.endInterval("TabSwitch", state)
        }
    }
}
