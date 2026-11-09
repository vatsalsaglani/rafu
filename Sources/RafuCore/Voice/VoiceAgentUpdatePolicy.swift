import Foundation

/// One agent terminal on the visible Ensemble, as Rafu Voice sees it. Built
/// from the hook session that runs in the card's terminal. Small values only.
public nonisolated struct VoiceAgentSignal: Equatable, Sendable {
    public let cardID: String
    public let title: String
    /// "Claude Code", "Codex".
    public let agent: String
    /// Stable per agent session; resets the "already said" memory per card.
    public let sessionRowID: UUID
    public let state: AgentSessionState
    public let replyEventID: UUID?
    /// The hook's last reply text (at most 600 characters). Spoken only after
    /// `VoiceAgentUpdatePolicy.spokenExcerpt`.
    public let preview: String?

    public init(
        cardID: String, title: String, agent: String, sessionRowID: UUID,
        state: AgentSessionState, replyEventID: UUID?, preview: String?
    ) {
        self.cardID = cardID
        self.title = title
        self.agent = agent
        self.sessionRowID = sessionRowID
        self.state = state
        self.replyEventID = replyEventID
        self.preview = preview
    }

    /// What the agent needs, or `nil` while it works, ended, or finished
    /// without a new reply.
    public var kind: VoiceAgentUpdate.Kind? {
        switch state {
        case .finished: replyEventID == nil ? nil : .done
        case .waitingForPermission: .needsApproval
        case .needsInput: .waiting
        case .working, .ended: nil
        }
    }

    /// Changes when there is something new to say about this card.
    public var announcementKey: String? {
        guard let kind else { return nil }
        switch kind {
        case .done: return "reply:\(replyEventID?.uuidString ?? "")"
        case .needsApproval, .waiting: return "\(kind):\(sessionRowID.uuidString)"
        }
    }
}

/// One sentence worth of news, waiting for a quiet moment.
public nonisolated struct VoiceAgentUpdate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case done, needsApproval, waiting
    }

    public let cardID: String
    public let kind: Kind
    public let agent: String
    public let title: String
    /// Already reduced by `VoiceAgentUpdatePolicy.spokenExcerpt`.
    public let excerpt: String?
    public let queuedAt: Duration

    public init(
        cardID: String, kind: Kind, agent: String, title: String, excerpt: String?,
        queuedAt: Duration
    ) {
        self.cardID = cardID
        self.kind = kind
        self.agent = agent
        self.title = title
        self.excerpt = excerpt
        self.queuedAt = queuedAt
    }
}

