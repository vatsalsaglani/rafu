import AppKit
import RafuCore
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

/// Regression for "reorder by dragging a tab is inconsistent": a release on
/// the tab shelf's breathing room or trailing controls did nothing, because
/// only the 28 pt scrolling tab row was a drop target. The real editor canvas
/// is hosted offscreen, and AppKit's own drag-target lookup
/// (`-[NSWindow _findDragTargetFrom:]`, the call the drag manager makes for
/// each drag event) picks the destination for a synthetic `NSDraggingInfo`.
/// No events are posted and no drag session starts.
@Suite("Editor tab strip drop routing and insertion index")
@MainActor
struct EditorTabStripDropRoutingTests {
    // MARK: Pure insertion math

    @Test("Insertion resolves against tab midpoints including inset and spacing")
    func insertionMidpoints() {
        let ids = ["a", "b", "c"]
        // 8 pt leading inset, 100 pt tabs, 4 pt spacing.
        let frames: [String: CGRect] = [
            "a": CGRect(x: 8, y: 6, width: 100, height: 28),
            "b": CGRect(x: 112, y: 6, width: 100, height: 28),
            "c": CGRect(x: 216, y: 6, width: 100, height: 28),
        ]
        func resolve(_ x: CGFloat) -> TabStripInsertion {
            TabStripDrop.insertion(atX: x, orderedIDs: ids, frames: frames)
        }
        #expect(resolve(0) == TabStripInsertion(index: 0, indicatorX: 8))
        #expect(resolve(57) == TabStripInsertion(index: 0, indicatorX: 8))
        #expect(resolve(59) == TabStripInsertion(index: 1, indicatorX: 110))
        #expect(resolve(110) == TabStripInsertion(index: 1, indicatorX: 110))
        #expect(resolve(163) == TabStripInsertion(index: 2, indicatorX: 214))
        #expect(resolve(267) == TabStripInsertion(index: 3, indicatorX: 316))
        #expect(resolve(900) == TabStripInsertion(index: 3, indicatorX: 316))
    }

    @Test("Insertion uses the scrolled frames, not content offsets")
    func insertionScrolled() {
        let ids = (0..<6).map { "t\($0)" }
        // Scrolled by 250 pt: frames are in the drop target's (shelf) space.
        var frames: [String: CGRect] = [:]
        for (index, id) in ids.enumerated() {
            frames[id] = CGRect(x: CGFloat(index) * 104 - 250, y: 6, width: 100, height: 28)
        }
        // t2 spans -42...58 (mid 8); t3 spans 62...162 (mid 112).
        #expect(TabStripDrop.insertion(atX: 5, orderedIDs: ids, frames: frames).index == 2)
        #expect(TabStripDrop.insertion(atX: 10, orderedIDs: ids, frames: frames).index == 3)
        #expect(TabStripDrop.insertion(atX: 120, orderedIDs: ids, frames: frames).index == 4)
    }

