import AppKit

enum TerminalNewlinePolicy {
    static func usesLegacyLineFeed(
        event: NSEvent, hasMarkedText: Bool, hasKeyboardProtocol: Bool
    ) -> Bool {
        guard event.type == .keyDown, !hasMarkedText, !hasKeyboardProtocol,
            event.keyCode == 36 || event.keyCode == 76
        else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        return modifiers == .shift || modifiers == .control || modifiers == [.shift, .control]
    }
}

/// One app-local monitor, installed only while terminal views are attached.
/// It holds no terminal or window alive and never monitors other applications.
enum TerminalNewlineMonitor {
    private static var registrations: Set<ObjectIdentifier> = []
    private static var monitor: Any?

    static var registrationCount: Int { registrations.count }

    static func updateRegistration(for view: RafuTerminalView) {
        guard view.window != nil else {
            removeRegistration(for: view)
            return
        }
        registrations.insert(ObjectIdentifier(view))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    static func removeRegistration(for view: RafuTerminalView) {
        registrations.remove(ObjectIdentifier(view))
        guard registrations.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    static func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window.attachedSheet == nil,
            NSApp.modalWindow == nil,
            let view = window.firstResponder as? RafuTerminalView,
            view.window === window, !view.isHiddenOrHasHiddenAncestor,
            registrations.contains(ObjectIdentifier(view)),
            view.handleLegacyNewline(event)
        else { return event }
        return nil
    }
}
