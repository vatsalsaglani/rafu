import Foundation

/// The status-bar memory chip's settled value: the median of the last
/// `window` 5 s samples, so a short spike (a Finder drag session, a large
/// paste) does not move the number. Live and peak stay available for the
/// tooltip, and a trend flags a sustained change. Pure.
nonisolated struct MemorySettling: Equatable, Sendable {
    /// Six 5 s samples: 30 s.
    static let window = 6
    /// Twenty-four 5 s samples: two minutes.
    static let trendWindow = 24
    /// The median of the last `window` must differ from the median of the
    /// first `window` by more than this fraction to show a trend.
    static let trendThreshold = 0.15

    enum Trend: Equatable, Sendable { case flat, up, down }

    /// Oldest first, at most `trendWindow`.
    private(set) var samples: [UInt64] = []
    /// The highest sample since this value was made, not only in the ring.
    private(set) var peak: UInt64?

    init() {}

    mutating func append(_ bytes: UInt64) {
        samples.append(bytes)
        if samples.count > Self.trendWindow {
            samples.removeFirst(samples.count - Self.trendWindow)
        }
        peak = max(peak ?? bytes, bytes)
    }

    var live: UInt64? { samples.last }

    /// The median of the last `window` samples. With fewer samples it is the
    /// live value, so the chip never shows a median of one or two readings.
    var settled: UInt64? {
        guard samples.count >= Self.window else { return live }
        return Self.median(Array(samples.suffix(Self.window)))
    }

    /// The median of the last `window` against the median of the first
    /// `window` of a full ring; `flat` until the ring is full.
    var trend: Trend {
        guard samples.count >= Self.trendWindow,
            let recent = Self.median(Array(samples.suffix(Self.window))),
            let earlier = Self.median(Array(samples.prefix(Self.window))), earlier > 0
        else { return .flat }
        let change = (Double(recent) - Double(earlier)) / Double(earlier)
        if change > Self.trendThreshold { return .up }
        if change < -Self.trendThreshold { return .down }
        return .flat
    }

    /// The middle value; the mean of the two middle values for an even count.
    static func median(_ values: [UInt64]) -> UInt64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            let low = sorted[middle - 1]
            let high = sorted[middle]
            return low + (high - low) / 2
        }
        return sorted[middle]
    }
}
