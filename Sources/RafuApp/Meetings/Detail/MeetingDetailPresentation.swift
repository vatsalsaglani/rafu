import Foundation
import RafuCore

/// The start time and the speaker of one turn. The overview keeps one for
/// each turn, so a citation gets its label ("02:13 Shilpa") when its turn
/// is not loaded. No text.
nonisolated struct MeetingTurnRef: Hashable, Sendable {
    var start: TimeInterval
    var speaker: MeetingSpeakerLabel
}

/// The local overview of one meeting: made on this Mac, with no AI. It
/// holds labels and numbers only, never transcript text.
nonisolated struct MeetingOverview: Hashable, Sendable {
    /// The talk time of each speaker, repeated lines left out.
    var stats: MeetingTalkStats
    /// The start and the speaker of each turn.
    var turnRefs: [MeetingTurnID: MeetingTurnRef]
    /// The turns that are not repeated lines.
    var turnCount: Int
    /// The repeated lines (hidden by default).
    var repeatedCount: Int
    /// True when a speaker engine split the "Them" track into numbered
    /// speakers.
    var hasNumberedSpeakers: Bool

    /// Every speaker label, in the order of its first turn. The shapes use
    /// this order.
    var speakerLabels: [MeetingSpeakerLabel] { stats.speakers.map(\.speaker) }

    /// The speakers with enough talk time to show (two seconds or more).
    var shownSpeakers: [MeetingSpeakerStats] { stats.speakers.filter(\.isShown) }
}

/// One piece of an answer: plain text, or a citation mark.
nonisolated enum MeetingAnswerSegment: Hashable, Sendable {
    case text(String)
    /// `isVerified` is false when the turn is not in the checked citations
    /// of the answer. An unverified mark is dropped from the answer.
    case citation(MeetingTurnID, isVerified: Bool)
}

/// One citation chip below an answer or a summary item: "02:13 Shilpa".
nonisolated struct MeetingCitationChip: Hashable, Sendable, Identifiable {
    var turn: MeetingTurnID
    var label: String
    /// "Show the line at 2 minutes 13 seconds, Shilpa".
    var accessibilityLabel: String

    var id: MeetingTurnID { turn }
}

/// Consecutive lines of one speaker, with less than 30 seconds between
/// them. The transcript shows one speaker row for each group.
nonisolated struct MeetingTurnGroup: Hashable, Sendable, Identifiable {
    var speaker: MeetingSpeakerLabel
    /// Never empty.
    var turns: [MeetingTurn]

    var id: MeetingTurnID { turns[0].id }
    var start: TimeInterval { turns[0].start }
}

