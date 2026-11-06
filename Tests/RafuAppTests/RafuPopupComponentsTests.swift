import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// The Rafu popup language (ADR 0033): key hints, row selection, the
/// confirmation default rule, Open Ensemble selection, and the Icon Library's
/// memory bounds.
@Suite("Rafu popup components")
@MainActor
struct RafuPopupComponentsTests {
    @Test("Key hints use the macOS modifier order")
    func keyHintFormat() {
        #expect(
            RafuKeyHint.text(for: KeyboardShortcut("k", modifiers: [.command, .shift])) == "⇧⌘K")
        #expect(RafuKeyHint.text(for: KeyboardShortcut("f", modifiers: .command)) == "⌘F")
        #expect(
            RafuKeyHint.text(for: KeyboardShortcut("1", modifiers: [.control, .option])) == "⌃⌥1")
        #expect(RafuKeyHint.text(for: KeyboardShortcut(.return, modifiers: [])) == "↩")
        #expect(RafuKeyHint.text(for: KeyboardShortcut(.escape, modifiers: [])) == "esc")
    }

    @Test("A row's leading view replaces the symbol; existing rows keep the symbol")
    func rowLeadingSlot() throws {
        let plain = RafuPopupRow(symbol: "doc", title: "Plain", isSelected: false)
        #expect(plain.leading == nil)
        let outlined = RafuPopupRow(
            symbol: "doc", title: "Outlined", isSelected: false,
            leading: AnyView(CanvasBoardSilhouetteView(silhouette: .empty)))
        #expect(outlined.leading != nil)
        let source = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Support/RafuPopupComponents.swift")
        let row = try #require(source.range(of: "struct RafuPopupRow: View"))
        let rowSource = String(source[row.upperBound...])
        let leading = try #require(rowSource.range(of: "if let leading {"))
        let symbol = try #require(rowSource.range(of: "Image(systemName: symbol)"))
        #expect(leading.lowerBound < symbol.lowerBound)
        let dialogs = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Canvas/Views/CanvasDialogView.swift")
        #expect(dialogs.contains("CanvasBoardSilhouetteView(silhouette: item.silhouette)"))
        let silhouette = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Canvas/Views/CanvasBoardSilhouetteView.swift")
        #expect(!silhouette.contains(".shadow("))
    }

    @Test("A selected row carries the isSelected trait, not only a colour")
    func rowSelectionTrait() {
        #expect(RafuPopupRow.accessibilityTraits(isSelected: true).contains(.isSelected))
        #expect(!RafuPopupRow.accessibilityTraits(isSelected: false).contains(.isSelected))
    }

    @Test("Return never destroys: a destructive action is never the default")
    func confirmDefaultAction() {
        let delete = RafuConfirmPopup.Action("Delete", isDestructive: true) {}
        let create = RafuConfirmPopup.Action("Create") {}
        #expect(RafuConfirmPopup.defaultActionIndex([delete], preferred: nil) == nil)
        #expect(RafuConfirmPopup.defaultActionIndex([delete], preferred: "Delete") == nil)
        #expect(RafuConfirmPopup.defaultActionIndex([delete, create], preferred: "Create") == 1)
        #expect(RafuConfirmPopup.defaultActionIndex([create], preferred: nil) == nil)
    }

    @Test("The confirmation source gives Cancel the default action and Escape")
    func confirmSourceContract() throws {
        let source = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Support/RafuPopupComponents.swift")
        let start = try #require(source.range(of: "struct RafuConfirmPopup: View"))
        let end = try #require(
            source.range(
                of: "struct RafuDestructiveButtonStyle", range: start.upperBound..<source.endIndex))
        let popup = String(source[start.upperBound..<end.lowerBound])
        #expect(popup.contains("cancelButton(isDefault: defaultIndex == nil)"))
        #expect(popup.contains(".onExitCommand(perform: cancel)"))
        #expect(popup.contains("Self.footerOrder(actions)"))
        // The destructive branch has no keyboard shortcut.
        let destructive = try #require(popup.range(of: "if action.isDestructive {"))
        let next = try #require(
            popup.range(of: "} else if isDefault {", range: destructive.upperBound..<popup.endIndex)
        )
        #expect(!popup[destructive.upperBound..<next.lowerBound].contains(".keyboardShortcut("))
        // No shadow and no blur in the popup language.
        #expect(!source.contains(".shadow("))
        #expect(!source.contains("Material"))
        // The message popup has exactly one default action; Escape closes it.
        let messageStart = try #require(source.range(of: "struct RafuMessagePopup: View"))
        let messageEnd = try #require(
            source.range(
                of: "struct RafuTextFieldPopup: View",
                range: messageStart.upperBound..<source.endIndex
            ))
        let message = String(source[messageStart.upperBound..<messageEnd.lowerBound])
        #expect(message.components(separatedBy: ".keyboardShortcut(.defaultAction)").count == 2)
        #expect(message.contains(".keyboardShortcut(.cancelAction)"))
        #expect(message.contains(".onExitCommand(perform: dismiss)"))
    }

    @Test("The footer puts destructive actions left of Cancel and the others right")
    func footerOrder() {
        let discard = RafuConfirmPopup.Action("Discard", isDestructive: true) {}
        let remove = RafuConfirmPopup.Action("Remove", isDestructive: true) {}
        let save = RafuConfirmPopup.Action("Save and Close") {}
        let other = RafuConfirmPopup.Action("Other") {}
        let mixed = RafuConfirmPopup.footerOrder([save, discard, other, remove])
        #expect(mixed.leading.map(\.id) == ["Discard", "Remove"])
        #expect(mixed.trailing.map(\.id) == ["Save and Close", "Other"])
        #expect(RafuConfirmPopup.footerOrder([save, other]).leading.isEmpty)
        #expect(RafuConfirmPopup.footerOrder([discard]).trailing.isEmpty)
    }

    @Test("The close prompt makes Save and Close the Return action, never Discard")
    func closePromptDefault() {
        let save = RafuConfirmPopup.Action("Save and Close") {}
        let discard = RafuConfirmPopup.Action("Discard", isDestructive: true) {}
        #expect(
            RafuConfirmPopup.defaultActionIndex([save, discard], preferred: "Save and Close") == 0)
        #expect(RafuConfirmPopup.defaultActionIndex([save, discard], preferred: "Discard") == nil)
    }

    @Test("Message popups pick a symbol per kind")
    func messagePopupSymbols() {
        #expect(RafuMessagePopup.symbol(for: .error) == "exclamationmark.triangle")
        #expect(RafuMessagePopup.symbol(for: .info) == "info.circle")
    }

    @Test("A text popup submits only a non-empty, valid, trimmed value")
    func textFieldCanSubmit() {
        let any: (String) -> String? = { _ in nil }
        let noSlash: (String) -> String? = { $0.contains("/") ? "No slashes." : nil }
        #expect(!RafuTextFieldPopup.canSubmit("", validate: any))
        #expect(!RafuTextFieldPopup.canSubmit("   \n", validate: any))
        #expect(!RafuTextFieldPopup.canSubmit("a/b", validate: noSlash))
        #expect(RafuTextFieldPopup.canSubmit(" ok ", validate: noSlash))
        #expect(RafuTextFieldPopup.problem("a/b", validate: noSlash) == "No slashes.")
        #expect(RafuTextFieldPopup.problem("  ", validate: noSlash) == nil)
    }

    @Test("Increase Contrast shows the full border")
    func borderOpacity() {
        #expect(RafuPopupStyle.borderOpacity(increaseContrast: false) == 0.5)
        #expect(RafuPopupStyle.borderOpacity(increaseContrast: true) == 1)
    }

    @Test("Open Ensemble selects the first row, keeps a listed selection, and moves within bounds")
    func librarySelection() {
        let a = CanvasSummary(id: CanvasID(rawValue: UUID()), title: "Alpha", revision: 1)
        let b = CanvasSummary(id: CanvasID(rawValue: UUID()), title: "Beta", revision: 1)
        let c = CanvasSummary(id: CanvasID(rawValue: UUID()), title: "Release notes", revision: 1)
        let items = [a, b, c]
        #expect(CanvasLibrarySelection.initial(items: items, previous: nil) == a.id)
        #expect(CanvasLibrarySelection.initial(items: items, previous: b.id) == b.id)
        #expect(CanvasLibrarySelection.initial(items: [a, c], previous: b.id) == a.id)
        #expect(CanvasLibrarySelection.initial(items: [], previous: b.id) == nil)
        #expect(CanvasLibrarySelection.move(a.id, by: 1, in: items) == b.id)
        #expect(CanvasLibrarySelection.move(c.id, by: 1, in: items) == c.id)
        #expect(CanvasLibrarySelection.move(a.id, by: -1, in: items) == a.id)
        #expect(CanvasLibrarySelection.move(nil, by: 1, in: []) == nil)
        #expect(CanvasLibrarySelection.filter(items, query: " rel ") == [c])
        #expect(CanvasLibrarySelection.filter(items, query: "") == items)
        #expect(CanvasLibrarySelection.subtitle(count: 3) == "3 saved in this workspace")
    }

    @Test("Icon Library arrow keys stay inside the grid")
    func iconLibraryNavigation() {
        typealias Nav = CanvasIconLibraryNavigation
        // Five columns (UX Round C).
        #expect(Nav.move(0, .left, count: 10) == 0)
        #expect(Nav.move(0, .right, count: 10) == 1)
        #expect(Nav.move(1, .down, count: 10) == 6)
        #expect(Nav.move(4, .down, count: 10) == 9)
        #expect(Nav.move(7, .down, count: 10) == 7)
        #expect(Nav.move(5, .up, count: 10) == 0)
        #expect(Nav.move(2, .up, count: 10) == 2)
        #expect(Nav.move(9, .right, count: 10) == 9)
        #expect(Nav.move(3, .down, count: 0) == 0)
    }

    @Test("The decoded-icon cache is bounded by count and cost")
    func iconCacheLimits() {
        let library = CanvasIconPackLibrary(
            directory: FileManager.default.temporaryDirectory.appending(
                path: "rafu-icon-cache-\(UUID().uuidString)"))
        #expect(library.imageCacheLimits.count == 300)
        #expect(library.imageCacheLimits.cost == 16 * 1024 * 1024)
        #expect(
            CanvasIconPackLibrary.cacheCost(pixelsWide: 64, pixelsHigh: 32, pointSize: .zero)
                == 64 * 32 * 4)
        // A vector image has no pixels: its point size at 2x.
        #expect(
            CanvasIconPackLibrary.cacheCost(
                pixelsWide: 0, pixelsHigh: 0, pointSize: CGSize(width: 10, height: 10))
                == 20 * 20 * 4)
    }

    @Test("Closing the Icon Library panel releases it")
    func libraryPanelReleasedOnClose() {
        let holder = CanvasLibraryPanelHolder()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        holder.install(panel)
        #expect(holder.isLoaded)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: panel)
        #expect(!holder.isLoaded)
        // A second close notice is harmless.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: panel)
        #expect(!holder.isLoaded)
        #expect(!CanvasDiagramPanels.libraryPanelIsLoaded)
    }
}
