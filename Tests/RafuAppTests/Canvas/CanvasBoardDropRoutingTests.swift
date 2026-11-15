import AppKit
import RafuCore
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

/// Runs a hosted routing test only where Launch Services declares the
/// private Ensemble drag type as `public.item`, the precondition for AppKit
/// to route it to a SwiftUI `.onDrop` (see
/// `docs/references/drag-and-drop-custom-uttype.md`).
private let ensembleDragTypeDeclared = ConditionTrait.enabled(
    Comment(
        rawValue: "Launch Services does not declare \(UTType.rafuEnsembleDrag.identifier); "
            + "stage and register the app bundle first (lsregister -f)")
) {
    await BoardDropFixture.launchServicesDeclaresEnsembleType
}

/// Regression guard for "dragging an Agent History row onto the board does
/// nothing". The real editor canvas hosts a visible board offscreen, and
/// AppKit's own drag-target lookup (`-[NSWindow _findDragTargetFrom:]`)
/// picks the destination for a synthetic `NSDraggingInfo` that carries the
/// row's real payload. No events are posted and no drag session starts.
///
/// It proves the DESTINATION half end to end: the editor group's own
/// `.onDrop` (which takes only tab drags under a board) never wins over the
/// board, a card's body (stopped terminal, note) does not hide the board,
/// the hover is a `.copy` with the "Resume chat" ghost, and the drop reaches
/// `WorkspaceSession.dropAgentSessionOnCanvas` (an unknown session shows the
/// board notice). It cannot start a real drag on the History row: AppKit
/// starts no drag from synthetic mouse events in a test process.
@Suite("Ensemble board drop routing")
@MainActor
struct CanvasBoardDropRoutingTests {
    @Test(
        "An Agent History drag over a visible board routes to the board and drops there",
        ensembleDragTypeDeclared)
    func agentSessionDragReachesBoard() async throws {
        let fixture = try await BoardDropFixture()
        defer { fixture.remove() }
        let points = [
            NSPoint(x: 450, y: 60),  // empty board, bottom
            NSPoint(x: 800, y: 380),  // empty board, top trailing
            fixture.windowPoint(ofCard: 0),  // over the note card's body
            fixture.windowPoint(ofCard: 1),  // over the stopped terminal card
        ]
        for point in points {
            try #require(fixture.boardFrame.contains(point), "point \(point) is off the board")
            let destination = try #require(fixture.destination(at: point), "point \(point)")
            #expect(
                fixture.isBoardSurface(destination),
                "point \(point) routed to \(type(of: destination)) \(fixture.frame(of: destination))"
            )
            let outcome = try await fixture.dropAgentSession(at: point)
            #expect(outcome.hover == .copy, "point \(point)")
            #expect(outcome.previewLabel == "Resume chat in a new terminal", "point \(point)")
            #expect(outcome.performed, "point \(point)")
            #expect(
                outcome.notice == "This session is no longer in Agent History.", "point \(point)")
        }
    }

    @Test(
        "Tab drags over the shelf above a board still route to the tab strip",
        ensembleDragTypeDeclared)
    func shelfStillRoutesToStrip() async throws {
        let fixture = try await BoardDropFixture()
        defer { fixture.remove() }
        let shelfPoint = NSPoint(x: 600, y: fixture.window.frame.height - 15)
        let destination = try #require(
            fixture.destination(at: shelfPoint, type: .rafuEditorDrag))
        #expect(!fixture.isBoardSurface(destination))
        #expect(fixture.frame(of: destination).height < 80)
    }
}

/// The AppKit half of the board's drop target (`CanvasScrollBridge.Host`)
/// decodes an Agent History payload and hands it to the board once. Needs no
/// Launch Services declaration: the bridge registers the exact type.
@Suite("Ensemble board AppKit drop bridge")
@MainActor
struct CanvasScrollBridgeDropTests {
    @Test("An Agent History payload performs once on the bridge with its session key")
    func bridgePerformsAgentSession() throws {
        _ = NSApplication.shared
        var performed: [CanvasBoardDropContent] = []
        var updates = 0
        let host = CanvasScrollBridge.Host(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.drop = CanvasBoardDropTarget(
            accepts: { _ in true },
            preview: { _, _, _ in nil },
            update: { _ in updates += 1 },
            perform: { content, _, _ in
                performed.append(content)
                return true
            })
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { host.detach() }
        let payload = CanvasBoardDragPayload.agentSession(provider: .codex, sessionID: "s-1")
        let info = BoardDraggingInfo(
            window: window, pasteboard: try BoardDropFixture.pasteboard(payload),
            location: NSPoint(x: 200, y: 150))
        #expect(host.draggingEntered(info) == .copy)
        #expect(host.prepareForDragOperation(info))
        #expect(host.performDragOperation(info))
        host.concludeDragOperation(info)
        #expect(
            performed == [
                .agentSession(AgentHistorySessionKey(provider: .codex, sessionID: "s-1"))
            ])
        #expect(updates > 0)
    }
}

@MainActor
private final class BoardDropFixture {
    struct DropOutcome {
        let hover: NSDragOperation
        let previewLabel: String?
        let performed: Bool
        let notice: String?
    }

    let folder: URL
    let session: WorkspaceSession
    let board: CanvasBoardState
    let window: NSWindow

