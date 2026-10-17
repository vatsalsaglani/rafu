import AppKit
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Editor guard banner visibility")
@MainActor
struct EditorGuardBannerVisibilityTests {
    @Test("An inactive retained editor has no guard banner content")
    func inactiveGuardLeavesRenderedTree() {
        _ = NSApplication.shared
        let document = EditorDocument(untitledNumber: 1)
        let visible = NSHostingView(
            rootView: GuardBannerView(document: document, isVisible: true)
                .frame(width: 600))
        let inactive = NSHostingView(
            rootView: GuardBannerView(document: document, isVisible: false)
                .frame(width: 600))
        visible.layoutSubtreeIfNeeded()
        inactive.layoutSubtreeIfNeeded()
        #expect(visible.fittingSize.height == 32)
        #expect(inactive.fittingSize.height == 0)
    }
}
