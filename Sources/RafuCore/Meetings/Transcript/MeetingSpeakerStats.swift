import Foundation

/// The talk time of one speaker label.
public struct MeetingSpeakerStats: Hashable, Sendable, Identifiable {
    public var speaker: MeetingSpeakerLabel
    /// The seconds of speech of this speaker. Echo turns are not counted.
    public var speechSeconds: TimeInterval
    /// The part of the talk time of the shown speakers, 0...1. 0 when this
    /// speaker is not shown.
    public var share: Double
    /// The turns that count (echo turns do not).
    public var turnCount: Int
    /// False for a speaker with less than
    /// `MeetingSpeakerStatsRule.minimumShownSpeechSeconds` of speech, for
    /// example a stray word that a speaker engine gave its own label.
    public var isShown: Bool

    public var id: MeetingSpeakerLabel { speaker }

    public init(
        speaker: MeetingSpeakerLabel, speechSeconds: TimeInterval, share: Double,
        turnCount: Int, isShown: Bool
    ) {
        self.speaker = speaker
        self.speechSeconds = speechSeconds
        self.share = share
        self.turnCount = turnCount
        self.isShown = isShown
    }
}

/// The talk time of a meeting.
public struct MeetingTalkStats: Hashable, Sendable {
    /// Every speaker label of the turns, in the order of its first turn.
    public var speakers: [MeetingSpeakerStats]
    /// The seconds of speech of all speakers, shown or not. Echo turns are
    /// not counted.
    public var totalSpeechSeconds: TimeInterval
    /// The turns marked as echo.
    public var echoTurnCount: Int
    /// True when a counted turn has no `speechSeconds` (a meeting made before
    /// that field existed); its talk time is then the turn length.
    public var isEstimated: Bool

    public init(
        speakers: [MeetingSpeakerStats], totalSpeechSeconds: TimeInterval, echoTurnCount: Int,
        isEstimated: Bool
    ) {
        self.speakers = speakers
        self.totalSpeechSeconds = totalSpeechSeconds
        self.echoTurnCount = echoTurnCount
        self.isEstimated = isEstimated
    }
}

/// Talk time from the stored turns. Pure: the app calls it when it loads a
/// meeting, so stored meetings get it too.
public enum MeetingSpeakerStatsRule {
    /// A speaker with less speech than this is not shown, unless no speaker
    /// reaches it.
    public static let minimumShownSpeechSeconds: TimeInterval = 2

    public static func stats(for turns: [MeetingTurn]) -> MeetingTalkStats {
        var order: [MeetingSpeakerLabel] = []
        var seconds: [MeetingSpeakerLabel: TimeInterval] = [:]
        var counts: [MeetingSpeakerLabel: Int] = [:]
        var echoTurnCount = 0
        var isEstimated = false

        for turn in turns {
            if seconds[turn.speaker] == nil {
                order.append(turn.speaker)
                seconds[turn.speaker] = 0
                counts[turn.speaker] = 0
            }
            if turn.isEcho {
                echoTurnCount += 1
                continue
            }
            if turn.speechSeconds == nil { isEstimated = true }
            seconds[turn.speaker, default: 0] += speech(of: turn)
            counts[turn.speaker, default: 0] += 1
        }

        let threshold = minimumShownSpeechSeconds - MeetingTurnRules.tolerance
        let anyReaches = order.contains { (seconds[$0] ?? 0) >= threshold }
        let shown = Set(order.filter { !anyReaches || (seconds[$0] ?? 0) >= threshold })
        let shownTotal = shown.reduce(0) { $0 + (seconds[$1] ?? 0) }

        let speakers = order.map { label in
            let value = seconds[label] ?? 0
            let isShown = shown.contains(label)
            return MeetingSpeakerStats(
                speaker: label, speechSeconds: value,
                share: isShown && shownTotal > 0 ? value / shownTotal : 0,
                turnCount: counts[label] ?? 0, isShown: isShown)
        }
        return MeetingTalkStats(
            speakers: speakers,
            totalSpeechSeconds: order.reduce(0) { $0 + (seconds[$1] ?? 0) },
            echoTurnCount: echoTurnCount, isEstimated: isEstimated)
    }

    /// The seconds one turn counts for: `speechSeconds`, else the length.
    private static func speech(of turn: MeetingTurn) -> TimeInterval {
        let value = turn.speechSeconds ?? (turn.end - turn.start)
        return value.isFinite ? max(0, value) : 0
    }
}
