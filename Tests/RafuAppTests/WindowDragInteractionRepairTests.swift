import AppKit
import Testing

@testable import RafuApp

@Suite("Window drag interaction repair")
@MainActor
struct WindowDragInteractionRepairTests {
    @Test("A double-click is sent only to the attached window's native titlebar")
    func doubleClickKeepsWindowOwnership() throws {
        let first = makeWindow()
        let second = makeWindow()
        let attachment = WindowDragAttachment.AttachmentView(frame: .zero)
        let target = WindowTitlebarDoubleClickTarget()
        target.attachment = attachment
        try #require(first.contentView).addSubview(attachment)
        let firstEvent = try event(window: first)
        target.forwardDoubleClick(firstEvent)
        #expect(first.titlebar.receivedEvent === firstEvent)
        #expect(second.titlebar.receivedEvent == nil)

        first.titlebar.receivedEvent = nil
        attachment.removeFromSuperview()
        try #require(second.contentView).addSubview(attachment)
        target.forwardDoubleClick(firstEvent)
        #expect(first.titlebar.receivedEvent == nil)
        #expect(second.titlebar.receivedEvent == nil)
        let secondEvent = try event(window: second)
        target.forwardDoubleClick(secondEvent)
        #expect(second.titlebar.receivedEvent === secondEvent)
    }

    @Test("Ordinary clicks and control clicks do not run a window action")
    func ignoresOtherInput() throws {
        let window = makeWindow()
        let attachment = WindowDragAttachment.AttachmentView(frame: .zero)
        let target = WindowTitlebarDoubleClickTarget()
        target.attachment = attachment
        try #require(window.contentView).addSubview(attachment)
        target.forwardDoubleClick(try event(window: window, clicks: 1))
        target.forwardDoubleClick(try event(window: window, type: .leftMouseDown))
        target.forwardDoubleClick(try event(window: window, flags: .control))
        target.forwardDoubleClick(nil)
        #expect(window.titlebar.receivedEvent == nil)

        attachment.removeFromSuperview()
        target.forwardDoubleClick(try event(window: window))
        #expect(window.titlebar.receivedEvent == nil)
    }

    @Test("Attachment does not take pointer input from the drag gesture or controls")
    func attachmentDoesNotTakePointerInput() {
        let attachment = WindowDragAttachment.AttachmentView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 14)
        )
        #expect(attachment.hitTest(NSPoint(x: 50, y: 7)) == nil)
    }

    private func makeWindow() -> DragTestWindow {
        DragTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func event(
        window: NSWindow,
        type: NSEvent.EventType = .leftMouseUp,
        clicks: Int = 2,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 400, y: 595),
                modifierFlags: flags, timestamp: 1,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: clicks, pressure: 0
            )
        )
    }
}

/// Fake the native event recipient, not a window action. The test must not
/// resize a window or change the user's system double-click setting.
@MainActor
private final class DragTestWindow: NSWindow {
    let titlebar = DragTestTitlebarContainerView()
    private let proxyButton = NSButton()

    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
        guard b == .closeButton else { return super.standardWindowButton(b) }
        if proxyButton.superview == nil { titlebar.addSubview(proxyButton) }
        return proxyButton
    }
}

@MainActor
private final class DragTestTitlebarContainerView: NSView {
    var receivedEvent: NSEvent?

    override func mouseUp(with event: NSEvent) { receivedEvent = event }
}
