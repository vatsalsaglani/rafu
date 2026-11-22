import Foundation

// The private answer channel between Rafu and a waiting Claude Code hook
// helper (`rafu-agent-events claude <spool> --answer`).
//
// Claude Code runs a `PermissionRequest` hook at the same moment it shows its
// own terminal dialog, and it waits for the hook up to the hook's `timeout`.
// When the hook prints a decision, Claude takes it and closes the dialog. When
// the hook prints nothing, the dialog stays. So the helper can wait for the
// person to answer in Rafu without hiding the terminal prompt.
//
// The channel is a folder next to the spool:
//
// - `answers/<event id>.json`: one answer for one waiting helper (0600). The
//   app writes it with a temporary name and a rename; the helper reads it once
//   and deletes it.
// - `answers/watcher.lock`: the app holds an exclusive `flock` on it while it
//   can answer. The kernel drops the lock when the app exits or crashes, so a
//   helper can tell "Rafu is running and watching" from a stale file.
//
// An answer file holds an event id, a verdict and, for a question set, the
// chosen labels and the text the user typed (bounded, sanitized). It never
// holds request text: question text stays with the helper, which keys the
// answers itself. Nothing here logs.

public enum AgentAnswerChannelError: Error, Equatable, Sendable {
    case symlinkedDirectory
    case tooManyAnswers
    /// An answer for this event exists already. The first answer wins.
    case alreadyAnswered
    case writeFailed
}

/// The app's answer to one waiting `PermissionRequest` hook.
public nonisolated struct AgentPermissionAnswer: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// Claude runs the tool. The helper prints an allow decision.
        case allow
        /// Claude does not run the tool. The helper prints a deny decision.
        case deny
        /// Rafu does not answer (the request is gone, or no Rafu terminal owns
        /// it). The helper prints nothing, so Claude keeps its own dialog.
        case dismiss
    }

    /// Sent to the model with a denial. A fixed text: no user text travels.
    public static let denyMessage = "The user denied this request in Rafu."

    /// The answer to one question of an AskUserQuestion request: the index of
    /// the question in `tool_input.questions`, the chosen labels, and the
    /// typed text. The helper checks every label against its own copy.
    public struct QuestionAnswer: Codable, Equatable, Sendable {
        public let index: Int
        public let labels: [String]
        public let text: String?

        public init(index: Int, labels: [String], text: String? = nil) {
            self.index = index
            self.labels = labels
            self.text = text
        }
    }

    public let eventID: UUID
    public let verdict: Verdict
    /// A denial that also stops the turn ("Deny and stop"). Only for `deny`.
    public let interrupt: Bool
    /// The answers to a question set. Only for `allow`.
    public let answers: [QuestionAnswer]?
    /// Allow and remember: the helper echoes the one permission suggestion
    /// it received as `updatedPermissions`. Only for `allow`, and only while
    /// `CanvasAgentRequest.PersistPolicy` allows lasting grants.
    public let remember: Bool

    public init(
        eventID: UUID, verdict: Verdict, interrupt: Bool = false,
        answers: [QuestionAnswer]? = nil, remember: Bool = false
    ) {
        self.eventID = eventID
        self.verdict = verdict
        self.interrupt = verdict == .deny && interrupt
        self.answers = verdict == .allow ? answers : nil
        self.remember = verdict == .allow && remember
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let answers = try container.decodeIfPresent([QuestionAnswer].self, forKey: .answers)
        let limits = CanvasAgentRequest.Limits.self
        if let answers {
            // Bound what one file can ask the helper to print.
            guard answers.count <= limits.questions,
                answers.allSatisfy({
                    $0.labels.count <= limits.choices
                        && ($0.text?.utf8.count ?? 0) <= limits.freeTextBytes
                })
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .answers, in: container, debugDescription: "Too many answers.")
            }
        }
        self.init(
            eventID: try container.decode(UUID.self, forKey: .eventID),
            verdict: try container.decode(Verdict.self, forKey: .verdict),
            interrupt: try container.decodeIfPresent(Bool.self, forKey: .interrupt) ?? false,
            answers: answers,
            remember: try container.decodeIfPresent(Bool.self, forKey: .remember) ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, verdict, interrupt, answers, remember
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(interrupt, forKey: .interrupt)
        try container.encodeIfPresent(answers, forKey: .answers)
        if remember { try container.encode(remember, forKey: .remember) }
    }

    /// The output for a plain allow or deny, with no question set and no
    /// remembered rule.
    public var hookOutput: Data? { hookOutput(originalInput: nil, suggestion: nil) }

    /// The JSON the helper prints for Claude Code, or nil when it prints
    /// nothing. Schema verified on Claude Code 2.1.328:
    /// `hookSpecificOutput.decision.behavior` is `allow` or `deny`; a denial
    /// may carry `message` (shown to the model) and `interrupt` (stop).
    ///
    /// An allow with `answers` needs `originalInput`, the AskUserQuestion
    /// `tool_input` the helper kept. It prints `updatedInput`: that input
    /// with `answers` set to question text → value (Claude Code hooks and
    /// user-input references). Any answer that does not match the kept
    /// questions prints nothing, so the terminal dialog stays.
    ///
    /// `remember` adds `updatedPermissions: [suggestion]` when `suggestion`
    /// is the one entry Rafu understands (`PermissionSuggestion`) and
    /// `policy` allows lasting grants; otherwise it prints nothing.
    public func hookOutput(
        originalInput: [String: Any]?, suggestion: Any?,
        policy: CanvasAgentRequest.PersistPolicy = .current
    ) -> Data? {
        var decision: [String: Any]
        switch verdict {
        case .allow:
            decision = ["behavior": "allow"]
            if let answers {
                guard let originalInput,
                    let values = Self.answerValues(answers, questions: originalInput["questions"])
                else { return nil }
                var updated = originalInput
                updated["answers"] = values
                decision["updatedInput"] = updated
            }
            if remember {
                guard policy.allowsLasting, let entry = suggestion as? [String: Any],
                    AgentPermissionRequestSummary.PermissionSuggestion(entry: entry) != nil
                else { return nil }
                decision["updatedPermissions"] = [entry]
            }
        case .deny:
            decision = ["behavior": "deny", "message": Self.denyMessage]
            if interrupt { decision["interrupt"] = true }
        case .dismiss: return nil
        }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest", "decision": decision,
            ]
        ]
        guard JSONSerialization.isValidJSONObject(output) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Question text → answer value, or nil when the answers do not match
    /// `questions` exactly: one answer per question, each label one of that
    /// question's option labels, no label twice, a single-choice question
    /// with exactly one label or a text, a text within the free-text bound,
    /// and two questions with one text refused. Several labels (and a text)
    /// of a multiple-choice question are joined with `", "`.
    static func answerValues(_ answers: [QuestionAnswer], questions: Any?) -> [String: String]? {
        guard let list = questions as? [Any], !list.isEmpty,
            list.count <= CanvasAgentRequest.Limits.questions, answers.count == list.count,
            Set(answers.map(\.index)).count == answers.count
        else { return nil }
        var values: [String: String] = [:]
        for answer in answers {
            guard list.indices.contains(answer.index),
                let question = list[answer.index] as? [String: Any],
                let text = question["question"] as? String, values[text] == nil,
                let options = question["options"] as? [Any]
            else { return nil }
            let labels = options.compactMap { ($0 as? [String: Any])?["label"] as? String }
            let multiple = question["multiSelect"] as? Bool ?? false
            let separator = CanvasAgentRequest.Question.labelSeparator
            guard labels.count == options.count,
                Set(answer.labels).count == answer.labels.count,
                answer.labels.allSatisfy(labels.contains),
                !multiple || !answer.labels.contains(where: { $0.contains(separator) })
            else { return nil }
            if let typed = answer.text {
                let clean = CanvasAgentRequest.clean(
                    typed, limit: CanvasAgentRequest.Limits.freeTextBytes, keepsLineBreaks: false)
                guard !clean.altered, !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return nil
                }
            }
            let parts = answer.labels + (answer.text.map { [$0] } ?? [])
            if multiple {
                guard !parts.isEmpty else { return nil }
            } else {
                guard parts.count == 1 else { return nil }
            }
            values[text] = parts.joined(separator: separator)
        }
        return values
    }
}