/// The ask state of the detail view.
nonisolated enum MeetingAskState: Hashable, Sendable {
    case idle
    case running(MeetingAgentCLI)
    /// Another answer for this meeting is in progress. Not an error.
    case busy
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The question that was sent and is not stored yet: a bubble shows it at
/// once, before the answer comes.
nonisolated struct MeetingPendingQuestion: Hashable, Sendable {
    var text: String
    var cli: MeetingAgentCLI
    var date: Date
}

/// The result of a name-suggestion run that found nothing to accept.
nonisolated enum MeetingNameSuggestionOutcome: Hashable, Sendable {
    /// "Claude Code found no names in this meeting."
    case noNamesFound(MeetingAgentCLI)
}

/// A suggestion button of the empty Ask column.
nonisolated struct MeetingQuestionSuggestion: Hashable, Sendable, Identifiable {
    var title: String
    var question: String

    var id: String { title }
}

/// Publishes streamed text at most once for each interval, so the answer
/// view parses its Markdown at most ten times a second.
nonisolated struct MeetingStreamThrottle: Hashable, Sendable {
    static let interval: Duration = .milliseconds(100)

    private(set) var lastPublish: ContinuousClock.Instant?

    /// True when text can show now; it then records `now`.
    mutating func shouldPublish(at now: ContinuousClock.Instant) -> Bool {
        if let lastPublish, now - lastPublish < Self.interval { return false }
        lastPublish = now
        return true
    }

    /// The time left until the next publish may happen.
    func delay(at now: ContinuousClock.Instant) -> Duration {
        guard let lastPublish else { return .zero }
        let passed = now - lastPublish
        return passed >= Self.interval ? .zero : Self.interval - passed
    }

    mutating func reset() { lastPublish = nil }
}

/// The pure presentation logic of the meeting view. Each function is
/// tested; the views only show the results.
nonisolated enum MeetingDetailPresentation {
    /// The longest question the ask box sends.
    static let maximumQuestionLength = 2_000
    /// Turns for each page of the transcript.
    static let pageSize = 200
    /// A citation or a search loads at most this many pages.
    static let maximumRevealPages = 20
    /// A gap of this many seconds or more starts a new speaker group.
    static let groupGapSeconds: TimeInterval = 30
    /// Answers longer than this (in UTF-8 bytes) show as plain text, as in
    /// Agent History: MarkdownUI lays out a huge document slowly.
    static let markdownByteLimit = 24_000
    /// The scheme of a citation link in an answer.
    static let turnLinkScheme = "rafu-meeting-turn"

    static let questionSuggestions: [MeetingQuestionSuggestion] = [
        MeetingQuestionSuggestion(
            title: "What was decided?",
            question: "List each decision in this meeting. Cite the turn for each one."),
        MeetingQuestionSuggestion(
            title: "Who does what next?",
            question: "List each action item and its owner. Cite the turn for each one."),
        MeetingQuestionSuggestion(
            title: "What are the open questions?",
            question: "List the questions that this meeting left open. Cite the turn for each one."
        ),
    ]

    /// The shapes of the speakers, by first appearance. A shape goes with
    /// each colour, so a speaker is never told apart by colour alone.
    static let speakerShapes = ["◆", "●", "■", "▲", "▼"]

    // MARK: Overview

    static func overview(document: MeetingDocument) -> MeetingOverview {
        var refs: [MeetingTurnID: MeetingTurnRef] = [:]
        refs.reserveCapacity(document.turns.count)
        var turnCount = 0
        var repeatedCount = 0
        var numbered = false
        for turn in document.turns {
            refs[turn.id] = MeetingTurnRef(start: turn.start, speaker: turn.speaker)
            if turn.isEcho {
                repeatedCount += 1
                continue
            }
            turnCount += 1
            if case .speaker = turn.speaker { numbered = true }
        }
        return MeetingOverview(
            stats: MeetingSpeakerStatsRule.stats(for: document.turns),
            turnRefs: refs,
            turnCount: turnCount,
            repeatedCount: repeatedCount,
            hasNumberedSpeakers: numbered)
    }

    /// The shape of a speaker: its position in `order`, from a fixed list.
    static func shape(for label: MeetingSpeakerLabel, in order: [MeetingSpeakerLabel]) -> String {
        guard let index = order.firstIndex(of: label) else {
            return label == .me ? speakerShapes[0] : "○"
        }
        return speakerShapes[index % speakerShapes.count]
    }

    // MARK: Header

    /// "Today 12:06 · 6 min · Shilpa, Me": the speakers with the most talk
    /// first, at most four names and then "+2".
    static func headerMeta(
        start: Date, duration: TimeInterval, speakers: [String], now: Date = Date(),
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let line = MeetingsFormat.meetingLine(
            start: start, duration: duration, now: now, calendar: calendar, locale: locale)
        guard !speakers.isEmpty else { return line }
        let shown = speakers.prefix(4).joined(separator: ", ")
        let rest = speakers.count - 4
        return line + " · " + (rest > 0 ? "\(shown) +\(rest)" : shown)
    }

    /// "Exported 12:31", shown in the header for four seconds.
    static func exportedText(
        at date: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        "Exported \(MeetingsFormat.time(date, calendar: calendar, locale: locale))"
    }

    /// How long "Copied" or "Exported 12:31" stays in the header.
    static let shareResultSeconds: Duration = .seconds(4)

    /// The shown speakers, most talk first, as display names.
    static func headerSpeakers(_ overview: MeetingOverview?, names: MeetingSpeakerNames)
        -> [String]
    {
        guard let overview else { return [] }
        return overview.shownSpeakers
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.share != rhs.element.share {
                    return lhs.element.share > rhs.element.share
                }
                return lhs.offset < rhs.offset
            }
            .map { names.displayName(for: $0.element.speaker) }
    }

    // MARK: Speakers

    /// "57%".
    static func shareText(_ share: Double) -> String {
        "\(MeetingsFormat.percent(share))%"
    }

    /// "Shilpa, 57 percent of the talk. Rename".
    static func speakerAccessibilityLabel(name: String, share: Double) -> String {
        "\(name), \(MeetingsFormat.spokenPercent(share)) of the talk. Rename"
    }

    static func runningText(cli: MeetingAgentCLI) -> String {
        "\(cli.displayName) reads the meeting…"
    }

    static func noNamesText(cli: MeetingAgentCLI) -> String {
        "\(cli.displayName) found no names in this meeting."
    }

    // MARK: Citations

    /// "02:13 Shilpa". Nil when the turn is not in the meeting.
    static func citationLabel(
        _ turn: MeetingTurnID, refs: [MeetingTurnID: MeetingTurnRef], names: MeetingSpeakerNames
    ) -> String? {
        guard let ref = refs[turn] else { return nil }
        return "\(MeetingsFormat.clock(ref.start)) \(names.displayName(for: ref.speaker))"
    }

    /// The chips of the verified citations in `text`, in order, each once.
    /// A mark that is not verified, or whose turn is not in the meeting,
    /// gives no chip.
    static func citationChips(
        in text: String, verified: Set<MeetingTurnID>, refs: [MeetingTurnID: MeetingTurnRef],
        names: MeetingSpeakerNames
    ) -> [MeetingCitationChip] {
        var ids: [MeetingTurnID] = []
        for case .citation(let id, true) in answerSegments(text: text, verified: verified) {
            ids.append(id)
        }
        return chips(for: ids, refs: refs, names: names)
    }

    /// The chips for a list of turns, in order, each once.
    static func chips(
        for turns: [MeetingTurnID], refs: [MeetingTurnID: MeetingTurnRef],
        names: MeetingSpeakerNames
    ) -> [MeetingCitationChip] {
        var seen = Set<MeetingTurnID>()
        var result: [MeetingCitationChip] = []
        for id in turns where seen.insert(id).inserted {
            guard let ref = refs[id] else { continue }
            let name = names.displayName(for: ref.speaker)
            result.append(
                MeetingCitationChip(
                    turn: id,
                    label: "\(MeetingsFormat.clock(ref.start)) \(name)",
                    accessibilityLabel:
                        "Show the line at \(MeetingsFormat.spokenDuration(ref.start)), \(name)"))
        }
        return result
    }

    /// The Markdown that an answer shows: each verified `[t12]` becomes
    /// `[02:13 Shilpa](rafu-meeting-turn:t12)`; each other mark is dropped.
    /// The speaker name is escaped, so a name cannot make a link.
    static func answerMarkdown(
        _ text: String, verified: Set<MeetingTurnID>, refs: [MeetingTurnID: MeetingTurnRef],
        names: MeetingSpeakerNames
    ) -> String {
        var result = ""
        for segment in answerSegments(text: text, verified: verified) {
            switch segment {
            case .text(let part):
                result += part
            case .citation(let id, let isVerified):
                guard isVerified, let label = citationLabel(id, refs: refs, names: names)
                else { continue }
                result += "[\(escapedLinkLabel(label))](\(turnLinkScheme):\(id.text))"
            }
        }
        return result
    }

    /// Streamed text before its citations are checked: every mark is
    /// dropped.
    static func streamingMarkdown(_ text: String) -> String {
        answerMarkdown(text, verified: [], refs: [:], names: MeetingSpeakerNames())
    }

    /// Escapes the characters that would end a link label or start
    /// formatting: `\ [ ] ( ) * _ ` < >`.
    static func escapedLinkLabel(_ label: String) -> String {
        var result = ""
        for character in label {
            if "\\[]()*_`<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The turn of a citation link, or nil for any other link. The answer
    /// view opens only these links; it discards every other URL.
    static func turn(fromLink url: URL) -> MeetingTurnID? {
        guard url.scheme?.lowercased() == turnLinkScheme else { return nil }
        let text = url.absoluteString.dropFirst(turnLinkScheme.count + 1)
        return MeetingTurnID(text: String(text))
    }

    /// Cuts an answer into text and citation marks. The forms are `[t7]`,
    /// `[t11][t12]`, `[t7] [t11]` and a range `[t11–t12]` (an en dash or a
    /// hyphen); a range gives a mark for each end. Any other bracket text
    /// stays text.
    static func answerSegments(text: String, verified: Set<MeetingTurnID>)
        -> [MeetingAnswerSegment]
    {
        var segments: [MeetingAnswerSegment] = []
        var pending = ""
        var index = text.startIndex
        func flush() {
            if !pending.isEmpty {
                segments.append(.text(pending))
                pending = ""
            }
        }
        while index < text.endIndex {
            if text[index] == "[",
                let close = text[index...].firstIndex(of: "]"),
                let ids = citationIDs(String(text[text.index(after: index)..<close]))
            {
                flush()
                for id in ids {
                    segments.append(.citation(id, isVerified: verified.contains(id)))
                }
                index = text.index(after: close)
                continue
            }
            pending.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return segments
    }

    /// The turn ids inside one pair of brackets, or nil when it is not a
    /// citation.
    private static func citationIDs(_ inner: String) -> [MeetingTurnID]? {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if let single = MeetingTurnID(text: trimmed) { return [single] }
        for dash in ["–", "-"] {
            let parts = trimmed.components(separatedBy: dash)
            guard parts.count == 2,
                let first = MeetingTurnID(text: parts[0].trimmingCharacters(in: .whitespaces)),
                let last = MeetingTurnID(text: parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            return [first, last]
        }
        return nil
    }

    /// True when the answer is short enough for Markdown.
    static func usesMarkdown(_ text: String) -> Bool {
        text.utf8.count <= markdownByteLimit
    }

    // MARK: Conversation

    /// "Claude Code · 12:14".
    static func agentMeta(
        cli: MeetingAgentCLI?, date: Date, calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let name = cli?.displayName ?? "Agent"
        return "\(name) · \(MeetingsFormat.time(date, calendar: calendar, locale: locale))"
    }

    static let staleDividerText =
        "The text was made again. Earlier answers point to the old text."

    /// True when the line was written for an older text of the meeting. A
    /// line from before the revision existed counts as revision 0.
    static func isStale(_ entry: MeetingConversationEntry, currentRevision: Int?) -> Bool {
        guard let currentRevision else { return false }
        return (entry.textRevision ?? 0) < currentRevision
    }

    /// The id of the last line written for an older text: the divider shows
    /// after it. Nil when no line is old.
    static func staleDividerAfter(
        _ conversation: [MeetingConversationEntry], currentRevision: Int?
    ) -> UUID? {
        conversation.last { isStale($0, currentRevision: currentRevision) }?.id
    }

    // MARK: Transcript

    /// Groups consecutive turns of one speaker with a gap below 30 seconds.
    static func groups(_ turns: [MeetingTurn]) -> [MeetingTurnGroup] {
        var result: [MeetingTurnGroup] = []
        for turn in turns {
            if var last = result.last, last.speaker == turn.speaker,
                let previous = last.turns.last,
                turn.start - previous.end < groupGapSeconds
            {
                last.turns.append(turn)
                result[result.count - 1] = last
            } else {
                result.append(MeetingTurnGroup(speaker: turn.speaker, turns: [turn]))
            }
        }
        return result
    }

    /// "Show 6 repeated lines".
    static func repeatedToggleTitle(count: Int) -> String {
        count == 1 ? "Show 1 repeated line" : "Show \(count) repeated lines"
    }

    static let repeatedHelp = "The call sound that your microphone recorded again."

    /// The turns whose text has the query, in order. Case and diacritics
    /// do not count. An empty query matches nothing.
    static func searchMatches(_ query: String, in turns: [MeetingTurn]) -> [MeetingTurnID] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return turns.filter { matchRanges(of: needle, in: $0.text).isEmpty == false }.map(\.id)
    }

    /// The ranges of the query in one text.
    static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
            let range = text.range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex)
        {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    /// "3 of 12", or "No results".
    static func searchCountText(current: Int?, total: Int) -> String {
        guard total > 0, let current else { return "No results" }
        return "\(current + 1) of \(total)"
    }

    static let searchLimitNote = "Search covers the first 4,000 lines."

    // MARK: Engines

    static func textEngineName(_ engine: MeetingTextEngineID) -> String {
        switch engine {
        case .nemotronEnglish: "Nemotron English"
        case .appleSpeech: "Apple speech"
        case .whisperKit: "WhisperKit"
        }
    }

    static func speakerEngineName(_ engine: MeetingSpeakerEngineID) -> String {
        switch engine {
        case .nemotron3: "Nemotron 3"
        case .speakerKit: "SpeakerKit"
        }
    }

    /// "Text: WhisperKit · Speakers: Nemotron 3", or with no speaker engine
    /// "… · Speakers: not told apart".
    static func engineLine(_ use: MeetingEngineUse) -> String {
        var parts: [String] = []
        if let text = use.textEngine { parts.append("Text: \(textEngineName(text))") }
        if let speakers = use.speakerEngine {
            parts.append("Speakers: \(speakerEngineName(speakers))")
        } else {
            parts.append("Speakers: not told apart")
        }
        return parts.joined(separator: " · ")
    }

    /// The ready text engines other than the one that made the text, in the
    /// order of `MeetingTextEngineID.allCases`.
    static func remakeChoices(
        used: MeetingTextEngineID?, available: [MeetingTextEngineID: MeetingEngineAvailability]
    ) -> [MeetingTextEngineID] {
        MeetingTextEngineID.allCases.filter { $0 != used && available[$0]?.isReady == true }
    }

    static func remakeConfirmation(_ engine: MeetingTextEngineID) -> String {
        "Make the text again with \(textEngineName(engine))? This replaces the transcript. Your text edits are lost. Speaker names stay."
    }

    // MARK: Agents and consent

    static func consentTitle(cli: MeetingAgentCLI) -> String {
        "Send this transcript to \(cli.providerName)?"
    }

    static func consentText(cli: MeetingAgentCLI) -> String {
        """
        To answer, \(cli.displayName) reads this meeting. That sends the transcript text, the speaker names and your question off this Mac.

        Never sent: audio, other meetings, workspace files, Rafu's keys.

        \(cli.displayName) uses your own login. \(cli.providerName)'s terms apply.
        """
    }

    /// Consent is needed when the conversation has no answer from that CLI
    /// and the user did not agree in this view yet.
    static func needsConsent(
        cli: MeetingAgentCLI, conversation: [MeetingConversationEntry],
        askedThisSession: Set<MeetingAgentCLI>
    ) -> Bool {
        if askedThisSession.contains(cli) { return false }
        return !conversation.contains { $0.role == .answer && $0.cli == cli }
    }

    /// The probe result from the older availability check.
    static func probeResult(_ availability: MeetingAgentAvailability) -> MeetingAgentProbeResult {
        switch availability {
        case .ready: .ready
        case .notInstalled: .notInstalled
        case .unsupportedVersion(let found): .unsupportedVersion(found: found)
        }
    }

    /// "Claude Code", or for an agent that did not pass the probe
    /// "Codex — not installed", "Codex — not signed in", "Codex — this
    /// version is too old".
    static func agentMenuTitle(cli: MeetingAgentCLI, result: MeetingAgentProbeResult?) -> String {
        switch result {
        case nil, .ready: cli.displayName
        case .notInstalled: "\(cli.displayName) — not installed"
        case .notSignedIn: "\(cli.displayName) — not signed in"
        case .unsupportedVersion: "\(cli.displayName) — this version is too old"
        case .failed(let reason): "\(cli.displayName) — \(reason.message)"
        }
    }

    static let noAgentText = "Install Claude Code or Codex to ask questions."

    /// "Other agents cannot read your meetings".
    static func accessLine(_ access: MeetingAgentAccess) -> String {
        access == .on
            ? "Other agents can read your meetings" : "Other agents cannot read your meetings"
    }

    /// The suggestions that the user can accept: labels of this meeting
    /// only, never a label that already has the same confirmed name.
    static func usableSuggestions(
        _ suggested: [MeetingSpeakerLabel: String], speakers: [MeetingSpeakerLabel],
        names: MeetingSpeakerNames
    ) -> [MeetingSpeakerNameSuggestion] {
        let known = Set(speakers)
        return MeetingSpeakerNames.agentSuggestions(suggested)
            .filter { known.contains($0.label) && names.name(for: $0.label) != $0.name }
    }

    /// The text a question keeps: trimmed, at most 2,000 characters.
    static func cleanedQuestion(_ text: String) -> String {
        String(
            text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumQuestionLength))
    }

    // MARK: Summary

    static func summaryWritingText(cli: MeetingAgentCLI) -> String {
        "\(cli.displayName) writes the summary…"
    }

    static let summaryNoAgentText = "Install Claude Code or Codex to get a summary."
    static let summaryFailedText = "The summary was not made."
    static let summaryStaleText = "This summary is from an older text."
    static let summaryNoneText = "This meeting has no summary."

    /// The turns that a summary may cite: its own list and the lists of
    /// its items.
    static func verifiedSummaryTurns(_ notes: MeetingSummaryNotes) -> Set<MeetingTurnID> {
        var result = Set(notes.citations)
        for item in notes.decisions + notes.actionItems { result.formUnion(item.citations) }
        return result
    }
}
