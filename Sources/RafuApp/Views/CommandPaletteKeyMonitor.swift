import AppKit
import SwiftUI

/// Takes ⌘↩ while the Quick Open palette is the key window and runs the
/// selected row's secondary action ("Add to Ensemble").
///
/// A local monitor, not `onKeyPress`: the palette's search field is an AppKit
/// field editor, and a Command-modified key goes through `performKeyEquivalent`
/// (window, then main menu) before any view's `keyDown`. The Format menu binds
/// ⌘↩ to "Done Editing" while a note is edited, and a field editor can turn an
/// unhandled ⌘↩ into `insertNewline:` (which is `onSubmit`, so Open). A local
/// monitor sees the event before both, so the palette decides first. It lets
/// the key pass whenever the row has no secondary action, and it only acts on
/// events for its own window while that window is key.
struct CommandPaletteKeyMonitor: NSViewRepresentable {
    /// Returns true when it ran an action; the key is consumed only then.
    let perform: () -> Bool

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.perform = perform
        return view
    }
    func updateNSView(_ view: Host, context: Context) { view.perform = perform }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var perform: (() -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Return (key code 36) or keypad Enter (76) with Command and no
        /// other modifier.
        nonisolated static func isAddToEnsemble(keyCode: UInt16, flags: NSEvent.ModifierFlags)
            -> Bool
        {
            guard keyCode == 36 || keyCode == 76 else { return false }
            return flags.intersection([.command, .shift, .option, .control]) == .command
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                    window.isKeyWindow,
                    Self.isAddToEnsemble(keyCode: event.keyCode, flags: event.modifierFlags),
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