/// Decides what Rafu says unprompted when an agent finishes or needs the
/// person (ADR 0035, "Agent updates by voice"). Pure: the caller passes the
/// time and decides when speaking is allowed. Owns the queue, the coalescing
/// and the rate limit. The sentence is composed here from the hook preview and
/// is never sent to the backend as an instruction.
public nonisolated struct VoiceAgentUpdatePolicy: Equatable, Sendable {
    /// One spoken update per this long.
    public static let coalesceInterval: Duration = .seconds(10)
    public static let queueLimit = 3
    public static let maximumPerMinute = 6
    /// An update older than this is news no more; it is dropped, not spoken.
    public static let staleAfter: Duration = .seconds(120)
    public static let maximumTitleScalars = 40
    public static let maximumExcerptScalars = 120

    /// Local speech this recent holds an update back.
    public static let speechQuiet: Duration = .milliseconds(1_500)
    /// Rafu's own audible reply this recent holds an update back.
    public static let replyQuiet: Duration = .milliseconds(600)

    public private(set) var queue: [VoiceAgentUpdate] = []
    /// The instants of the updates spoken in the last minute.
    public private(set) var spoken: [Duration] = []
    public private(set) var lastSpokenAt: Duration?

    public init() {}

    /// Queues one update. A newer update for the same card replaces the older
    /// one; past `queueLimit` the oldest is dropped.
    public mutating func enqueue(_ update: VoiceAgentUpdate) {
        queue.removeAll { $0.cardID == update.cardID }
        queue.append(update)
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
    }

    /// The sentence to speak at `now`, or `nil` when none is due (empty queue,
    /// less than `coalesceInterval` since the last one, or the minute limit).
    /// Returning a sentence empties the queue and counts as one spoken update.
    public mutating func nextSentence(at now: Duration) -> String? {
        queue.removeAll { now - $0.queuedAt > Self.staleAfter }
        spoken.removeAll { now - $0 >= .seconds(60) }
        guard !queue.isEmpty else { return nil }
        if let lastSpokenAt, now - lastSpokenAt < Self.coalesceInterval { return nil }
        guard spoken.count < Self.maximumPerMinute else { return nil }
        let batch = queue
        queue = []
        spoken.append(now)
        lastSpokenAt = now
        return Self.sentence(for: batch)
    }

    /// Whether an update would talk over nobody: no local speech in the last
    /// `speechQuiet` and no audible reply in the last `replyQuiet`.
    public static func isQuiet(now: Duration, lastSpeech: Duration, lastAudibleAt: Duration?)
        -> Bool
    {
        guard now - lastSpeech >= speechQuiet else { return false }
        if let lastAudibleAt, now - lastAudibleAt < replyQuiet { return false }
        return true
    }

    // MARK: Text

    /// "Claude Code in “Build” is done. It says: …." For several updates, one
    /// sentence per kind: "Claude Code in “Build” and Codex in “Tests” are
    /// done." The excerpt is added only when exactly one update is spoken.
    public static func sentence(for updates: [VoiceAgentUpdate]) -> String {
        let kinds: [VoiceAgentUpdate.Kind] = [.done, .needsApproval, .waiting]
        var parts: [String] = []
        for kind in kinds {
            let group = updates.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            let names = list(group.map { "\($0.agent) in “\(cleanTitle($0.title))”" })
            let plural = group.count > 1
            switch kind {
            case .done: parts.append("\(names) \(plural ? "are" : "is") done.")
            case .needsApproval:
                parts.append("\(names) \(plural ? "need" : "needs") your approval.")
            case .waiting:
                parts.append("\(names) \(plural ? "are" : "is") waiting for you.")
            }
        }
        if updates.count == 1, updates[0].kind == .done, let excerpt = updates[0].excerpt,
            !excerpt.isEmpty
        {
            parts.append("It says: \(excerpt).")
        }
        return parts.joined(separator: " ")
    }

    static func cleanTitle(_ title: String) -> String {
        let line = CanvasAgentText.singleLine(title, limit: maximumTitleScalars)
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "terminal" : line
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0, 1: items.first ?? ""
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// The first sentence of a reply preview, safe to read aloud: secrets
    /// replaced, at most `maximumExcerptScalars`, no code and no file paths.
    /// `nil` when nothing speakable is left (the update then says only that
    /// the agent is done).
    public static func spokenExcerpt(_ preview: String?) -> String? {
        guard let preview else { return nil }
        var lines: [String] = []
        var inFence = false
        for raw in preview.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence || line.isEmpty { continue }
            lines.append(line)
        }
        guard let first = lines.first else { return nil }
        // Markup at the line start ("## ", "- ", "> ") and bold markers.
        let marks = CharacterSet(charactersIn: "#*->• ")
        var text = first.replacingOccurrences(of: "**", with: "")
        text = text.trimmingCharacters(in: marks)
        text = VoiceOutputScrubber.scrub(lines: [text], maxLines: 1)
        guard !text.isEmpty else { return nil }
        var sentence = firstSentence(of: text)
        // Code and paths read badly aloud. Drop the whole excerpt instead.
        if sentence.contains(where: { "`/\\{}[]<>|;=$~".contains($0) }) { return nil }
        if sentence.contains(VoiceOutputScrubber.redaction) { return nil }
        if sentence.unicodeScalars.count > maximumExcerptScalars {
            let cut = String(sentence.unicodeScalars.prefix(maximumExcerptScalars))
            if let space = cut.lastIndex(of: " ") {
                sentence = String(cut[..<space])
            } else {
                sentence = cut
            }
        }
        sentence = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?"))
        return sentence.isEmpty ? nil : sentence
    }

    /// Up to the first ". ", "! " or "? ", or the whole text.
    private static func firstSentence(of text: String) -> String {
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if let previous, ".!?".contains(previous), character == " " {
                return String(text[..<index])
            }
            previous = character
            index = next
        }
        return text
    }
}
