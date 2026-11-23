import AppKit
import Testing

@testable import RafuApp

@MainActor
@Suite("Dock menu")
struct RafuDockMenuTests {
    @Test("The Dock menu starts with New Window, and each item has a target")
    func newWindowFirst() {
        let menu = RafuDockMenu.shared.makeMenu()
        #expect(menu.items.first?.title == "New Window")
        for item in menu.items where !item.isSeparatorItem {
            #expect(item.target === RafuDockMenu.shared)
            #expect(item.action != nil)
        }
    }
}
