import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board's drop target in AppKit terms. AppKit sends a drag session to a
/// registered `NSView` under the pointer. Over the board, that can be a hidden
/// editor view of the same group (mounted below the Canvas overlay) instead of
/// SwiftUI's `.onDrop`, so this bridge view accepts the drop itself. Over a
/// visible board it owns every drag: files, Agent History rows,
/// Terminals-panel Terminal Group rows, and editor tabs. See
/// `docs/references/canvas-interaction.md`, "File drops".
struct CanvasBoardDropTarget {
    /// Whether the board takes this decoded drag. False rejects the drag.
    let accepts: (CanvasBoardDropContent) -> Bool
    /// The hover preview `content` would produce at the drop point (bridge's
    /// top-left space) on a bridge of size `surface`, or `nil` for none.
    let preview: (CanvasBoardDropContent, CGPoint, CGSize) -> CanvasDropPreview?
    /// Drives the board's hover preview state.
    let update: (CanvasDropPreview?) -> Void
    /// The decoded drag, the drop point in the bridge's top-left space, and
    /// the bridge's size (for the edge bands of a dropped tab).
    let perform: (CanvasBoardDropContent, CGPoint, CGSize) -> Bool
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
        private var dropContent: CanvasBoardDropContent?

        var drop: CanvasBoardDropTarget? {
            didSet {
                guard (drop == nil) != (oldValue == nil) else { return }
                if drop == nil {
                    unregisterDraggedTypes()
                } else {
                    registerForDraggedTypes([Self.ensembleDragType, Self.editorDragType, .fileURL])
                }
            }
        }

        private static let editorDragType = NSPasteboard.PasteboardType(
            UTType.rafuEditorDrag.identifier)
        private static let ensembleDragType = NSPasteboard.PasteboardType(
            UTType.rafuEnsembleDrag.identifier)

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

        // MARK: Drops

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = draggingUpdated(sender)
            DragDiag.note(
                "board(AppKit) entered accepted=\(!operation.isEmpty) "
                    + "types=\(sender.draggingPasteboard.types?.count ?? 0)")
            return operation
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let drop, let content = droppedContent(sender), drop.accepts(content) else {
                drop?.update(nil)
                return []
            }
            let point = dropPoint(sender)
            drop.update(drop.preview(content, point, bounds.size))
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            drop?.update(nil)
            dropSequence = nil
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let drop, let content = droppedContent(sender) else { return false }
            return drop.accepts(content)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DragDiag.note("board(AppKit) performDragOperation")
            drop?.update(nil)
            guard let drop, let content = droppedContent(sender), drop.accepts(content) else {
                return false
            }
            return drop.perform(content, dropPoint(sender), bounds.size)
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            drop?.update(nil)
            dropSequence = nil
        }

        /// The drag's location converted to this view's top-left-origin
        /// space, matching `EditorDropGeometry`'s SwiftUI-style coordinates.
        private func dropPoint(_ sender: NSDraggingInfo) -> CGPoint {
            let local = convert(sender.draggingLocation, from: nil)
            return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        }

        /// What this drag carries, classified and decoded once per drag
        /// session. Priority: Agent History row or Terminal Group row (both
        /// `rafuEnsembleDrag`), then the private editor payload (a
        /// Files-tree file or an editor tab), then Finder file URLs. Plain
        /// text or anything unreadable gives nil, which rejects the drag.
        private func droppedContent(_ sender: NSDraggingInfo) -> CanvasBoardDropContent? {
            if Self.canReuseCachedDecode(
                requestSequence: sender.draggingSequenceNumber, cachedSequence: dropSequence,
                cachedContent: dropContent)
            {
                return dropContent
            }
            let pasteboard = sender.draggingPasteboard
            let types = Set((pasteboard.types ?? []).map(\.rawValue))
            var content: CanvasBoardDropContent?
            if types.contains(UTType.rafuEnsembleDrag.identifier) {
                let payload = pasteboard.data(forType: Self.ensembleDragType)
                    .flatMap(CanvasBoardDragPayload.decode)
                if let sessionKey = payload?.sessionKey {
                    content = .agentSession(sessionKey)
                } else if let groupID = payload?.terminalGroupID {
                    content = .terminalGroup(groupID)
                }
            } else {
                switch EditorDragKind.classify(typeIdentifiers: types) {
                case .internalPayload:
                    content = pasteboard.data(forType: Self.editorDragType)
                        .flatMap(CanvasFileDropDecoder.editorContent)
                case .externalFiles:
                    let objects = pasteboard.readObjects(
                        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                    let read = (objects as? [URL]) ?? []
                    let valid = read.filter { CanvasFileDropDecoder.isAcceptable($0) }
                    if !valid.isEmpty, valid.count == read.count {
                        content = .files(valid, fromFilesTree: false)
                    }
                case .text:
                    break
                }
            }
            // Only a SUCCESSFUL decode is cached. A nil decode can be a
            // transient `pasteboard.data(forType:)` miss during
            // `draggingEntered`; caching it would reject the whole drag
            // session even though `draggingUpdated`/`performDragOperation`
            // would have decoded it correctly a moment later.
            if content != nil {
                dropSequence = sender.draggingSequenceNumber
                dropContent = content
            }
            return content
        }

        /// Pure caching rule for `droppedContent`: whether a previously
        /// decoded `cachedContent` for `cachedSequence` may be reused for
        /// `requestSequence` instead of re-reading the pasteboard. A cached
        /// `nil` is never reused, so a failed decode is retried on every
        /// subsequent call within the same drag session.
        static func canReuseCachedDecode(
            requestSequence: Int, cachedSequence: Int?, cachedContent: CanvasBoardDropContent?
        ) -> Bool {
            cachedSequence == requestSequence && cachedContent != nil
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
