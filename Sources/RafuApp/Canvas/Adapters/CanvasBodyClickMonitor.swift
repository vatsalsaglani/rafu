import AppKit
import SwiftUI

/// Reports every primary mouse-down inside the board to the board view, which
/// decides with `CanvasBodyClick` whether a card body was clicked. The event
/// is always returned unchanged: the view under the pointer (selectable text,
/// a link, a button, SwiftTerm, a web view) still gets it. The view itself
/// never takes a mouse event (`hitTest` is nil).
struct CanvasBodyClickMonitor: NSViewRepresentable {
    /// The point in this view's top-left space and the event's modifiers.
    let mouseDown: (CGPoint, CanvasBodyClick.Modifiers) -> Void

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.mouseDown = mouseDown
        return view
    }
    func updateNSView(_ view: Host, context: Context) { view.mouseDown = mouseDown }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var mouseDown: ((CGPoint, CanvasBodyClick.Modifiers) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window,
                    window.attachedSheet == nil, NSApp.modalWindow == nil,
                    !isHiddenOrHasHiddenAncestor
                else { return event }
                let local = convert(event.locationInWindow, from: nil)
                guard bounds.contains(local) else { return event }
                let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
                mouseDown?(point, Self.modifiers(event.modifierFlags))
                return event
            }
        }

        static func modifiers(_ flags: NSEvent.ModifierFlags) -> CanvasBodyClick.Modifiers {
            var result: CanvasBodyClick.Modifiers = []
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            return result
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit { detach() }
    }
}

extension View {
    /// Records this overlay's frame as a place where a click belongs to the
    /// overlay, not to a card body under it (`CanvasBodyClickExclusions`).
    func canvasBodyClickExclusion(_ key: String, in exclusions: CanvasBodyClickExclusions)
        -> some View
    {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(CanvasBodyClick.coordinateSpaceName))
        } action: {
            exclusions.set(key, $0)
        }
        .onDisappear { exclusions.set(key, nil) }
    }
}

extension WorkspaceSession {
    /// Gives a clicked Ensemble terminal card the keyboard. Only a running
    /// terminal whose presentation lease this board already holds (ADR 0025
    /// Amendment 5) takes focus; a click never takes a lease from another
    /// board or tab and never starts a shell.
    func focusCanvasTerminalContent(_ groupID: TerminalGroupID, board: CanvasID) {
        guard canvasTerminalOwners[groupID] == board,
            let pane = terminal.terminalGroup(groupID)?.panes.first,
            terminal.terminalController(for: pane.id) != nil
        else { return }
        _ = try? terminal.perform(.revealGroup(groupID))
        focusTerminalPane(pane.id, in: groupID)
        requestCanvasTerminalFocus()
    }
}