    init() async throws {
        _ = NSApplication.shared
        folder = URL.temporaryDirectory.appending(
            path: "rafu-board-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session = WorkspaceSession(
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: folder)))
        session.descriptor = WorkspaceDescriptor(
            displayName: "BoardDrop",
            location: .local(LocalWorkspaceReference(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        board = try #require(await session.canvas.create(title: "Drop routing"))
        try board.add(
            title: "Note", content: .note(snapshot: "# Note\n"), center: CGPoint(x: 200, y: 150))
        try board.add(
            title: "Terminal", content: .terminal(groupID: TerminalGroupID()),
            center: CGPoint(x: 600, y: 250))
        session.presentCanvasBoard(board)
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: EditorCanvasView(session: session, openFolder: {})
                .frame(width: 900, height: 500))
        layout()
    }

    func layout() {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func remove() {
        session.terminal.shutdownAll()
        try? FileManager.default.removeItem(at: folder)
    }

    /// The board's AppKit drop bridge: its frame is the board surface.
    private var bridge: CanvasScrollBridge.Host? {
        func find(_ view: NSView) -> CanvasScrollBridge.Host? {
            // The board view also mounts a disabled bridge (visibility
            // only, no drop target) over the whole board view.
            if let host = view as? CanvasScrollBridge.Host, host.drop != nil { return host }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    var boardFrame: NSRect { bridge.map(frame(of:)) ?? .zero }

    /// The bridge itself, or a SwiftUI drop destination with exactly the
    /// board surface's frame (the board's `.onDrop`). The editor group's own
    /// destination is taller: it also covers the board's header bar.
    func isBoardSurface(_ view: NSView) -> Bool {
        guard let bridge else { return false }
        if view === bridge { return true }
        let name = String(describing: type(of: view))
        return name.contains("PlatformDraggingDestinationView")
            && frame(of: view).integral == frame(of: bridge).integral
    }

    /// The centre of a card's body, in window coordinates.
    func windowPoint(ofCard index: Int) -> NSPoint {
        let card = board.cards[index]
        let viewport = board.viewport
        let viewX = (card.rect.x + card.rect.width / 2) * viewport.scale + viewport.x
        let viewY = (card.rect.y + card.rect.height / 2) * viewport.scale + viewport.y
        return NSPoint(x: boardFrame.minX + viewX, y: boardFrame.maxY - viewY)
    }

    func destination(at point: NSPoint, type: UTType = .rafuEnsembleDrag) -> NSView? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rafu.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("{}".utf8), forType: NSPasteboard.PasteboardType(type.identifier))
        return Self.destination(
            in: window,
            for: BoardDraggingInfo(window: window, pasteboard: pasteboard, location: point))
    }

    /// Enter, update, prepare, perform, and conclude on the destination
    /// AppKit picks for an Agent History payload whose session is not in
    /// the index, then wait (bounded) for the board's refusal notice.
    func dropAgentSession(at point: NSPoint) async throws -> DropOutcome {
        board.notice = nil
        let payload = CanvasBoardDragPayload.agentSession(
            provider: .claudeCode, sessionID: "missing-\(UUID().uuidString)")
        let info = BoardDraggingInfo(
            window: window, pasteboard: try Self.pasteboard(payload), location: point)
        let view = try #require(Self.destination(in: window, for: info))
        _ = view.draggingEntered(info)
        let hover = view.draggingUpdated(info)
        let label = board.dropPreview?.label
        var performed = false
        if view.prepareForDragOperation(info) {
            performed = view.performDragOperation(info)
            view.concludeDragOperation(info)
        }
        // The SwiftUI half decodes its item provider asynchronously.
        for _ in 0..<200 where board.notice == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        layout()
        return DropOutcome(
            hover: hover, previewLabel: label, performed: performed,
            notice: board.notice?.message)
    }

    static func pasteboard(_ payload: CanvasBoardDragPayload) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rafu.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(
            try payload.encodedData(),
            forType: NSPasteboard.PasteboardType(UTType.rafuEnsembleDrag.identifier))
        return pasteboard
    }

    static func destination(in window: NSWindow, for info: BoardDraggingInfo) -> NSView? {
        let selector = NSSelectorFromString("_findDragTargetFrom:")
        guard window.responds(to: selector) else { return nil }
        return window.perform(selector, with: info)?.takeUnretainedValue() as? NSView
    }

    /// Whether AppKit routes the Ensemble drag type to a view registered only
    /// for `public.item`, as it must to reach a SwiftUI `.onDrop`.
    static let launchServicesDeclaresEnsembleType: Bool = {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(
            contentRect: frame.offsetBy(dx: -20000, dy: -20000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: frame)
        view.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.item.identifier)])
        window.contentView = view
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rafu.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(
            Data("{}".utf8),
            forType: NSPasteboard.PasteboardType(UTType.rafuEnsembleDrag.identifier))
        let info = BoardDraggingInfo(
            window: window, pasteboard: pasteboard, location: NSPoint(x: 20, y: 20))
        return destination(in: window, for: info) === view
    }()
}

/// A minimal dragging info over a private pasteboard. The underscored
/// methods answer the private calls AppKit's default `NSView` drag
/// implementation makes on its real dragging info.
@MainActor
private final class BoardDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let window: NSWindow
    let pasteboard: NSPasteboard
    var location: NSPoint

    init(window: NSWindow, pasteboard: NSPasteboard, location: NSPoint) {
        self.window = window
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    private var lastOperation: UInt = 0
    @objc func _lastDragDestinationOperation() -> UInt { lastOperation }
    @objc func _setLastDragDestinationOperation(_ operation: UInt) { lastOperation = operation }
    @objc func _lastDragLocation() -> NSPoint { location }
}
