import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Ensemble event center")
struct EnsembleEventCenterTests {
    @Test("Published cursors are monotonic and eventsSince is exclusive")
    func monotonicCursorAndEventsSince() async {
        let center = makeCenter()
        let stream = center.subscribe()
        var iterator = stream.makeAsyncIterator()

        center.publish(event(runID: "a"))
        center.publish(event(runID: "b"))

        #expect(await iterator.next()?.cursor == 1)
        #expect(await iterator.next()?.cursor == 2)
        #expect(center.eventsSince(1).map(\.runID) == ["b"])
        center.finishSubscriptionsForTesting()
    }

    @Test("The ring retains only the newest 512 events")
    func ringEviction() {
        let center = makeCenter()
        for index in 0...ConductorEnsembleEventCenter.ringCapacity {
            center.publish(event(runID: "run-\(index)"))
        }

        let retained = center.eventsSince(0)
        #expect(retained.count == ConductorEnsembleEventCenter.ringCapacity)
        #expect(retained.first?.cursor == 2)
        #expect(retained.last?.cursor == 513)
    }

    @Test("A stalled subscriber drops oldest values beyond its 64-event buffer")
    func boundedSubscriberDropsOldest() async {
        let center = makeCenter()
        let stream = center.subscribe()
        var iterator = stream.makeAsyncIterator()
        for index in 1...65 {
            center.publish(event(runID: "run-\(index)"))
        }

        #expect(await iterator.next()?.cursor == 2)
        center.finishSubscriptionsForTesting()
    }

    @Test("A heartbeat is emitted after the injected 15-second sleeper fires")
    func heartbeatEmission() async {
        let driver = HeartbeatDriver()
        let center = ConductorEnsembleEventCenter(
            heartbeatEvery: .seconds(15),
            sleep: { _ in try await driver.wait() }
        )
        let stream = center.subscribe()
        var iterator = stream.makeAsyncIterator()

        await driver.fire()
        let heartbeat = await iterator.next()

        #expect(heartbeat?.kind == "heartbeat")
        #expect(heartbeat?.runID == "")
        #expect(heartbeat?.cursor == 1)
        center.finishSubscriptionsForTesting()
    }

    private func makeCenter() -> ConductorEnsembleEventCenter {
        let driver = HeartbeatDriver()
        return ConductorEnsembleEventCenter(sleep: { _ in try await driver.wait() })
    }

    private func event(runID: String) -> EnsembleEvent {
        EnsembleEvent(
            cursor: 0,
            at: Date(timeIntervalSince1970: 1),
            runID: runID,
            kind: "state",
            state: .running
        )
    }
}

private actor HeartbeatDriver {
    private var permitCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        if waiters.isEmpty {
            permitCount = 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func wait() async throws {
        if permitCount > 0 {
            permitCount -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
