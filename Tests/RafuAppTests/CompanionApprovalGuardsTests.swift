import Foundation
import Testing

@testable import RafuApp

/// A clock the test moves by hand.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@MainActor
@Suite("Up next approval guards")
struct CompanionApprovalGuardsTests {
    @Test("Clicks are ignored for half a second after the rows change")
    func clickGuardQuietInterval() {
        let clock = TestClock()
        var guardian = ApprovalClickGuard(now: { clock.now })
        #expect(guardian.allowsClick)
        let first = UUID()
        let second = UUID()
        // A new request appears.
        guardian.noteRows([first])
        #expect(!guardian.allowsClick)
        clock.advance(0.49)
        #expect(!guardian.allowsClick)
        clock.advance(0.01)
        #expect(guardian.allowsClick)
        // The same rows again do not restart the interval.
        guardian.noteRows([first])
        #expect(guardian.allowsClick)
        // The first request closes and the next moves into its place.
        guardian.noteRows([second])
        #expect(!guardian.allowsClick)
        clock.advance(ApprovalClickGuard.quietInterval)
        #expect(guardian.allowsClick)
        // A change of order counts too.
        guardian.noteRows([first, second])
        clock.advance(0.6)
        guardian.noteRows([second, first])
        #expect(!guardian.allowsClick)
    }

    @Test("The panel takes key status only after the person interacts with the rows")
    func keyEngagement() {
        var engagement = ApprovalKeyEngagement()
        // An interaction before any row is visible does not count.
        engagement.noteInteraction()
        #expect(!engagement.wantsKey)
        // A request arrives on a pinned panel: no key status yet.
        engagement.setRowsVisible(true)
        #expect(!engagement.wantsKey)
        engagement.noteInteraction()
        #expect(engagement.wantsKey)
        // The panel lost key status (the person clicked a terminal).
        engagement.endInteraction()
        #expect(!engagement.wantsKey)
        #expect(engagement.rowsVisible)
        engagement.noteInteraction()
        #expect(engagement.wantsKey)
        // The rows leave: the next request starts without key status.
        engagement.setRowsVisible(false)
        engagement.setRowsVisible(true)
        #expect(!engagement.wantsKey)
    }
}
