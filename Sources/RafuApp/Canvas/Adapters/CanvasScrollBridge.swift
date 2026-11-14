import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board's drop target in AppKit terms. AppKit sends a drag session to a
/// registered `NSView` under the pointer. Over the board, that can be a hidden
/// editor view of the same group (mounted below the Canvas overlay) instead of
/// SwiftUI's `.onDrop`, so this bridge view accepts the drop itself. Over a
/// visible board it owns every drag: files, Agent History rows,
/// Terminals-panel Terminal Group rows, and editor tabs. See
/// `docs/references/canvas-interaction.md`, "Board drop previews".
struct CanvasBoardDropTarget {
    /// Whether the board takes this decoded drag. False rejects the drag.
    let accepts: (CanvasBoardDropContent) -> Bool
    /// The hover preview `content` would produce at the drop point (bridge's
    /// top-left space) on a bridge of size `surface`, or `nil` for none.
    let preview: (CanvasBoardDropContent, CGPoint, CGSize) -> CanvasDropPreview?
    /// Drives the board's hover preview (`CanvasBoardState.dropPreview`, the
    /// one owner both drop halves share). `nil` clears it.
    let update: (CanvasDropPreview?) -> Void
    /// The decoded drag, the drop point in the bridge's top-left space, and
    /// the bridge's size (for the edge bands of a dropped tab).
    let perform: (CanvasBoardDropContent, CGPoint, CGSize) -> Bool
}

/// SwiftUI has no desktop wheel event with scoped modifier/delta access.
/// The view never takes a mouse event (`hitTest` is nil): clicks and drags go
/// to the SwiftUI board, which is the only owner of pan and marquee. Scroll
/// and zoom come from a local event monitor, routed by `CanvasScrollRouter`;
/// file drops from the drag destination methods.
struct CanvasScrollBridge: NSViewRepresentable {
    let isEnabled: Bool
    /// Whether a point (bridge's top-left space) is on the body of the
    /// focused, content-active card. That card's body gets every scroll.
    var overActiveCardBody: (CGPoint) -> Bool = { _ in false }
    /// Space held or the Hand tool: the board pans over everything.
    var panOverridesCards: () -> Bool = { false }
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
        view.overActiveCardBody = overActiveCardBody
        view.panOverridesCards = panOverridesCards
        view.pan = pan
        view.zoom = zoom
        view.onHidden = hidden
        view.onVisible = visible
        view.drop = drop
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.detach() }

    final class Host: NSView {
        var isEnabled = true
        var overActiveCardBody: (CGPoint) -> Bool = { _ in false }
        var panOverridesCards: () -> Bool = { false }
        var pan: ((Double, Double) -> Void)?
        var zoom: ((Double, CGPoint) -> Void)?
        var onHidden: (() -> Void)?
        var onVisible: (() -> Void)?
        private var monitor: Any?
        private var scrollRouter = CanvasScrollRouter()
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
            draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let drop, let content = droppedContent(sender), drop.accepts(content) else {
                drop?.update(nil)
                return []
            }
            let point = dropPoint(sender)
            let preview = drop.preview(content, point, bounds.size)
            drop.update(preview)
            // A warn-tone preview refuses the drop (UX Round A): AppKit
            // shows no copy badge and never calls perform. The preview stays
            // drawn until the drag leaves or ends, so the reason is visible.
            switch CanvasDropAcceptance.resolve(valid: true, preview: preview) {
            case .copy: return .copy
            case .cancel, .forbidden: return []
            }
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            drop?.update(nil)
            dropSequence = nil
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let drop, let content = droppedContent(sender), drop.accepts(content) else {
                // A refused drop gets no perform or conclude call.
                drop?.update(nil)
                return false
            }
            return true
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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

        /// AppKit sends this to every destination the session visited, also
        /// when the drop happened on another view (a card's own text view, a
        /// hidden editor view, another window) or was cancelled with Escape.
        /// Without it a preview drawn by this view can outlive the drag.
        override func draggingEnded(_ sender: NSDraggingInfo) {
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
                return handleScroll(event, at: point, in: window)
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

        /// Routes one scroll event. Returns the event to pass it on to the
        /// view under the pointer, or nil when the board consumed it.
        private func handleScroll(_ event: NSEvent, at point: CGPoint, in window: NSWindow)
            -> NSEvent?
        {
            let phase = Self.routerPhase(event)
            let decides = scrollRouter.needsDecision(phase, at: event.timestamp)
            let input = CanvasScrollRouter.Input(
                phase: phase, timestamp: event.timestamp,
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                zoomModifier: event.modifierFlags.contains(.control)
                    || event.modifierFlags.contains(.command),
                panOverridesCards: panOverridesCards(),
                // The hit test and card geometry are read only where the
                // router decides (gesture start, a new wheel run).
                overActiveCardBody: decides && overActiveCardBody(point),
                extents: decides ? scrollExtents(under: event, in: window) : [])
            switch scrollRouter.route(input) {
            case .content:
                return event
            case .zoom:
                if event.scrollingDeltaY != 0 {
                    zoom?(event.scrollingDeltaY > 0 ? 1.05 : 1 / 1.05, point)
                }
            case .board:
                pan?(event.scrollingDeltaX, event.scrollingDeltaY)
            }
            return nil
        }

        /// Maps AppKit's two phase fields to the router's one. Momentum
        /// events carry `phase == []` and a non-empty `momentumPhase`; a
        /// classic wheel has both empty.
        static func routerPhase(_ event: NSEvent) -> CanvasScrollRouter.Phase {
            routerPhase(phase: event.phase, momentumPhase: event.momentumPhase)
        }

        static func routerPhase(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase)
            -> CanvasScrollRouter.Phase
        {
            if phase.contains(.mayBegin) { return .mayBegin }
            if phase.contains(.began) { return .began }
            if phase.contains(.cancelled) { return .cancelled }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
            if !momentumPhase.isEmpty { return .momentum }
            return .legacy
        }

        /// The scroll views under the pointer, innermost first, up to four
        /// levels. Scroll views that contain the board itself are not card
        /// content and stop the walk.
        private func scrollExtents(under event: NSEvent, in window: NSWindow)
            -> [CanvasScrollExtent]
        {
            guard let contentView = window.contentView else { return [] }
            let location =
                contentView.superview?.convert(event.locationInWindow, from: nil)
                ?? event.locationInWindow
            guard let hit = contentView.hitTest(location) else { return [] }
            var extents: [CanvasScrollExtent] = []
            var scrollView = hit as? NSScrollView ?? hit.enclosingScrollView
            while let current = scrollView, extents.count < 4, !isDescendant(of: current) {
                if let extent = Self.extent(of: current) { extents.append(extent) }
                scrollView = current.enclosingScrollView
            }
            return extents
        }

        /// The extent of one scroll view, measured on its clip view (whose
        /// bounds origin is the scroll position, insets included) so the top
        /// of the document is offset zero whether or not it is flipped.
        static func extent(of scrollView: NSScrollView) -> CanvasScrollExtent? {
            guard let document = scrollView.documentView else { return nil }
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            let frame = document.frame
            let visible = clip.bounds
            let top =
                clip.isFlipped
                ? visible.minY - (frame.minY - insets.top)
                : (frame.maxY + insets.top) - visible.maxY
            return CanvasScrollExtent(
                offset: CGPoint(x: visible.minX - (frame.minX - insets.left), y: top),
                contentSize: CGSize(
                    width: frame.width + insets.left + insets.right,
                    height: frame.height + insets.top + insets.bottom),
                visibleSize: visible.size)
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
