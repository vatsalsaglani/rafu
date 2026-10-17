import AppKit

/// Each SwiftUI presentation gets a distinct container. The native content has
/// one parent, including during a split move where old teardown can arrive late.
final class NativeContentMount: NSView {
    private(set) weak var hosted: NSView?
    var acceptsContentInput = true
    var onWindowAttached: (() -> Void)?
    var onContentMouseDown: (() -> Void)? {
        didSet { updateInputMonitor() }
    }
    private var inputMonitor: Any?

    private func updateInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        guard window != nil, onContentMouseDown != nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, let window = self.window, event.window === window,
                window.attachedSheet == nil, NSApp.modalWindow == nil,
                !isHiddenOrHasHiddenAncestor,
                bounds.contains(convert(event.locationInWindow, from: nil))
            else { return event }
            onContentMouseDown?()
            return event
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateInputMonitor()
        if window != nil { onWindowAttached?() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsContentInput ? super.hitTest(point) : nil
    }
    func mount(_ content: NSView) {
        guard hosted !== content || content.superview !== self else { return }
        hosted?.removeFromSuperview()
        content.removeFromSuperview()
        hosted = content
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    func detach() {
        onWindowAttached = nil
        onContentMouseDown = nil
        if hosted?.superview === self { hosted?.removeFromSuperview() }
        hosted = nil
    }
    isolated deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
}
