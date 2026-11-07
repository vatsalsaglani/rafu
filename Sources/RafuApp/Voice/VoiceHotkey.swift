import AppKit

/// Push-to-talk while Rafu is in front: hold ⌃⌥Space. A local `NSEvent`
/// monitor sees the key before any view (a focused terminal card included)
/// and consumes it. Key repeats are ignored. Phase 1b adds a global hotkey.
///
/// macOS uses ⌃⌥Space for "Select next source in Input menu" when more than
/// one input source is on; the system then takes the key first.
@MainActor
final class VoiceHotkey {
    static let shared = VoiceHotkey()

    /// Space.
    nonisolated static let keyCode: UInt16 = 49
    nonisolated static let modifiers: NSEvent.ModifierFlags = [.control, .option]

    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var isHolding = false

    /// Installs the monitor once, at launch. It holds no timer and does no
    /// work until the key is pressed.
    func install(session: VoiceSession = .shared) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event, session: session) ? nil : event
        }
        // Releasing the key in another app never reaches this monitor.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHolding else { return }
                self.isHolding = false
                session.endHold()
            }
        }
    }

    /// Whether an event is the push-to-talk chord. Pure, for tests.
    nonisolated static func isChord(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == Self.keyCode
            && modifiers.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function]) == Self.modifiers
    }

    /// Returns true when the event was the chord and is consumed.
    private func handle(_ event: NSEvent, session: VoiceSession) -> Bool {
        switch event.type {
        case .keyDown:
            guard Self.isChord(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
                return false
            }
            if !event.isARepeat, !isHolding {
                isHolding = true
                session.beginHold()
            }
            return true
        case .keyUp:
            // The modifiers may already be up; Space alone ends the hold.
            guard event.keyCode == Self.keyCode, isHolding else { return false }
            isHolding = false
            session.endHold()
            return true
        default:
            return false
        }
    }
}
