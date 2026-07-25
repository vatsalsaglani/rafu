import Foundation
import RafuCore

/// Main-actor broadcast center for re-derivable, content-free Ensemble run
/// events. Subscribers are bounded independently so one stalled CLI cannot
/// grow app memory or slow another subscriber.
@MainActor
final class ConductorEnsembleEventCenter {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    static let shared = ConductorEnsembleEventCenter()
    static let ringCapacity = 512
    static let subscriberBufferCapacity = 64
    static let heartbeatInterval: Duration = .seconds(15)

    private(set) var cursor: UInt64 = 0
    private var events: [EnsembleEvent] = []
    private var subscribers: [UUID: AsyncStream<EnsembleEvent>.Continuation] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatEvery: Duration
    private let sleep: Sleeper

    init(
        heartbeatEvery: Duration = ConductorEnsembleEventCenter.heartbeatInterval,
        sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) }
    ) {
        self.heartbeatEvery = heartbeatEvery
        self.sleep = sleep
    }

    func publish(_ event: EnsembleEvent) {
        cursor &+= 1
        let published = EnsembleEvent(
            cursor: cursor,
            at: event.at,
            runID: event.runID,
            kind: event.kind,
            state: event.state,
            stepIndex: event.stepIndex,
            note: event.note,
            label: event.label,
            startedBy: event.startedBy
        )
        events.append(published)
        if events.count > Self.ringCapacity {
            events.removeFirst(events.count - Self.ringCapacity)
        }
        for continuation in subscribers.values {
            continuation.yield(published)
        }
    }

    func subscribe() -> AsyncStream<EnsembleEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: EnsembleEvent.self,
            bufferingPolicy: .bufferingNewest(Self.subscriberBufferCapacity)
        )
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeSubscriber(id)
            }
        }
        subscribers[id] = continuation
        startHeartbeatIfNeeded()
        return stream
    }

    func eventsSince(_ requestedCursor: UInt64) -> [EnsembleEvent] {
        events.filter { $0.cursor > requestedCursor }
    }

    func runChanged(manifest: ConductorRunManifest) {
        publish(
            EnsembleEvent(
                cursor: 0,
                at: manifest.updatedAt,
                runID: manifest.id,
                kind: manifest.mergedAt == nil ? "state" : "merged",
                state: ConductorEnsembleRequestService.runState(
                    manifest: manifest,
                    liveState: nil
                ),
                label: manifest.label,
                startedBy: manifest.startedBy
            ))
    }

    func gateReady(event: ConductorGateReadyEvent) {
        let state: EnsembleRunState =
            event.kind == .merge ? .awaitingMergeGate : .awaitingGate
        publish(
            EnsembleEvent(
                cursor: 0,
                at: Date(),
                runID: event.runID,
                kind: "gate",
                state: state,
                stepIndex: event.stepIndex
            ))
    }

    var subscriberCountForTesting: Int {
        subscribers.count
    }

    func finishSubscriptionsForTesting() {
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil, !subscribers.isEmpty else { return }
        heartbeatTask = Task { @MainActor [weak self, sleep, heartbeatEvery] in
            do {
                while !Task.isCancelled {
                    try await sleep(heartbeatEvery)
                    try Task.checkCancellation()
                    guard let self, !self.subscribers.isEmpty else { return }
                    self.publish(
                        EnsembleEvent(
                            cursor: 0,
                            at: Date(),
                            runID: "",
                            kind: "heartbeat"
                        ))
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        guard subscribers.isEmpty else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
