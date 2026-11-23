import Foundation

/// One turn of the live view. It is a preview: it has no `MeetingTurnID`, and
/// nothing stores it. The stored transcript comes from the final pass after
/// Stop.
public struct MeetingLiveTurn: Hashable, Sendable, Identifiable {
    public var track: MeetingTrack
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// True when the end of this turn is text that can still change.
    public var isVolatile: Bool

    public init(
        track: MeetingTrack, start: TimeInterval, end: TimeInterval, text: String,
        isVolatile: Bool
    ) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.isVolatile = isVolatile
    }

    /// The label: the live view cannot tell the far speakers apart.
    public var speaker: MeetingSpeakerLabel { track == .me ? .me : .them }

    /// A view identity for the list, from the track and the start time. It is
    /// not a turn id and is never stored.
    public var id: String { "\(track.rawValue)@\(Int((start * 1000).rounded()))" }
}

/// Joins the live events of the two tracks into turns for the live view, with
/// the time rules of `MeetingTurnRules`.
public struct MeetingLiveTurnAssembler: Sendable {
    private struct VolatileText: Sendable {
        var text: String
        var range: ClosedRange<TimeInterval>
    }

    private struct TrackState: Sendable {
        var finalWords: [MeetingWord] = []
        var volatile: VolatileText?
        var unavailableReason: String?
    }

    private var states: [MeetingTrack: TrackState] = [:]

    public init() {}

    /// Takes one event of one track.
    public mutating func ingest(_ event: MeetingLiveTextEvent, track: MeetingTrack) {
        var state = states[track] ?? TrackState()
        switch event {
        case .volatile(let text, let range):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            state.volatile =
                trimmed.isEmpty || !range.lowerBound.isFinite || !range.upperBound.isFinite
                ? nil : VolatileText(text: trimmed, range: range)
        case .final(let words):
            let usable = words.filter(\.isUsable)
            guard !usable.isEmpty else { break }
            let needsSort =
                usable.count > 1
                || (state.finalWords.last.map { usable[0].start < $0.start } ?? false)
            state.finalWords += usable
            if needsSort { state.finalWords.sort(by: MeetingWord.clockOrder) }
            // The words that are final now replace the preview of that span.
            let finalEnd = usable.map(\.end).max() ?? 0
            if let volatile = state.volatile, volatile.range.lowerBound < finalEnd {
                state.volatile = nil
            }
            state.unavailableReason = nil
        case .unavailable(let reason):
            state.volatile = nil
            state.unavailableReason = reason
        }
        states[track] = state
    }

    /// The reason a track stopped giving text, or nil.
    public func unavailableReason(for track: MeetingTrack) -> String? {
        states[track]?.unavailableReason
    }

    /// The turns now, in start order; at the same start the "Me" turn first.
    public func turns() -> [MeetingLiveTurn] {
        var result: [MeetingLiveTurn] = []
        for track in MeetingTrack.allCases {
            result += turns(for: track)
        }
        result.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.track == .me && $1.track != .me
        }
        return result
    }

    /// Final words are cut with `MeetingTurnRules.startsNewTurn`, the same
    /// time rules as the stored transcript. The volatile tail can still
    /// change, so it joins the last turn unless there is a pause.
    private func turns(for track: MeetingTrack) -> [MeetingLiveTurn] {
        guard let state = states[track] else { return [] }
        var runs: [MeetingLiveTurn] = []
        var lastTexts: [String] = []

        func add(text: String, start: TimeInterval, end: TimeInterval, isVolatile: Bool) {
            if let last = runs.last,
                isVolatile
                    ? !MeetingTurnRules.isPause(gap: start - last.end)
                    : !MeetingTurnRules.startsNewTurn(
                        turnStart: last.start, turnEnd: last.end,
                        lastText: lastTexts[lastTexts.count - 1], nextStart: start,
                        nextEnd: end)
            {
                runs[runs.count - 1].end = max(last.end, end)
                runs[runs.count - 1].text += " " + text
                runs[runs.count - 1].isVolatile = isVolatile
                lastTexts[lastTexts.count - 1] = text
            } else {
                runs.append(
                    MeetingLiveTurn(
                        track: track, start: start, end: max(start, end), text: text,
                        isVolatile: isVolatile))
                lastTexts.append(text)
            }
        }

        var items: [(text: String, start: TimeInterval, end: TimeInterval, isVolatile: Bool)] =
            state.finalWords.map {
                (
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines), $0.start,
                    MeetingTurnRules.effectiveEnd(of: $0), false
                )
            }
        if let volatile = state.volatile {
            items.append(
                (volatile.text, volatile.range.lowerBound, volatile.range.upperBound, true))
        }
        items.sort { $0.start < $1.start }
        for item in items {
            add(text: item.text, start: item.start, end: item.end, isVolatile: item.isVolatile)
        }
        return runs
    }
}
