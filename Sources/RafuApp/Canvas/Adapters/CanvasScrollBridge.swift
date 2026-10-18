import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board's file drop target in AppKit terms. AppKit sends a drag session
/// to a registered `NSView` under the pointer. Over the board, that can be a
/// hidden editor view of the same group (mounted below the Canvas overlay)
/// instead of SwiftUI's `.onDrop`, so this bridge view accepts the drop
/// itself. See `docs/references/canvas-interaction.md`, "File drops".
struct CanvasBoardDropTarget {
    /// The number of files the drag carries; false rejects the whole drag.
    let accepts: (Int) -> Bool
    let targeted: (Bool) -> Void
    /// The dropped file URLs, whether they came from the Files tree, and the
    /// drop point in the bridge's top-left space.
    let perform: ([URL], Bool, CGPoint) -> Bool
}

/// SwiftUI has no desktop wheel event with scoped modifier/delta access.
/// The view never takes a mouse event (`hitTest` is nil): clicks and drags go
/// to the SwiftUI board, which is the only owner of pan and marquee. Scroll
/// and zoom come from a local event monitor; file drops from the drag
/// destination methods.
struct CanvasScrollBridge: NSViewRepresentable {
    let isEnabled: Bool
    var capturesScroll: (CGPoint) -> Bool = { _ in true }
    let pan: (Double, Double) -> Void
    /// Zoom factor and the pointer position in the bridge's top-left space.
    let zoom: (Double, CGPoint) -> Void
    let hidden: () -> Void
    var visible: () -> Void = {}
    var drop: CanvasBoardDropTarget?

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
        view.drop = drop
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var isEnabled = true
        var capturesScroll: (CGPoint) -> Bool = { _ in true }
        var pan: ((Double, Double) -> Void)?
        var zoom: ((Double, CGPoint) -> Void)?
        var onHidden: (() -> Void)?
        var onVisible: (() -> Void)?
        private var monitor: Any?
        private var visibility: NSObjectProtocol?
        private var lockObserver: NSObjectProtocol?
        private var unlockObserver: NSObjectProtocol?
        private var dropSequence: Int?
        private var dropURLs: [URL]?
        private var dropIsInternal = false

        var drop: CanvasBoardDropTarget? {
            didSet {
                guard (drop == nil) != (oldValue == nil) else { return }
                if drop == nil {
                    unregisterDraggedTypes()
                } else {
                    registerForDraggedTypes([Self.editorDragType, .fileURL])
                }
            }
        }

        private static let editorDragType = NSPasteboard.PasteboardType(
            UTType.rafuEditorDrag.identifier)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            focusRingType = .none
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            focusRingType = .none
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        // MARK: File drops

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let drop, let urls = droppedURLs(sender), drop.accepts(urls.count) else {
                drop?.targeted(false)
                return []
            }
            drop.targeted(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            drop?.targeted(false)
            dropSequence = nil
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let drop, let urls = droppedURLs(sender) else { return false }
            return drop.accepts(urls.count)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            drop?.targeted(false)
            guard let drop, let urls = droppedURLs(sender), drop.accepts(urls.count) else {
                return false
            }
            let local = convert(sender.draggingLocation, from: nil)
            let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
            return drop.perform(urls, dropIsInternal, point)
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            drop?.targeted(false)
            dropSequence = nil
        }

        /// The file URLs of this drag, read once per drag session. The private
        /// Files-tree payload wins over its public file URL. A tab payload,
        /// plain text, or any unreadable URL gives nil, which rejects the drag.
        private func droppedURLs(_ sender: NSDraggingInfo) -> [URL]? {
            if dropSequence == sender.draggingSequenceNumber { return dropURLs }
            let pasteboard = sender.draggingPasteboard
            let types = Set((pasteboard.types ?? []).map(\.rawValue))
            var urls: [URL]?
            switch EditorDragKind.classify(typeIdentifiers: types) {
            case .internalPayload:
                dropIsInternal = true
                if let data = pasteboard.data(forType: Self.editorDragType),
                    let url = CanvasFileDropDecoder.privateURL(data)
                {
                    urls = [url]
                }
            case .externalFiles:
                dropIsInternal = false
                let objects = pasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                let read = (objects as? [URL]) ?? []
                let valid = read.filter { CanvasFileDropDecoder.isAcceptable($0) }
                if !valid.isEmpty, valid.count == read.count { urls = valid }
            case .text:
                dropIsInternal = false
            }
            dropSequence = sender.draggingSequenceNumber
            dropURLs = urls
            return urls
        }

        // MARK: Scroll, zoom and visibility

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
                let point = CGPoint(x: local.x, y: bounds.height - local.y)
                guard capturesScroll(point) else {
                    return event
                }
                if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command)
                {
                    zoom?(event.scrollingDeltaY > 0 ? 1.05 : 1 / 1.05, point)
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
