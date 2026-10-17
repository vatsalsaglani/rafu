import AppKit
import SwiftUI

/// SwiftUI has no desktop wheel event with scoped modifier/delta access.
struct CanvasScrollBridge: NSViewRepresentable {
    let isEnabled: Bool
    var capturesScroll: (CGPoint) -> Bool = { _ in true }
    let pan: (Double, Double) -> Void
    let zoom: (Double) -> Void
    let hidden: () -> Void
    var visible: () -> Void = {}

    func makeNSView(context: Context) -> Host {
        let view = Host()
        configure(view)
        return view
    }
    func updateNSView(_ view: Host, context: Context) { configure(view) }
    private func configure(_ view: Host) {
        view.isEnabled = isEnabled
        view.capturesScroll = capturesScroll
        view.pan = pan
        view.zoom = zoom
        view.onHidden = hidden
        view.onVisible = visible
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var isEnabled = true
        var capturesScroll: (CGPoint) -> Bool = { _ in true }
        var pan: ((Double, Double) -> Void)?
        var zoom: ((Double) -> Void)?
        var onHidden: (() -> Void)?
        var onVisible: (() -> Void)?
        private var monitor: Any?
        private var visibility: NSObjectProtocol?
        private var lockObserver: NSObjectProtocol?
        private var unlockObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self, isEnabled, let window = self.window, event.window === window,
                    window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                    bounds.contains(convert(event.locationInWindow, from: nil))
                else { return event }
                let local = convert(event.locationInWindow, from: nil)
                guard capturesScroll(CGPoint(x: local.x, y: bounds.height - local.y)) else {
                    return event
                }
                if event.modifierFlags.contains(.control) {
                    zoom?(event.scrollingDeltaY > 0 ? 1.05 : 1 / 1.05)
                } else {
                    pan?(event.scrollingDeltaX, event.scrollingDeltaY)
                }
                return nil
            }
            visibility = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if window?.occlusionState.contains(.visible) == true {
                        self?.onVisible?()
                    } else {
                        self?.onHidden?()
                    }
                }
            }
            lockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onHidden?() } }
            unlockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if window?.occlusionState.contains(.visible) == true { self?.onVisible?() }
                }
            }
            Task { [weak self] in
                guard let self, let window = self.window else { return }
                if window.occlusionState.contains(.visible) { onVisible?() } else { onHidden?() }
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let visibility { NotificationCenter.default.removeObserver(visibility) }
            if let lockObserver {
                DistributedNotificationCenter.default().removeObserver(lockObserver)
            }
            if let unlockObserver {
                DistributedNotificationCenter.default().removeObserver(unlockObserver)
            }
            monitor = nil
            visibility = nil
            lockObserver = nil
            unlockObserver = nil
        }

        isolated deinit { detach() }
    }
}
