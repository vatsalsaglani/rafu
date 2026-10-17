import AppKit
import SwiftUI

/// Preserve SwiftUI's window delegate. Only close preflight is owned here;
/// every other supported delegate message forwards to the original delegate.
struct CanvasWindowCloseGuard: NSViewRepresentable {
    let session: WorkspaceSession
    func makeNSView(context: Context) -> Host { Host(session: session) }
    func updateNSView(_ view: Host, context: Context) { view.attach() }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        let closeDelegate: CloseDelegate
        init(session: WorkspaceSession) {
            closeDelegate = CloseDelegate(session: session)
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
        func attach() {
            guard let window, window.delegate !== closeDelegate else { return }
            closeDelegate.attach(window)
        }
        func detach() { closeDelegate.detach() }
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var session: WorkspaceSession?
        private weak var original: (any NSWindowDelegate)?
        private weak var hostWindow: NSWindow?
        private var saveTask: Task<Void, Never>?
        private var approved = false
        init(session: WorkspaceSession) { self.session = session }
        func attach(_ window: NSWindow) {
            detach()
            original = window.delegate
            hostWindow = window
            window.delegate = self
        }
        func detach() {
            if hostWindow?.delegate === self { hostWindow?.delegate = original }
            original = nil
            hostWindow = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            session?.canvas.refreshResourceSnapshots()
            if approved || session?.canvas.hasPendingWrites != true {
                return original?.windowShouldClose?(sender) ?? true
            }
            guard saveTask == nil, let session else { return false }
            saveTask = Task { [weak self, weak sender] in
                let saved = await session.canvas.flushAll()
                guard let self else { return }
                saveTask = nil
                guard saved else {
                    session.revealCanvasSaveFailure()
                    return
                }
                guard let sender else { return }
                approved = true
                sender.performClose(nil)
                approved = false
            }
            return false
        }
        func waitForPendingSave() async { await saveTask?.value }

        // These wrappers remain MainActor isolated. Only the Bool capability
        // query crosses NSObject's nonisolated API. No delegate object crosses.
        nonisolated static let forwardedSelectors: Set<String> = [
            "windowWillReturnFieldEditor:toObject:",
            "windowWillResize:toSize:",
            "windowWillUseStandardFrame:defaultFrame:",
            "windowShouldZoom:toFrame:",
            "windowWillReturnUndoManager:",
            "window:willPositionSheet:usingRect:",
            "window:shouldPopUpDocumentPathMenu:",
            "window:shouldDragDocumentWithEvent:from:withPasteboard:",
            "window:willUseFullScreenContentSize:",
            "window:willUseFullScreenPresentationOptions:",
            "customWindowsToEnterFullScreenForWindow:",
            "window:startCustomAnimationToEnterFullScreenWithDuration:",
            "windowDidFailToEnterFullScreen:",
            "customWindowsToExitFullScreenForWindow:",
            "window:startCustomAnimationToExitFullScreenWithDuration:",
            "customWindowsToEnterFullScreenForWindow:onScreen:",
            "window:startCustomAnimationToEnterFullScreenOnScreen:withDuration:",
            "windowDidFailToExitFullScreen:",
            "window:willResizeForVersionBrowserWithMaxPreferredSize:maxAllowedSize:",
            "window:willEncodeRestorableState:",
            "window:didDecodeRestorableState:",
            "previewRepresentableActivityItemsForWindow:",
            "windowForSharingRequestFromWindow:",
            "windowDidResize:",
            "windowDidExpose:",
            "windowWillMove:",
            "windowDidMove:",
            "windowDidBecomeKey:",
            "windowDidResignKey:",
            "windowDidBecomeMain:",
            "windowDidResignMain:",
            "windowWillClose:",
            "windowWillMiniaturize:",
            "windowDidMiniaturize:",
            "windowDidDeminiaturize:",
            "windowDidUpdate:",
            "windowDidChangeScreen:",
            "windowDidChangeScreenProfile:",
            "windowDidChangeBackingProperties:",
            "windowWillBeginSheet:",
            "windowDidEndSheet:",
            "windowWillStartLiveResize:",
            "windowDidEndLiveResize:",
            "windowWillEnterFullScreen:",
            "windowDidEnterFullScreen:",
            "windowWillExitFullScreen:",
            "windowDidExitFullScreen:",
            "windowWillEnterVersionBrowser:",
            "windowDidEnterVersionBrowser:",
            "windowWillExitVersionBrowser:",
            "windowDidExitVersionBrowser:",
            "windowDidChangeOcclusionState:",
        ]
        override nonisolated func responds(to selector: Selector!) -> Bool {
            if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
            if Self.forwardedSelectors.contains(NSStringFromSelector(selector)) {
                guard Thread.isMainThread else { return false }
                return MainActor.assumeIsolated { original?.responds(to: selector) ?? false }
            }
            return super.responds(to: selector)
        }
        func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
            original?.windowWillReturnFieldEditor?(sender, to: client)
        }
        func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
            original?.windowWillResize?(sender, to: size) ?? size
        }
        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame frame: NSRect) -> NSRect {
            original?.windowWillUseStandardFrame?(window, defaultFrame: frame) ?? frame
        }
        func windowShouldZoom(_ window: NSWindow, toFrame frame: NSRect) -> Bool {
            original?.windowShouldZoom?(window, toFrame: frame) ?? true
        }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
            original?.windowWillReturnUndoManager?(window)
        }
        func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect)
            -> NSRect
        { original?.window?(window, willPositionSheet: sheet, using: rect) ?? rect }
        func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool {
            original?.window?(window, shouldPopUpDocumentPathMenu: menu) ?? true
        }
        func window(
            _ window: NSWindow, shouldDragDocumentWith event: NSEvent, from point: NSPoint,
            with pasteboard: NSPasteboard
        ) -> Bool {
            original?.window?(window, shouldDragDocumentWith: event, from: point, with: pasteboard)
                ?? !window.isDocumentEdited
        }
        func window(_ window: NSWindow, willUseFullScreenContentSize size: NSSize) -> NSSize {
            original?.window?(window, willUseFullScreenContentSize: size) ?? size
        }
        func window(
            _ window: NSWindow,
            willUseFullScreenPresentationOptions options: NSApplication.PresentationOptions
        ) -> NSApplication.PresentationOptions {
            original?.window?(window, willUseFullScreenPresentationOptions: options) ?? options
        }
        func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
            original?.customWindowsToEnterFullScreen?(for: window)
        }
        func window(
            _ window: NSWindow,
            startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval
        ) { original?.window?(window, startCustomAnimationToEnterFullScreenWithDuration: duration) }
        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            original?.windowDidFailToEnterFullScreen?(window)
        }
        func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
            original?.customWindowsToExitFullScreen?(for: window)
        }
        func window(
            _ window: NSWindow,
            startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval
        ) { original?.window?(window, startCustomAnimationToExitFullScreenWithDuration: duration) }
        func customWindowsToEnterFullScreen(for window: NSWindow, on screen: NSScreen)
            -> [NSWindow]?
        { original?.customWindowsToEnterFullScreen?(for: window, on: screen) }
        func window(
            _ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen,
            withDuration duration: TimeInterval
        ) {
            original?.window?(
                window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: duration)
        }
        func windowDidFailToExitFullScreen(_ window: NSWindow) {
            original?.windowDidFailToExitFullScreen?(window)
        }
        func window(
            _ window: NSWindow, willResizeForVersionBrowserWithMaxPreferredSize preferred: NSSize,
            maxAllowedSize allowed: NSSize
        ) -> NSSize {
            original?.window?(
                window, willResizeForVersionBrowserWithMaxPreferredSize: preferred,
                maxAllowedSize: allowed) ?? preferred
        }
        func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
            original?.window?(window, willEncodeRestorableState: state)
        }
        func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
            original?.window?(window, didDecodeRestorableState: state)
        }
        func previewRepresentableActivityItems(for window: NSWindow)
            -> [any NSPreviewRepresentableActivityItem]?
        { original?.previewRepresentableActivityItems?(for: window) }
        func windowForSharingRequest(from window: NSWindow) -> NSWindow? {
            original?.windowForSharingRequest?(from: window)
        }
        func windowDidResize(_ notification: Notification) {
            original?.windowDidResize?(notification)
        }
        func windowDidExpose(_ notification: Notification) {
            original?.windowDidExpose?(notification)
        }
        func windowWillMove(_ notification: Notification) {
            original?.windowWillMove?(notification)
        }
        func windowDidMove(_ notification: Notification) { original?.windowDidMove?(notification) }
        func windowDidBecomeKey(_ notification: Notification) {
            original?.windowDidBecomeKey?(notification)
        }
        func windowDidResignKey(_ notification: Notification) {
            original?.windowDidResignKey?(notification)
        }
        func windowDidBecomeMain(_ notification: Notification) {
            original?.windowDidBecomeMain?(notification)
        }
        func windowDidResignMain(_ notification: Notification) {
            original?.windowDidResignMain?(notification)
        }
        func windowWillClose(_ notification: Notification) {
            original?.windowWillClose?(notification)
        }
        func windowWillMiniaturize(_ notification: Notification) {
            original?.windowWillMiniaturize?(notification)
        }
        func windowDidMiniaturize(_ notification: Notification) {
            original?.windowDidMiniaturize?(notification)
        }
        func windowDidDeminiaturize(_ notification: Notification) {
            original?.windowDidDeminiaturize?(notification)
        }
        func windowDidUpdate(_ notification: Notification) {
            original?.windowDidUpdate?(notification)
        }
        func windowDidChangeScreen(_ notification: Notification) {
            original?.windowDidChangeScreen?(notification)
        }
        func windowDidChangeScreenProfile(_ notification: Notification) {
            original?.windowDidChangeScreenProfile?(notification)
        }
        func windowDidChangeBackingProperties(_ notification: Notification) {
            original?.windowDidChangeBackingProperties?(notification)
        }
        func windowWillBeginSheet(_ notification: Notification) {
            original?.windowWillBeginSheet?(notification)
        }
        func windowDidEndSheet(_ notification: Notification) {
            original?.windowDidEndSheet?(notification)
        }
        func windowWillStartLiveResize(_ notification: Notification) {
            original?.windowWillStartLiveResize?(notification)
        }
        func windowDidEndLiveResize(_ notification: Notification) {
            original?.windowDidEndLiveResize?(notification)
        }
        func windowWillEnterFullScreen(_ notification: Notification) {
            original?.windowWillEnterFullScreen?(notification)
        }
        func windowDidEnterFullScreen(_ notification: Notification) {
            original?.windowDidEnterFullScreen?(notification)
        }
        func windowWillExitFullScreen(_ notification: Notification) {
            original?.windowWillExitFullScreen?(notification)
        }
        func windowDidExitFullScreen(_ notification: Notification) {
            original?.windowDidExitFullScreen?(notification)
        }
        func windowWillEnterVersionBrowser(_ notification: Notification) {
            original?.windowWillEnterVersionBrowser?(notification)
        }
        func windowDidEnterVersionBrowser(_ notification: Notification) {
            original?.windowDidEnterVersionBrowser?(notification)
        }
        func windowWillExitVersionBrowser(_ notification: Notification) {
            original?.windowWillExitVersionBrowser?(notification)
        }
        func windowDidExitVersionBrowser(_ notification: Notification) {
            original?.windowDidExitVersionBrowser?(notification)
        }
        func windowDidChangeOcclusionState(_ notification: Notification) {
            original?.windowDidChangeOcclusionState?(notification)
        }
    }
}
