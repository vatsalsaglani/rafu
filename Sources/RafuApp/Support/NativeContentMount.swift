import AppKit

/// Each SwiftUI presentation gets a distinct container. The native content has
/// one parent, including during a split move where old teardown can arrive late.
final class NativeContentMount: NSView {
    private(set) weak var hosted: NSView?
    var acceptsContentInput = true
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
        if hosted?.superview === self { hosted?.removeFromSuperview() }
        hosted = nil
    }
}
