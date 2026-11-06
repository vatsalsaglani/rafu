import Testing

@testable import RafuApp

@Suite("Dock attention badge")
struct DockAttentionBadgeTests {
    @Test("No badge at zero; needs you and failed add up")
    func label() {
        #expect(DockAttentionBadgeLabel.label(needsYou: 0, failed: 0) == nil)
        #expect(DockAttentionBadgeLabel.label(needsYou: 2, failed: 1) == "3")
        #expect(DockAttentionBadgeLabel.label(needsYou: 0, failed: 1) == "1")
    }

    @Test("The badge caps at 99+")
    func cap() {
        #expect(DockAttentionBadgeLabel.label(needsYou: 99, failed: 0) == "99")
        #expect(DockAttentionBadgeLabel.label(needsYou: 60, failed: 40) == "99+")
    }
}
