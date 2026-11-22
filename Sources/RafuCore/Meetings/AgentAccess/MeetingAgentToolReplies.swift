import Foundation

/// One meeting in a `meeting_search` reply with no query.
public struct MeetingAgentListedMeeting: Codable, Hashable, Sendable {
    public var meetingID: String
    public var title: String
    public var date: String
    public var minutes: Int
    public var state: String

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case title, date, minutes, state
    }
}

/// One hit in a `meeting_search` reply with a query.
public struct MeetingAgentSearchHit: Codable, Hashable, Sendable {
    public var meetingID: String
    public var title: String
    public var date: String
    /// Nil when the title matched, not a turn.
    public var turnID: String?
    public var snippet: String

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case turnID = "turn_id"
        case title, date, snippet
    }
}

/// One turn in a `meeting_read` reply.
public struct MeetingAgentReadTurn: Codable, Hashable, Sendable {
    public var id: String
    /// Clock text on the meeting clock, for example `12:27`.
    public var time: String
    public var speaker: String
    public var text: String
}

/// The reply of one meeting tool. Only the fields of that tool are set; the
/// encoder leaves out each nil field. There is no path, no audio size, no
/// engine name and no count of meetings that the reply does not list.
public struct MeetingAgentToolReply: Codable, Hashable, Sendable {
    // meeting_access
    public var access: String?
    public var message: String?
    // meeting_search
    public var meetings: [MeetingAgentListedMeeting]?
    public var hits: [MeetingAgentSearchHit]?
    // meeting_read
    public var title: String?
    public var date: String?
    public var minutes: Int?
    public var speakers: [String]?
    public var turns: [MeetingAgentReadTurn]?
    public var nextAfter: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case nextAfter = "next_after"
        case access, message, meetings, hits, title, date, minutes, speakers, turns
    }

    /// The reply as JSON text with sorted keys.
    public func jsonText() -> String {
        String(decoding: MeetingAgentToolReplies.encode(self), as: UTF8.self)
    }
}

/// Pure builders for the meeting tool replies. Each text field goes through
/// `cleanLine`; meeting text is data inside JSON strings.
public enum MeetingAgentToolReplies {
    public static let accessOn = "on"
    public static let accessOff = "off"
    public static let readyState = "ready"
    static let noMatchMessage = "No ready meeting matches."
    static let noMeetingsMessage = "There is no ready meeting."

    // MARK: Builders

    /// `meeting_access`.
    public static func access(_ access: MeetingAgentAccess) -> MeetingAgentToolReply {
        var reply = MeetingAgentToolReply()
        switch MeetingAgentAccessGate.check(access) {
        case .success:
            reply.access = accessOn
        case .failure(let denied):
            reply.access = accessOff
            reply.message = denied.message
        }
        return reply
    }

    /// `meeting_search` with no query: the newest ready meetings.
    public static func list(_ summaries: [MeetingSummaryRecord], limit: Int)
        -> MeetingAgentToolReply
    {
        let ready =
            summaries
            .filter { $0.state == .ready }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(clamped(limit, to: MeetingAgentToolLimits.searchLimits))
        var reply = MeetingAgentToolReply()
        reply.meetings = ready.map { summary in
            MeetingAgentListedMeeting(
                meetingID: summary.id.uuidString, title: title(summary.title),
                date: date(summary.startDate), minutes: minutes(summary.duration),
                state: readyState)
        }
        if reply.meetings?.isEmpty == true { reply.message = noMeetingsMessage }
        return bounded(reply)
    }

    /// `meeting_search` with a query. `summaries` holds the meetings of the
    /// hits; a hit whose meeting is missing or not ready is left out.
    public static func search(
        _ hits: [MeetingSearchHit], summaries: [MeetingID: MeetingSummaryRecord], limit: Int
    ) -> MeetingAgentToolReply {
        var listed: [MeetingAgentSearchHit] = []
        let size = clamped(limit, to: MeetingAgentToolLimits.searchLimits)
        for hit in hits where listed.count < size {
            guard let summary = summaries[hit.meeting], summary.state == .ready else { continue }
            listed.append(
                MeetingAgentSearchHit(
                    meetingID: summary.id.uuidString, title: title(summary.title),
                    date: date(summary.startDate), turnID: hit.turn?.text,
                    snippet: cleanLine(
                        hit.snippet, limit: MeetingAgentToolLimits.maximumSnippetCharacters)))
        }
        var reply = MeetingAgentToolReply()
        reply.hits = listed
        if listed.isEmpty { reply.message = noMatchMessage }
        return bounded(reply)
    }

