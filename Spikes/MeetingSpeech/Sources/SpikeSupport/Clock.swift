// A small monotonic-time helper for the spike executables. Throw-away
// spike code; see .rafu/plans/meeting-speech-spike.md.
import Foundation

public struct SpikeClock: Sendable {
    private let start: ContinuousClock.Instant

    public init() {
        start = ContinuousClock.now
    }

    public var elapsedSeconds: Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public var elapsedMilliseconds: Double { elapsedSeconds * 1000 }
}
