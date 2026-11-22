import Foundation
import RafuCore
import Synchronization

/// Fans one value out to many `AsyncStream` subscribers. With `replaysLatest`
/// a new subscriber first gets the current value. Safe from each thread
/// except an audio callback (it takes a mutex).
nonisolated final class MeetingRecorderBroadcast<Element: Sendable>: Sendable {
    private struct State: ~Copyable {
        var latest: Element?
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
    }

    private let state: Mutex<State>
    private let replaysLatest: Bool
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(
        initial: Element? = nil, replaysLatest: Bool,
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(64)
    ) {
        state = Mutex(State(latest: initial))
        self.replaysLatest = replaysLatest
        self.bufferingPolicy = bufferingPolicy
    }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self, bufferingPolicy: bufferingPolicy)
        let id = UUID()
        state.withLock { state in
            if replaysLatest, let latest = state.latest { continuation.yield(latest) }
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ value: Element) {
        let subscribers = state.withLock { state in
            state.latest = value
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(value) }
    }

    /// Ends every current subscription.
    func finishAll() {
        let subscribers = state.withLock { state in
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.finish() }
    }

    var latest: Element? { state.withLock { $0.latest } }
}

/// The level of each track as small sampled values: the recorder stores the
/// peak of each block; the interface reads at its own pace (for example 10
/// times a second). Never observable state at audio rate.
nonisolated final class MeetingLevelMeters: Sendable {
    private let me = Atomic<UInt64>(MeetingBlockLevels.floorDBFS.bitPattern)
    private let them = Atomic<UInt64>(MeetingBlockLevels.floorDBFS.bitPattern)

    func set(_ track: MeetingTrack, peakDBFS: Double) {
        switch track {
        case .me: me.store(peakDBFS.bitPattern, ordering: .relaxed)
        case .them: them.store(peakDBFS.bitPattern, ordering: .relaxed)
        }
    }

    /// The latest block peak in dBFS (-160 is silence).
    func peakDBFS(_ track: MeetingTrack) -> Double {
        let bits =
            switch track {
            case .me: me.load(ordering: .relaxed)
            case .them: them.load(ordering: .relaxed)
            }
        return Double(bitPattern: bits)
    }

    func reset() {
        for track in MeetingTrack.allCases { set(track, peakDBFS: MeetingBlockLevels.floorDBFS) }
    }
}
