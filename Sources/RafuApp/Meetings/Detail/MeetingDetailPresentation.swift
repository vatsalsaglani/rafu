import Foundation
import RafuCore

/// The talk time of one speaker in the local overview.
nonisolated struct MeetingOverviewSpeaker: Hashable, Sendable, Identifiable {
    var label: MeetingSpeakerLabel
    /// The sum of the lengths of this speaker's turns, echo turns left out.
    var talkSeconds: TimeInterval

    var id: MeetingSpeakerLabel { label }
}

/// The local overview of one meeting: made on this Mac, with no AI. It
/// holds labels and numbers only, never transcript text.
nonisolated struct MeetingOverview: Hashable, Sendable {
    var startDate: Date
    var duration: TimeInterval
    /// The speakers of the turns that are not echo, in the order of their
    /// first turn.
    var speakers: [MeetingOverviewSpeaker]
    /// The turns that are not echo.
    var turnCount: Int
    /// The echo turns (hidden by default).
    var echoCount: Int
    /// True when a speaker engine split the "Them" track into numbered
    /// speakers.
    var hasNumberedSpeakers: Bool

    var speakerLabels: [MeetingSpeakerLabel] { speakers.map(\.label) }
}

/// One piece of an answer: plain text, or a citation mark.
nonisolated enum MeetingAnswerSegment: Hashable, Sendable {
    case text(String)
    /// `isVerified` is false when the turn is not in the checked citations
    /// of the answer: the interface shows "No source" and no link.
    case citation(MeetingTurnID, isVerified: Bool)
}

/// One distinct citation mark of an answer, for the "Sources" row.
nonisolated struct MeetingCitationMark: Hashable, Sendable, Identifiable {
    var turn: MeetingTurnID
    var isVerified: Bool

    var id: MeetingTurnID { turn }
}

/// The ask state of the detail view.
nonisolated enum MeetingAskState: Hashable, Sendable {
    case idle
    case running(MeetingAgentCLI)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// A question chip of the conversation column.
nonisolated struct MeetingQuestionChip: Hashable, Sendable, Identifiable {
    var title: String
    var question: String

    var id: String { title }
}

/// The pure presentation logic of the meeting detail view. Each function is
/// tested; the views only show the results.
nonisolated enum MeetingDetailPresentation {
    /// The longest question the ask box sends.
    static let maximumQuestionLength = 2_000
    /// Turns for each page of the transcript sidebar.
    static let pageSize = 200
    /// A citation loads at most this many pages to find its turn.
    static let maximumRevealPages = 20

    static let chips: [MeetingQuestionChip] = [
        MeetingQuestionChip(
            title: "Summarize",
            question: "Summarize this meeting in five points. Cite the turn for each point."),
        MeetingQuestionChip(
            title: "Decisions",
            question: "List each decision in this meeting. Cite the turn for each one."),
        MeetingQuestionChip(
            title: "Action items",
            question: "List each action item and its owner. Cite the turn for each one."),
    ]

    /// The shapes of the speakers, by first appearance. A shape goes with
    /// each colour, so a speaker is never told apart by colour alone.
    static let speakerShapes = ["◆", "●", "■", "▲", "▼"]

    // MARK: Overview

    static func overview(document: MeetingDocument) -> MeetingOverview {
        var order: [MeetingSpeakerLabel] = []
        var talk: [MeetingSpeakerLabel: TimeInterval] = [:]
        var turnCount = 0
        var echoCount = 0
        var numbered = false
        for turn in document.turns {
            if turn.isEcho {
                echoCount += 1
                continue
            }
            turnCount += 1
            if case .speaker = turn.speaker { numbered = true }
            if talk[turn.speaker] == nil { order.append(turn.speaker) }
            let length = turn.end - turn.start
            talk[turn.speaker, default: 0] += length.isFinite ? max(0, length) : 0
        }
        return MeetingOverview(
            startDate: document.summary.startDate,
            duration: document.summary.duration,
            speakers: order.map { MeetingOverviewSpeaker(label: $0, talkSeconds: talk[$0] ?? 0) },
            turnCount: turnCount,
            echoCount: echoCount,
            hasNumberedSpeakers: numbered)
    }

    /// "31 min", "45 s", "1 h 5 min".
    static func lengthText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "Today 10:30 · 31 min".
    static func dateLine(
        startDate: Date, duration: TimeInterval, now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let time = startDate.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDate(startDate, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(startDate, inSameDayAs: yesterday)
        {
            day = "Yesterday"
        } else {
            day = startDate.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(day) \(time) · \(lengthText(duration))"
    }

    /// The share of the talk time, 0...1, for one speaker.
    static func talkShare(_ speaker: MeetingOverviewSpeaker, in overview: MeetingOverview)
        -> Double
    {
        let total = overview.speakers.reduce(0) { $0 + $1.talkSeconds }
        guard total > 0 else { return 0 }
        return speaker.talkSeconds / total
    }

    /// The shape of a speaker: its position in `order`, from a fixed list.
    static func shape(for label: MeetingSpeakerLabel, in order: [MeetingSpeakerLabel]) -> String {
        guard let index = order.firstIndex(of: label) else {
            return label == .me ? speakerShapes[0] : "○"
        }
        return speakerShapes[index % speakerShapes.count]
    }

    // MARK: Answers

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

    /// The distinct citation marks of an answer, in order.
    static func citationMarks(in segments: [MeetingAnswerSegment]) -> [MeetingCitationMark] {
        var seen = Set<MeetingTurnID>()
        var result: [MeetingCitationMark] = []
        for case .citation(let id, let verified) in segments where seen.insert(id).inserted {
            result.append(MeetingCitationMark(turn: id, isVerified: verified))
        }
        return result
    }

    // MARK: Transcript

    static func namesBanner(count: Int) -> String {
        count == 1 ? "1 name to check" : "\(count) names to check"
    }

    static func echoToggleTitle(count: Int, shown: Bool) -> String {
        let noun = count == 1 ? "echo line" : "echo lines"
        return "\(shown ? "Hide" : "Show") \(count) \(noun)"
    }

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

    /// "Text: Nemotron English · Speakers: Nemotron 3", or with no speaker
    /// engine "… · Speakers: not told apart".
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

    /// "ready", "not installed", "Not available with this Codex version".
    /// Nil (no checker, or not checked yet) gives no text.
    static func availabilityText(
        _ availability: MeetingAgentAvailability?, cli: MeetingAgentCLI
    ) -> String? {
        switch availability {
        case .ready: "ready"
        case .notInstalled: "not installed"
        case .unsupportedVersion: "Not available with this \(cli.displayName) version"
        case nil: nil
        }
    }

    static func runningText(cli: MeetingAgentCLI) -> String {
        "\(cli.displayName) reads the meeting…"
    }

    static func accessLine(_ access: MeetingAgentAccess) -> String {
        access == .on ? "Agents can read your meetings" : "Agents cannot read your meetings"
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
}