    @Test("A tab with no rendered frame keeps its slot in the full tab order")
    func insertionSkipsUnframedTabs() {
        let ids = ["a", "b", "c", "d"]
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 28),
            "c": CGRect(x: 104, y: 0, width: 100, height: 28),
            "d": CGRect(x: 208, y: 0, width: 100, height: 28),
        ]
        let insertion = TabStripDrop.insertion(atX: 80, orderedIDs: ids, frames: frames)
        // Before "c" is index 2 in the group's order. Counting rendered
        // frames alone says 1, which would land the tab before "b".
        #expect(insertion == TabStripInsertion(index: 2, indicatorX: 102))
        #expect(
            TabStripDrop.insertionIndex(forX: 80, tabFrames: [frames["a"]!, frames["c"]!]) == 1)
    }

    @Test("An empty or unlaid strip appends and draws no bar")
    func insertionEmpty() {
        #expect(
            TabStripDrop.insertion(atX: 40, orderedIDs: [String](), frames: [:])
                == TabStripInsertion(index: 0, indicatorX: nil))
        #expect(
            TabStripDrop.insertion(atX: 40, orderedIDs: ["a", "b"], frames: [:])
                == TabStripInsertion(index: 2, indicatorX: nil))
    }

    @Test("Sweeping across the strip never moves the index backwards")
    func insertionMonotonic() {
        let ids = (0..<5).map { "t\($0)" }
        var frames: [String: CGRect] = [:]
        for (index, id) in ids.enumerated() {
            frames[id] = CGRect(x: 6 + CGFloat(index) * 97, y: 0, width: 93, height: 28)
        }
        var last = 0
        for x in stride(from: -20.0, through: 600, by: 0.5) {
            let index = TabStripDrop.insertion(atX: x, orderedIDs: ids, frames: frames).index
            #expect(index >= last)
            last = index
        }
        #expect(last == ids.count)
    }

    // MARK: Hosted routing

    @Test("Every point of the tab shelf routes to the strip; the text routes to the editor")
    func shelfRouting() throws {
        let fixture = try StripDropFixture(tabCount: 3)
        defer { fixture.remove() }
        let strip = try fixture.stripRow()
        let shelfTop = strip.maxY + RafuMetrics.tabShelfBreathingRoom
        let shelfBottom = strip.minY - RafuMetrics.tabShelfBreathingRoom
        let width = fixture.window.frame.width
        let shelfPoints = [
            NSPoint(x: 2, y: strip.midY),  // leading edge
            NSPoint(x: 300, y: strip.midY),  // over the tabs
            NSPoint(x: 600, y: strip.midY),  // empty bar past the last tab
            NSPoint(x: width - 10, y: strip.midY),  // trailing controls
            NSPoint(x: 200, y: shelfTop - 1),  // top breathing room
            NSPoint(x: 200, y: strip.maxY + 2),
            NSPoint(x: 200, y: strip.minY - 2),  // bottom breathing room
            NSPoint(x: 200, y: shelfBottom + 1),
            NSPoint(x: width - 10, y: shelfBottom + 1),
        ]
        for point in shelfPoints {
            #expect(fixture.target(at: point) == .strip, "shelf point \(point)")
        }
        #expect(fixture.target(at: NSPoint(x: 450, y: 200)) == .editor)
        #expect(fixture.target(at: NSPoint(x: 870, y: 40)) == .editor)
    }

    @Test("Moving from the shelf into the text never flaps between targets")
    func boundaryDoesNotFlap() throws {
        let fixture = try StripDropFixture(tabCount: 3)
        defer { fixture.remove() }
        for x in [3.0, 250, 600, 890] {
            var segments: [StripDropFixture.Target] = []
            for y in stride(from: fixture.window.frame.height - 0.5, through: 300, by: -1) {
                let target = fixture.target(at: NSPoint(x: x, y: y))
                if segments.last != target { segments.append(target) }
            }
            #expect(segments == [.strip, .groupBody, .editor], "column x=\(x)")
        }
    }

    @Test("A release on the shelf's breathing room or controls still reorders")
    func deadZonesReorder() throws {
        let fixture = try StripDropFixture(tabCount: 3)
        defer { fixture.remove() }
        let strip = try fixture.stripRow()
        let tabs = try fixture.tabs()

        // Last tab released in the top breathing room at the leading edge.
        fixture.beginTabDrag(tabs[2])
        #expect(try fixture.drop(at: NSPoint(x: 2, y: strip.maxY + 3)) == .strip)
        #expect(try fixture.tabs() == [tabs[2], tabs[0], tabs[1]])

        // First tab (now tabs[2]) released on the trailing controls appends.
        fixture.beginTabDrag(tabs[2])
        let controls = NSPoint(x: fixture.window.frame.width - 10, y: strip.minY - 3)
        #expect(try fixture.drop(at: controls) == .strip)
        #expect(try fixture.tabs() == [tabs[0], tabs[1], tabs[2]])
    }

    @Test("Each tab half resolves to the slot before or after that tab")
    func tabHalvesResolve() throws {
        let fixture = try StripDropFixture(tabCount: 12)
        defer { fixture.remove() }
        // The strip opens scrolled to reveal its selected (last) tab; the
        // slots below are measured from the leading edge.
        try fixture.scrollStrip(by: 0)
        try verifyHalves(fixture, slots: [1, 4, 6])
    }

    @Test("A scrolled strip resolves slots against the scrolled tabs")
    func scrolledStripResolves() throws {
        let fixture = try StripDropFixture(tabCount: 12)
        defer { fixture.remove() }
        try fixture.scrollStrip(by: 400)
        let layout = try fixture.tabLayout()
        #expect(layout.firstMinX < -300, "the strip did not scroll: \(layout.firstMinX)")
        let visible = (0..<12).filter { layout.center($0) > 20 && layout.center($0) < 780 }
        try #require(visible.count >= 3)
        try verifyHalves(fixture, slots: Array(visible.prefix(3)))
    }

    @Test("A drop after hover flaps between the editor and the strip still reorders")
    func dropAfterFlap() throws {
        let fixture = try StripDropFixture(tabCount: 3)
        defer { fixture.remove() }
        let strip = try fixture.stripRow()
        let tabs = try fixture.tabs()
        fixture.beginTabDrag(tabs[0])
        try fixture.hover(at: NSPoint(x: 300, y: strip.midY))
        try fixture.hover(at: NSPoint(x: 300, y: 300))
        try fixture.hover(at: NSPoint(x: 300, y: strip.minY - 2))
        try fixture.hover(at: NSPoint(x: 300, y: 200))
        #expect(try fixture.drop(at: NSPoint(x: 880, y: strip.maxY + 2)) == .strip)
        #expect(try fixture.tabs() == [tabs[1], tabs[2], tabs[0]])
    }

    @Test("A tab released in the centre of its own group's text is selected")
    func editorCentreSelects() throws {
        let fixture = try StripDropFixture(tabCount: 3)
        defer { fixture.remove() }
        let tabs = try fixture.tabs()
        let groupID = fixture.session.editorLayout.focusedGroupID
        #expect(fixture.session.editorLayout.group(id: groupID)?.selectedTabID == tabs[2])
        fixture.beginTabDrag(tabs[0])
        #expect(try fixture.drop(at: NSPoint(x: 450, y: 200)) == .editor)
        #expect(fixture.session.editorLayout.group(id: groupID)?.selectedTabID == tabs[0])
        #expect(try fixture.tabs() == tabs)
    }

    /// For each slot `k`, a release on the left half of tab `k` inserts
    /// before it and a release on its right half inserts after it.
    private func verifyHalves(_ fixture: StripDropFixture, slots: [Int]) throws {
        let row = try fixture.stripRow()
        for slot in slots {
            for (offset, insertion) in [(-0.25, slot), (0.25, slot + 1)] {
                let original = try fixture.tabs()
                let layout = try fixture.tabLayout()
                // Drag a tab that is not adjacent to the slot.
                let source = slot < 6 ? original.count - 1 : 0
                fixture.beginTabDrag(original[source])
                let x = layout.center(slot) + offset * layout.width
                let outcome = try fixture.drop(at: NSPoint(x: x, y: row.midY))
                #expect(outcome == .strip)
                var expected = original
                let moved = expected.remove(at: source)
                expected.insert(moved, at: insertion > source ? insertion - 1 : insertion)
                #expect(
                    try fixture.tabs() == expected,
                    "slot \(slot) offset \(offset): x=\(x) layout=\(layout)")
                // Put the tab back so every case starts from the same order.
                fixture.session.reorderOrMoveEditorTab(
                    moved, to: fixture.session.editorLayout.focusedGroupID,
                    atInsertionIndex: source > insertion ? source + 1 : source)
                #expect(try fixture.tabs() == original)
                fixture.layout()
            }
        }
    }
}

