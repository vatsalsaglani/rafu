import Foundation
import Testing

@testable import RafuApp

@Suite("Drag source ghost token lifecycle")
struct RafuDragSourceLifecycleTests {
    @Test("begin sets the token")
    func beginSets() {
        let token = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.begin(token) == token)
    }

    @Test("end clears only when the token is still the in-flight one")
    func endClears() {
        let token = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.end(token, clearing: token) == nil)
    }

    @Test("end is a no-op for a drag already superseded by a newer token")
    func endIsNoOpWhenSuperseded() {
        let old = RafuDragSourceToken()
        let newer = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.end(old, clearing: newer) == newer)
    }

    @Test("cancel clears the same way as end")
    func cancelClears() {
        let token = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.cancel(token, clearing: token) == nil)
    }

    @Test("cancel is a no-op for a drag already superseded by a newer token")
    func cancelIsNoOpWhenSuperseded() {
        let old = RafuDragSourceToken()
        let newer = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.cancel(old, clearing: newer) == newer)
    }

    @Test("A second window's in-flight token is independent of the first")
    @MainActor
    func secondWindowIsIndependent() {
        let first = WorkspaceSession()
        let second = WorkspaceSession()
        let firstToken = RafuDragSourceToken()
        let secondToken = RafuDragSourceToken()

        first.dragInFlight = RafuDragSourceLifecycle.begin(firstToken)
        second.dragInFlight = RafuDragSourceLifecycle.begin(secondToken)
        #expect(first.dragInFlight == firstToken)
        #expect(second.dragInFlight == secondToken)

        first.dragInFlight = RafuDragSourceLifecycle.end(firstToken, clearing: first.dragInFlight)
        #expect(first.dragInFlight == nil)
        #expect(second.dragInFlight == secondToken)
    }
}
