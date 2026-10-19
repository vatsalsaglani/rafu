import AppKit
import RafuCore
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

/// Regression for "dragging an editor tab to reorder it, or to an editor
/// edge to split, does nothing". The real editor canvas is hosted offscreen
/// and its drop destinations are driven directly with a synthetic
/// `NSDraggingInfo` over a private pasteboard that carries only the private
/// tab payload, which is what SwiftUI's `.onDrag` writes for a `public.item`
/// type (no file promise). No events are posted and no drag session starts.
@Suite("Editor tab drag reorder and split")
@MainActor
struct EditorTabDragDropTests {
    @Test("A tab dropped past its neighbours on the tab strip moves there")
    func tabStripReorder() throws {
        let fixture = try TabDragFixture()
        defer { fixture.remove() }
        let tabA = try fixture.tabs()[0]
        fixture.beginTabDrag(tabA)

        // Window coordinates (bottom-left origin): the strip is the top row.
        let performed = try fixture.drop(at: NSPoint(x: 400, y: 480))

        #expect(performed)
        #expect(try fixture.titles() == ["b.swift", "c.swift", "a.swift"])
    }

    @Test("A tab dropped on the trailing edge of the editor text splits the group")
    func trailingEdgeSplit() throws {
        let fixture = try TabDragFixture()
        defer { fixture.remove() }
        let tabA = try fixture.tabs()[0]
        fixture.beginTabDrag(tabA)

        // Inside the trailing 100 pt band, over the text view.
        let performed = try fixture.drop(at: NSPoint(x: 870, y: 200))

        #expect(performed)
        let layout = fixture.session.editorLayout
        #expect(layout.groupIDs.count == 2)
        #expect(layout.group(containing: tabA)?.tabs.map(\.id) == [tabA])
    }

    @Test("Pure decision: the insertion index past two midpoints reorders to the end")
    func pureReorderDecision() throws {
        let fixture = try TabDragFixture()
        defer { fixture.remove() }
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 28),
            CGRect(x: 104, y: 0, width: 100, height: 28),
            CGRect(x: 208, y: 0, width: 100, height: 28),
        ]
        let index = TabStripDrop.insertionIndex(forX: 260, tabFrames: frames)
        #expect(index == 3)
        let tabs = try fixture.tabs()
        fixture.session.reorderOrMoveEditorTab(
            tabs[0], to: fixture.session.editorLayout.focusedGroupID, atInsertionIndex: index)
        #expect(try fixture.titles() == ["b.swift", "c.swift", "a.swift"])
    }

    @Test("Pure decision: a tab dropped in the trailing band splits; the centre does not")
    func pureSplitDecision() throws {
        let size = CGSize(width: 900, height: 436)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 870, y: 200), in: size) == .trailing)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 450, y: 200), in: size) == nil)

        let fixture = try TabDragFixture()
        defer { fixture.remove() }
        let tabs = try fixture.tabs()
        let groupID = fixture.session.editorLayout.focusedGroupID
        fixture.session.handleEditorTabDrop(
            tabs[1].rawValue.uuidString, on: groupID, edge: .trailing)
        #expect(fixture.session.editorLayout.groupIDs.count == 2)
    }
}

@MainActor
private final class TabDragFixture {
    let directory: URL
    let session = WorkspaceSession()
    let window: NSWindow
    private var pasteboard: NSPasteboard?

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-tab-drag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session.descriptor = WorkspaceDescriptor(
            displayName: "TabDrag", location: .local(LocalWorkspaceReference(path: directory.path)))
        for name in ["a.swift", "b.swift", "c.swift"] {
            let url = directory.appending(path: name)
            try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
            session.open(WorkspaceFileNode(url: url, relativePath: name, isDirectory: false))
        }
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: EditorCanvasView(session: session, openFolder: {})
                .frame(width: 900, height: 500))
        // Several passes: the tab frames arrive through a preference, which
        // updates state that the strip's drop delegate reads.
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func tabs() throws -> [EditorTabID] {
        try #require(session.editorLayout.group(id: session.editorLayout.focusedGroupID))
            .tabs.map(\.id)
    }

    func titles() throws -> [String] {
        try #require(session.editorLayout.group(id: session.editorLayout.focusedGroupID))
            .tabs.map { session.document(for: $0)?.displayName ?? "?" }
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
        self.pasteboard = pasteboard
    }

    /// Routes like AppKit (the deepest registered view under the point) and
    /// runs one enter, update, prepare, perform, conclude sequence.
    func drop(at point: NSPoint) throws -> Bool {
        let pasteboard = try #require(pasteboard)
        let root = try #require(window.contentView)
        let destination = try #require(Self.deepestRegistered(at: point, in: root))
        let info = SyntheticDraggingInfo(window: window, pasteboard: pasteboard, location: point)
        guard !destination.draggingEntered(info).isEmpty,
            !destination.draggingUpdated(info).isEmpty,
            destination.prepareForDragOperation(info)
        else { return false }
        let performed = destination.performDragOperation(info)
        destination.concludeDragOperation(info)
        return performed
    }

    private static func deepestRegistered(at point: NSPoint, in view: NSView) -> NSView? {
        guard !view.isHidden, view.bounds.contains(view.convert(point, from: nil)) else {
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
private final class SyntheticDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let window: NSWindow
    let pasteboard: NSPasteboard
    let location: NSPoint

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