/// How a helper's wait ended.
public nonisolated enum AgentAnswerOutcome: Equatable, Sendable {
    case answered(AgentPermissionAnswer)
    /// Rafu sent `dismiss`.
    case dismissed
    /// Rafu stopped watching (it quit) while the helper waited.
    case unwatched
    case timedOut

    /// What the helper prints for a plain allow or deny. Only an allow or a
    /// deny prints anything.
    public var output: Data? { output(originalInput: nil, suggestion: nil) }

    /// What the helper prints, with the request input and the permission
    /// suggestion it kept (see `AgentPermissionAnswer.hookOutput`).
    public func output(
        originalInput: [String: Any]?, suggestion: Any?,
        policy: CanvasAgentRequest.PersistPolicy = .current
    ) -> Data? {
        if case .answered(let answer) = self {
            return answer.hookOutput(
                originalInput: originalInput, suggestion: suggestion, policy: policy)
        }
        return nil
    }
}

/// The folder of answer files for one spool. The app writes; the helper reads.
public nonisolated struct AgentAnswerChannel: Equatable, Sendable {
    /// Seconds. The hook entry's `timeout`; Claude Code stops the hook then.
    public static let hookTimeoutSeconds = 300
    /// Seconds. The helper gives up first, so it exits on its own terms.
    public static let waitSeconds = 285
    /// Seconds. The helper's last-resort alarm, below `hookTimeoutSeconds`.
    public static let alarmSeconds = 290
    /// Seconds between two looks at the answer file.
    public static let pollInterval: TimeInterval = 0.2
    /// A verdict is a few dozen bytes. The largest question set (four
    /// answers of six 128-byte labels and 1 KiB of text) is about 7.5 KiB,
    /// and about 14.5 KiB when every character needs a JSON escape. Anything
    /// bigger is refused.
    public static let maximumAnswerBytes = 16 * 1_024
    /// The app writes no more answer files than this at once.
    public static let maximumFiles = 64
    /// Answer files older than this belong to a helper that is gone.
    public static let staleAge: TimeInterval = 600
    public static let watchLockName = "watcher.lock"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The channel that belongs to the hook's spool argument.
    public init(spool: URL) {
        directory = AgentTrackingPaths.answersDirectory(forSpool: spool)
    }

    public func answerURL(eventID: UUID) -> URL {
        directory.appending(path: eventID.uuidString + ".json", directoryHint: .notDirectory)
    }

    var watchLockURL: URL {
        directory.appending(path: Self.watchLockName, directoryHint: .notDirectory)
    }

    // MARK: App side

    /// Writes the answer for `answer.eventID` (0600, in a 0700 folder). The
    /// first answer for an event wins: a second write throws.
    public func write(_ answer: AgentPermissionAnswer) throws {
        let fileManager = FileManager.default
        try requireRealDirectoryPath()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        prune()
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard names.filter({ $0.hasSuffix(".json") }).count < Self.maximumFiles else {
            throw AgentAnswerChannelError.tooManyAnswers
        }
        let destination = answerURL(eventID: answer.eventID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw AgentAnswerChannelError.alreadyAnswered
        }
        let data = try JSONEncoder().encode(answer)
        let temporary = directory.appending(
            path: "." + answer.eventID.uuidString + ".tmp", directoryHint: .notDirectory)
        guard
            fileManager.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw AgentAnswerChannelError.writeFailed }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw AgentAnswerChannelError.writeFailed
        }
    }

    /// Removes answer files and temporary files older than `staleAge`: a
    /// helper that timed out never read them. Returns the number removed.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var removed = 0
        for url in urls where url.lastPathComponent != Self.watchLockName {
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > Self.staleAge else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Helper side

    /// Reads and deletes the answer for `eventID`. Nil when there is none, or
    /// when the file is not what the app writes: a link, a file of another
    /// owner, one readable by others, a big file, bad JSON, or an answer for
    /// another event. A refused file is deleted too, so it cannot linger.
    public func take(eventID: UUID) -> AgentPermissionAnswer? {
        guard !AgentTrackingFileCheck.isSymbolicLink(directory) else { return nil }
        let path = answerURL(eventID: eventID).path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        defer { unlink(path) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
            (info.st_mode & 0o077) == 0, Int(info.st_size) <= Self.maximumAnswerBytes,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let answer = try? JSONDecoder().decode(AgentPermissionAnswer.self, from: data),
            answer.eventID == eventID
        else { return nil }
        return answer
    }

    /// True while a Rafu process holds the watch lock. Never creates the lock.
    public var isWatched: Bool {
        let descriptor = open(watchLockURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Waits for the answer to `eventID`. The answer is checked first at every
    /// step, so an answer written just before Rafu quits still counts. `now`,
    /// `sleep` and `isWatched` are seams for tests.
    public func wait(
        eventID: UUID,
        timeout: TimeInterval = Double(AgentAnswerChannel.waitSeconds),
        interval: TimeInterval = AgentAnswerChannel.pollInterval,
        now: () -> Date = { Date() },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        isWatched watched: (() -> Bool)? = nil
    ) -> AgentAnswerOutcome {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if let answer = take(eventID: eventID) {
                return answer.verdict == .dismiss ? .dismissed : .answered(answer)
            }
            guard watched?() ?? isWatched else { return .unwatched }
            guard now() < deadline else { return .timedOut }
            sleep(interval)
        }
    }

    // MARK: Private

    private func requireRealDirectoryPath() throws {
        if AgentTrackingFileCheck.isSymbolicLink(directory)
            || AgentTrackingFileCheck.isSymbolicLink(directory.deletingLastPathComponent())
        {
            throw AgentAnswerChannelError.symlinkedDirectory
        }
    }
}

/// Held by the app while it can answer hook requests. The helper treats a
/// held lock as "Rafu is running and watching". Releasing it (or the app
/// exiting) tells every waiting helper to stop and leave the dialog alone.
public nonisolated final class AgentAnswerWatchLock {
    private var descriptor: Int32

    /// Takes the lock, creating the folder and the lock file (0700 / 0600).
    /// Nil when another process holds it, or the folder is a link.
    public init?(channel: AgentAnswerChannel) {
        let fileManager = FileManager.default
        let directory = channel.directory
        guard !AgentTrackingFileCheck.isSymbolicLink(directory),
            !AgentTrackingFileCheck.isSymbolicLink(directory.deletingLastPathComponent()),
            (try? fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil,
            (try? fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)) != nil
        else { return nil }
        let opened = open(
            channel.watchLockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return nil
        }
        descriptor = opened
    }

    /// Releases the lock. Safe to call twice.
    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