    /// `meeting_read`. Echo turns are left out. `names` holds the names that
    /// the user confirmed; other speakers are "Me", "Them", "Speaker 2".
    public static func read(
        _ summary: MeetingSummaryRecord, page: MeetingTurnPage,
        names: [MeetingSpeakerLabel: String]
    ) -> MeetingAgentToolReply {
        let shown = page.turns.filter { !$0.isEcho }
        var reply = MeetingAgentToolReply()
        reply.title = title(summary.title)
        reply.date = date(summary.startDate)
        reply.minutes = minutes(summary.duration)
        var seen = Set<MeetingSpeakerLabel>()
        var speakers: [String] = []
        for turn in shown where seen.insert(turn.speaker).inserted {
            speakers.append(displayName(turn.speaker, names: names))
        }
        reply.speakers = speakers
        reply.turns = shown.map { turn in
            MeetingAgentReadTurn(
                id: turn.id.text, time: MeetingClockText.text(turn.start),
                speaker: displayName(turn.speaker, names: names),
                text: cleanLine(turn.text, limit: MeetingAgentToolLimits.maximumTurnCharacters))
        }
        reply.nextAfter = page.nextAfter?.text
        // Too large: drop trailing turns and page on from the last kept one.
        while encode(reply).count > MeetingAgentToolLimits.maximumReplyBytes,
            let turns = reply.turns, turns.count > 1
        {
            let kept = Array(turns.dropLast(max(1, turns.count / 4)))
            reply.turns = kept
            reply.nextAfter = kept.last?.id
        }
        return reply
    }

    // MARK: Fields

    /// The name shown for a speaker: the confirmed name, else `Me`, `Them`
    /// or `Speaker <n>`.
    public static func displayName(
        _ label: MeetingSpeakerLabel, names: [MeetingSpeakerLabel: String]
    ) -> String {
        if let name = names[label] {
            let clean = cleanLine(name, limit: MeetingAgentToolLimits.maximumTitleCharacters)
            if !clean.isEmpty { return clean }
        }
        switch label {
        case .me: return "Me"
        case .them: return "Them"
        case .speaker(let number): return "Speaker \(number)"
        }
    }

    /// One line of text: each control, format, line or paragraph separator
    /// character becomes a space, runs of white space become one space, and
    /// text longer than `limit` characters is cut with "…".
    public static func cleanLine(_ value: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in value.unicodeScalars {
            let isBlank: Bool
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                isBlank = true
            default:
                isBlank = scalar.properties.isWhitespace
            }
            if isBlank {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var text = String(scalars)
        while text.last == " " { text.removeLast() }
        if text.count > limit {
            text = String(text.prefix(max(0, limit - 1))) + "…"
        }
        return text
    }

    static func title(_ value: String) -> String {
        cleanLine(value, limit: MeetingAgentToolLimits.maximumTitleCharacters)
    }

    /// ISO 8601 in UTC, for example `2026-11-23T10:15:00Z`.
    static func date(_ value: Date) -> String {
        value.ISO8601Format()
    }

    static func minutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds / 60, 1_000_000).rounded())
    }

    public static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Encoding

    static func encode(_ reply: MeetingAgentToolReply) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(reply)) ?? Data("{}".utf8)
    }

    /// Drops trailing list items until the reply fits.
    static func bounded(_ reply: MeetingAgentToolReply) -> MeetingAgentToolReply {
        var value = reply
        while encode(value).count > MeetingAgentToolLimits.maximumReplyBytes {
            if let hits = value.hits, !hits.isEmpty {
                value.hits = Array(hits.dropLast(max(1, hits.count / 4)))
            } else if let meetings = value.meetings, !meetings.isEmpty {
                value.meetings = Array(meetings.dropLast(max(1, meetings.count / 4)))
            } else {
                break
            }
        }
        return value
    }
}
