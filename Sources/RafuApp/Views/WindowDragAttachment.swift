import AppKit
import SwiftUI

/// SwiftUI supplies explicit window dragging, but exposes no titlebar
/// double-click action. Keep that action with the native titlebar so AppKit
/// applies the current system setting, including Fill, without private
/// selectors or a second implementation of window placement.
@MainActor
final class WindowTitlebarDoubleClickTarget {
    weak var attachment: NSView?

    func forwardDoubleClick(_ event: NSEvent?) {
        guard let event, let window = attachment?.window,
            event.type == .leftMouseUp, event.clickCount == 2,
            event.window === window,
            !event.modifierFlags.contains(.control),
            !window.styleMask.contains(.fullScreen),
            window.attachedSheet == nil,
            let titlebar = Self.titlebarContainer(in: window)
        else { return }
        titlebar.mouseUp(with: event)
    }

    /// The native container is rebuilt on full-screen transitions. Resolve
    /// it for this event, using the standard button's ancestor chain rather
    /// than caching an AppKit frame view. Never forward to a button itself.
    static func titlebarContainer(in window: NSWindow) -> NSView? {
        var ancestor = window.standardWindowButton(.closeButton)?.superview
        while let view = ancestor {
            if String(describing: type(of: view)).contains("TitlebarContainerView") {
                return view
            }
            ancestor = view.superview
        }
        return nil
    }
}

/// This view only tracks attachment. It must never take an input event
/// from the SwiftUI handle or any control placed above that handle.
struct WindowDragAttachment: NSViewRepresentable {
    let target: WindowTitlebarDoubleClickTarget

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        target.attachment = view
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        target.attachment = nsView
    }

    final class AttachmentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
