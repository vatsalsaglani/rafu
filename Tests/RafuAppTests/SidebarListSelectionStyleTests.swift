import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// Every sidebar list draws the Agent History selection: a quiet `selection`
/// fill drawn by the row, never AppKit's highlight, which is the saturated
/// system accent while the list is first responder in the key window and
/// ignores `.tint` (see `docs/references/sidebar-list-selection-style.md`).
@Suite("Sidebar lists share one quiet selection style")
@MainActor
struct SidebarListSelectionStyleTests {
    @Test("Selection wins over hover; an unselected, unhovered row has no fill")
    func fillRules() {
        for theme in [RafuThemeCatalog.indigo, RafuThemeCatalog.khadi] {
            let palette = theme.palette
            typealias P = RafuRowSelectionPresentation
            #expect(
                P.fill(isSelected: true, isHovering: false, palette: palette) == palette.selection)
            #expect(
                P.fill(isSelected: true, isHovering: true, palette: palette) == palette.selection)
            #expect(P.fill(isSelected: false, isHovering: true, palette: palette) == palette.hover)
            #expect(P.fill(isSelected: false, isHovering: false, palette: palette) == .clear)
        }
    }

    @Test("Increase Contrast adds a hairline to the selected row only")
    func hairlineRules() {
        typealias P = RafuRowSelectionPresentation
        #expect(P.showsHairline(isSelected: true, increasedContrast: true))
        #expect(!P.showsHairline(isSelected: true, increasedContrast: false))
        #expect(!P.showsHairline(isSelected: false, increasedContrast: true))
        #expect(!P.showsHairline(isSelected: false, increasedContrast: false))
    }

    @Test("The suppressor turns the List's native highlight off and keeps its selection")
    func suppressorTurnsNativeHighlightOff() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: SelectionProbeList().frame(width: 240, height: 160))
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        let root = try #require(window.contentView)
        let table = try #require(Self.table(in: root))
        #expect(table.selectionHighlightStyle == .none)
        #expect(table.selectedRowIndexes == IndexSet(integer: 1))
        window.contentView = nil
    }

    @Test("Each sidebar List(selection:) turns the native highlight off and rows draw the fill")
    func sidebarListsUseTheSharedStyle() throws {
        let files = [
            "Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift",
            "Sources/RafuApp/Canvas/Views/CanvasNavigatorPanelView.swift",
            "Sources/RafuApp/Views/GitInspectorView.swift",
            "Sources/RafuApp/Views/GitCommitGraphView.swift",
        ]
        for path in files {
            let source = try Self.source(path)
            #expect(source.contains("List(selection:"), "\(path)")
            #expect(source.contains(".rafuQuietListSelection()"), "\(path)")
            #expect(source.contains(".rafuRowSelection("), "\(path)")
            #expect(!source.contains(".tint(theme.palette.selection)"), "\(path)")
        }
        let saved = try Self.source("Sources/RafuApp/Views/TerminalGroupSavedLayoutsSection.swift")
        #expect(saved.contains(".rafuRowSelection("))
        // The reference style itself uses the same helper.
        let history = try Self.source("Sources/RafuApp/AgentHistory/AgentHistoryPanelView.swift")
        #expect(history.contains(".rafuRowSelection(isSelected: isOpen)"))
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = table(in: subview) { return found }
        }
        return nil
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private struct SelectionProbeList: View {
    @State private var selection: String? = "b"

    var body: some View {
        List(selection: $selection) {
            ForEach(["a", "b", "c"], id: \.self) { item in
                Text(item)
                    .rafuRowSelection(isSelected: selection == item)
                    .tag(item)
            }
        }
        .listStyle(.plain)
        .rafuQuietListSelection()
    }
}