@MainActor
private final class StripDropFixture {
    enum Target: Equatable {
        case strip, groupBody, editor, none, other
    }

    /// Equal-width tabs: every file has the same name, so the strip's tab
    /// frames follow from the row's content width alone.
    struct TabLayout: CustomStringConvertible {
        let firstMinX: CGFloat
        let width: CGFloat
        let spacing: CGFloat

        func center(_ index: Int) -> CGFloat {
            firstMinX + CGFloat(index) * (width + spacing) + width / 2
        }

        var description: String { "first=\(firstMinX) width=\(width)" }
    }

    let directory: URL
    let session = WorkspaceSession()
    let window: NSWindow
    private let tabCount: Int
    /// The one dragging info of the current drag; each event moves it.
    private var dragInfo: StripDraggingInfo?
    private var hovered: NSView?

    init(tabCount: Int) throws {
        _ = NSApplication.shared
        self.tabCount = tabCount
        directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-strip-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session.descriptor = WorkspaceDescriptor(
            displayName: "StripDrop",
            location: .local(LocalWorkspaceReference(path: directory.path)))
        for index in 0..<tabCount {
            let folder = directory.appending(path: "d\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "tab.swift")
            try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
            session.open(
                WorkspaceFileNode(url: url, relativePath: "d\(index)/tab.swift", isDirectory: false)
            )
        }
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: EditorCanvasView(session: session, openFolder: {})
                .frame(width: 900, height: 500))
        layout()
    }

    /// Several passes: the tab frames arrive through a preference.
    func layout() {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func tabs() throws -> [EditorTabID] {
        try #require(session.editorLayout.group(id: session.editorLayout.focusedGroupID))
            .tabs.map(\.id)
    }

    /// The horizontal scroll view that hosts the tab row.
    private func stripScrollView() throws -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, !(scroll is EditorDropForwardingScrollView),
                scroll.frame.height < 60
            {
                return scroll
            }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        let root = try #require(window.contentView)
        return try #require(find(root))
    }

