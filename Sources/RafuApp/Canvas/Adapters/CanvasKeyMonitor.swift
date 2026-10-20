import AppKit
import SwiftUI

/// Takes Control-Tab while a card's content has focus and returns to the
/// board (review 7.2, 7.7). It is the only extra key Rafu takes from a
/// terminal. A local monitor sees the key before the main menu, where
/// Control-Tab is also "Next Tab", so the board wins only while a card's
/// content is active.
struct CanvasReturnKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let perform: () -> Void

    func makeNSView(context: Context) -> Host {
        let view = Host()
        configure(view)
        return view
    }
    func updateNSView(_ view: Host, context: Context) { configure(view) }
    private func configure(_ view: Host) {
        view.isActive = isActive
        view.perform = perform
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var isActive = false
        var perform: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Control alone, with the Tab key (key code 48).
        static func isReturnToBoard(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
            let relevant = flags.intersection([.control, .command, .option, .shift])
            return keyCode == 48 && relevant == .control
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isActive, let window = self.window, event.window === window,
                    window.isKeyWindow, window.attachedSheet == nil,
                    Self.isReturnToBoard(keyCode: event.keyCode, flags: event.modifierFlags)
                else { return event }
                perform?()
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit { detach() }
    }
}

/// Delete or Forward Delete on a selected Ensemble edge. An edge is not a
/// focusable control, and the click that selects it also leaves card content,
/// so the board's own `onKeyPress` can miss the key when the board has no
/// focus yet. This local monitor is active only while an edge is selected and
/// the board takes keys; it never takes the key from text input (an editor,
/// a note, a terminal, a field), and it lets every other key pass.
struct CanvasEdgeDeleteKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    /// Returns true when it deleted an edge; the key is consumed only then.
    let perform: () -> Bool

    func makeNSView(context: Context) -> Host {
        let view = Host()
        configure(view)
        return view
    }
    func updateNSView(_ view: Host, context: Context) { configure(view) }
    private func configure(_ view: Host) {
        view.isActive = isActive
        view.perform = perform
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var isActive = false
        var perform: (() -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Delete (Backspace, key code 51) or Forward Delete (117), with no
        /// Command, Option or Control.
        static func isEdgeDelete(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
            guard keyCode == 51 || keyCode == 117 else { return false }
            return flags.intersection([.command, .option, .control]).isEmpty
        }

        /// False while text input owns the keys, so Backspace still edits.
        static func responderAllowsEdgeDelete(_ responder: NSResponder?) -> Bool {
            guard let responder, !(responder is NSWindow) else { return true }
            if responder is NSText { return false }
            if responder is any NSTextInputClient { return false }
            return true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isActive, let window = self.window, event.window === window,
                    window.isKeyWindow, window.attachedSheet == nil,
                    Self.isEdgeDelete(keyCode: event.keyCode, flags: event.modifierFlags),
                    Self.responderAllowsEdgeDelete(window.firstResponder),
                    perform?() == true
                else { return event }
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit { detach() }
    }
}
