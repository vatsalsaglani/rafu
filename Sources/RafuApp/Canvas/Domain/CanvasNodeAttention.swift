import Foundation

/// How much focused time an Ensemble card has earned. The record holds only a
/// duration and a date: never a title, a path or any card text. Tidy Up reads
/// it to decide which card anchors a cluster. Nothing here touches UI state.
nonisolated struct CanvasNodeAttention: Codable, Equatable, Sendable {
    /// Accumulated focused seconds as of `lastFocused`. Older time counts less:
    /// see `decayed(at:)`.
    var seconds: Double
    var lastFocused: Date

    /// The seconds that still count at `now`. The half-life is
    /// `CanvasLimits.attentionHalfLifeDays`; decay is computed on read, so no
    /// timer ever runs.
    func decayed(at now: Date) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(lastFocused)) / 86_400
        return seconds * pow(0.5, days / CanvasLimits.attentionHalfLifeDays)
    }
}

nonisolated extension CanvasLimits {
    /// Attention bounds. The record per card is two numbers, so the whole
    /// sidecar stays at most `boards * cards` small entries.
    static let attentionHalfLifeDays = 7.0
    static let attentionMaxAgeDays = 90.0
    static let attentionMaxSeconds = 100.0 * 3_600
    /// A single focus stretch counts at most this long (a sleeping Mac).
    static let attentionSegmentSeconds = 30.0 * 60
    /// A shorter stretch (arrow-key navigation) is not attention.
    static let attentionMinimumSegment = 1.0
    /// Focus without opened content counts less than working in the content.
    static let attentionFocusOnlyWeight = 0.3
    /// Routine flushes happen at most this often (seconds).
    static let attentionFlushInterval = 30.0
    /// The sidecar is read only up to this size; a bigger file is ignored.
    static let attentionFileBytes = 256 * 1_024
}

/// Pure merge, prune and score rules for attention records.
nonisolated enum CanvasAttention {
    typealias Records = [CanvasCardID: CanvasNodeAttention]

    /// `base` with `delta` added, per card. Both sides decay to the later of
    /// their two dates first, so the result does not depend on the order of
    /// merges. Seconds are capped at `attentionMaxSeconds`.
    static func merged(_ base: Records, adding delta: Records) -> Records {
        var result = base
        for (id, added) in delta {
            guard added.seconds.isFinite, added.seconds > 0 else { continue }
            guard let existing = result[id] else {
                result[id] = capped(added)
                continue
            }
            let anchor = max(existing.lastFocused, added.lastFocused)
            result[id] = capped(
                CanvasNodeAttention(
                    seconds: existing.decayed(at: anchor) + added.decayed(at: anchor),
                    lastFocused: anchor))
        }
        return result
    }

    /// Drops what no longer matters: cards that are gone (when `live` is
    /// given), entries older than `attentionMaxAgeDays`, entries that decayed
    /// to nothing and values that are not finite. Dates in the future are
    /// pulled back to `now`. Keeps at most `CanvasLimits.cards` entries, the
    /// most attended first.
    static func pruned(_ records: Records, live: Set<CanvasCardID>?, now: Date) -> Records {
        var kept: [(id: CanvasCardID, record: CanvasNodeAttention, score: Double)] = []
        for (id, record) in records {
            if let live, !live.contains(id) { continue }
            guard record.seconds.isFinite, record.seconds > 0,
                record.lastFocused.timeIntervalSince1970.isFinite
            else { continue }
            var value = capped(record)
            if value.lastFocused > now { value.lastFocused = now }
            guard
                now.timeIntervalSince(value.lastFocused) <= CanvasLimits.attentionMaxAgeDays
                    * 86_400
            else { continue }
            let score = value.decayed(at: now)
            guard score >= 1 else { continue }
            kept.append((id, value, score))
        }
        kept.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        return Dictionary(
            uniqueKeysWithValues: kept.prefix(CanvasLimits.cards).map { ($0.id, $0.record) })
    }

    /// Decayed seconds and last-focused dates, in the shape Tidy Up reads.
    static func scores(_ records: Records, at now: Date)
        -> (seconds: [CanvasCardID: Double], lastFocused: [CanvasCardID: Date])
    {
        var seconds: [CanvasCardID: Double] = [:]
        var dates: [CanvasCardID: Date] = [:]
        for (id, record) in records {
            seconds[id] = record.decayed(at: now)
            dates[id] = record.lastFocused
        }
        return (seconds, dates)
    }

    private static func capped(_ record: CanvasNodeAttention) -> CanvasNodeAttention {
        var value = record
        value.seconds = min(CanvasLimits.attentionMaxSeconds, max(0, record.seconds))
        return value
    }
}

/// What the user is looking at: a focused card, with or without its content
/// open.
nonisolated struct CanvasAttentionFocus: Equatable, Sendable {
    let card: CanvasCardID
    let contentIsActive: Bool

    var weight: Double { contentIsActive ? 1 : CanvasLimits.attentionFocusOnlyWeight }
}

/// Turns coarse focus transitions into attention samples. It is fed by
/// focus changes only (never a frame, a keystroke or terminal output), so it
/// costs one small record per transition.
nonisolated struct CanvasAttentionClock: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let card: CanvasCardID
        /// Weighted seconds.
        let seconds: Double
        let end: Date

        var record: CanvasNodeAttention { .init(seconds: seconds, lastFocused: end) }
    }

    private var focus: CanvasAttentionFocus?
    private var since = Date.distantPast

    /// Moves to `next` (nil: nobody is looking). Returns the stretch that just
    /// ended, or nil when nothing changed or the stretch was too short.
    mutating func move(to next: CanvasAttentionFocus?, at now: Date) -> Sample? {
        guard next != focus else { return nil }
        let closed = sample(at: now)
        focus = next
        since = now
        return closed
    }

    /// Closes the running stretch and starts the same focus again, so a flush
    /// sees time that has not ended yet.
    mutating func fold(at now: Date) -> Sample? {
        // A stretch that is too short keeps running, so no time is lost.
        guard let closed = sample(at: now) else { return nil }
        since = now
        return closed
    }

    /// The running stretch as a sample, without ending it.
    func preview(at now: Date) -> Sample? { sample(at: now) }

    private func sample(at now: Date) -> Sample? {
        guard let focus else { return nil }
        let raw = now.timeIntervalSince(since)
        guard raw.isFinite, raw >= CanvasLimits.attentionMinimumSegment else { return nil }
        return Sample(
            card: focus.card,
            seconds: min(raw, CanvasLimits.attentionSegmentSeconds) * focus.weight,
            end: now)
    }
}