    /// The visible tab row in window coordinates.
    func stripRow() throws -> NSRect {
        let scroll = try stripScrollView()
        return scroll.convert(scroll.bounds, to: nil)
    }

    func tabLayout() throws -> TabLayout {
        let scroll = try stripScrollView()
        let document = try #require(scroll.documentView)
        let content = document.convert(document.bounds, to: nil)
        let spacing = RafuMetrics.space1
        let width = (content.width - CGFloat(tabCount - 1) * spacing) / CGFloat(tabCount)
        try #require(content.width > scroll.frame.width, "the row must overflow the strip")
        return TabLayout(firstMinX: content.minX, width: width, spacing: spacing)
    }

    func scrollStrip(by offset: CGFloat) throws {
        let scroll = try stripScrollView()
        scroll.contentView.scroll(to: NSPoint(x: offset, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        layout()
    }

    /// What a tab's `.onDrag` closure does, plus the pasteboard the drag
    /// session carries for a `public.item` private type.
    func beginTabDrag(_ tab: EditorTabID) {
        let payload = EditorDragPayload.tab(id: tab.rawValue.uuidString)
        _ = session.beginEditorDrag(payload)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rafu.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(
            try? payload.encodedData(),
            forType: NSPasteboard.PasteboardType(UTType.rafuEditorDrag.identifier))
        dragInfo = StripDraggingInfo(window: window, pasteboard: pasteboard, location: .zero)
        hovered = nil
    }

    /// A routing query outside any drag: a fresh info over a payload-only
    /// pasteboard.
    private func probeInfo(at point: NSPoint) -> StripDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rafu.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(
            Data("{}".utf8),
            forType: NSPasteboard.PasteboardType(UTType.rafuEditorDrag.identifier))
        return StripDraggingInfo(window: window, pasteboard: pasteboard, location: point)
    }

    /// AppKit's own destination lookup for a drag event at `info.location`.
    private func destination(for info: StripDraggingInfo) -> NSView? {
        let selector = NSSelectorFromString("_findDragTargetFrom:")
        guard window.responds(to: selector) else {
            return Self.deepestRegistered(at: info.location, in: window.contentView)
        }
        return window.perform(selector, with: info)?.takeUnretainedValue() as? NSView
    }

    func target(at point: NSPoint) -> Target {
        classify(destination(for: probeInfo(at: point)))
    }

    private func classify(_ view: NSView?) -> Target {
        guard let view else { return .none }
        if view is EditorDropForwardingScrollView || view is RafuTextView { return .editor }
        let name = String(describing: type(of: view))
        guard name.contains("PlatformDraggingDestinationView") else { return .other }
        // The shelf is about 40 pt tall; the group body fills the rest.
        return view.frame.height < 80 ? .strip : .groupBody
    }

    /// One drag event: exits the previous destination when it changed, then
    /// enters (or updates) the one under `point`, like the drag manager.
    func hover(at point: NSPoint) throws {
        let info = try #require(dragInfo, "beginTabDrag first")
        info.location = point
        let view = destination(for: info)
        if view !== hovered {
            hovered?.draggingExited(info)
            hovered = view
            _ = view?.draggingEntered(info)
        }
        _ = view?.draggingUpdated(info)
    }

    /// Hovers, then runs prepare, perform, and conclude on the destination.
    /// Returns which target performed the drop, or `.none` when nothing did.
    func drop(at point: NSPoint) throws -> Target {
        try hover(at: point)
        let info = try #require(dragInfo)
        guard let view = hovered, view.prepareForDragOperation(info),
            view.performDragOperation(info)
        else { return .none }
        view.concludeDragOperation(info)
        hovered = nil
        layout()
        return classify(view)
    }

    private static func deepestRegistered(at point: NSPoint, in view: NSView?) -> NSView? {
        guard let view, !view.isHidden, view.bounds.contains(view.convert(point, from: nil)) else {
            return nil
        }
        for subview in view.subviews.reversed() {
            if let hit = deepestRegistered(at: point, in: subview) { return hit }
        }
        return view.registeredDraggedTypes.isEmpty ? nil : view
    }

    func remove() {
        session.terminal.shutdownAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A minimal dragging info over a private pasteboard. The underscored
/// methods answer the private calls AppKit's default `NSView` drag
/// implementation makes on its real dragging info.
@MainActor
private final class StripDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
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
