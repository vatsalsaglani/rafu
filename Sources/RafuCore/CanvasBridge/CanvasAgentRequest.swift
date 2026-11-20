import Foundation

// The shared contract for answering an agent's approval or question from the
// Up next row. The supervisor (`rafu _canvas-agent`) builds a sanitized
// `CanvasAgentRequest` from a Codex app-server request, the app shows it, and
// the user's `CanvasAgentRequestDecision` goes back under the opaque `key`.
// The JSON-RPC id never appears here: only the supervisor maps a key to it.
// Request and answer text stay in memory and are never logged.

/// One pending agent request, sanitized and bounded. Every decoded value is
/// re-sanitized, so a value that came over IPC holds the same guarantees as one
/// built here.
public nonisolated struct CanvasAgentRequest: Codable, Hashable, Sendable {
    /// What the agent asks for.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Run a shell command (`item/commandExecution/requestApproval`).
        case command
        /// Apply file changes (`item/fileChange/requestApproval`).
        case fileChange
        /// Grant extra sandbox permissions (`item/permissions/requestApproval`).
        case permissions
        /// Answer multiple-choice questions (`item/tool/requestUserInput`).
        case userInput
    }

    /// A button the user can choose. Derived from the kind; never sent.
    public struct Option: Hashable, Sendable {
        public let decision: CanvasAgentRequestDecision
        public let label: String
        /// A stable identifier: the decision's wire name.
        public var id: String { decision.name }
    }

    /// One choice of a question. The `label` is the answer sent back.
    public struct Choice: Codable, Hashable, Sendable {
        public let label: String
        public let detail: String

        public init(label: String, detail: String) {
            self.label = label
            self.detail = detail
        }
    }

    /// One multiple-choice question.
    public struct Question: Codable, Hashable, Sendable {
        public let id: String
        public let header: String
        public let text: String
        public let choices: [Choice]
        /// The question needs free text, is secret, or did not fit the
        /// bounds exactly. Only the terminal can answer it.
        public let terminalOnly: Bool

        /// Sanitizes one question. `isSecret` makes it terminal-only.
        /// `isOther` does not: Codex 0.170.0 sets it on every question the
        /// model asks (the terminal shows "None of the above"). The listed
        /// choices stay answerable from Up next; a free-text answer still
        /// needs the terminal.
        public init(
            id: String, header: String, text: String, choices: [Choice],
            isOther: Bool = false, isSecret: Bool = false, terminalOnly: Bool = false
        ) {
            let cleanID = CanvasAgentRequest.clean(
                id, limit: Limits.identifierBytes, keepsLineBreaks: false)
            var restricted = terminalOnly || isSecret || cleanID.altered
            restricted = restricted || cleanID.text.isEmpty || choices.isEmpty
            restricted = restricted || choices.count > Limits.choices
            var kept: [Choice] = []
            for choice in choices.prefix(Limits.choices) {
                let label = CanvasAgentRequest.clean(
                    choice.label, limit: Limits.labelBytes, keepsLineBreaks: false)
                // The label is the answer, so a changed label cannot be sent.
                restricted = restricted || label.altered || label.text.isEmpty
                let detail = CanvasAgentRequest.clean(
                    choice.detail, limit: Limits.detailBytes, keepsLineBreaks: false)
                kept.append(Choice(label: label.text, detail: detail.text))
            }
            self.id = cleanID.text
            self.header =
                CanvasAgentRequest.clean(
                    header, limit: Limits.headerBytes, keepsLineBreaks: false
                ).text
            self.text =
                CanvasAgentRequest.clean(
                    text, limit: Limits.questionBytes, keepsLineBreaks: true
                ).text
            self.choices = kept
            self.terminalOnly = restricted
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try (
                id: container.decode(String.self, forKey: .id),
                header: container.decode(String.self, forKey: .header),
                text: container.decode(String.self, forKey: .text),
                choices: container.decode([Choice].self, forKey: .choices),
                terminalOnly: container.decode(Bool.self, forKey: .terminalOnly)
            )
            self.init(
                id: raw.id, header: raw.header, text: raw.text, choices: raw.choices,
                terminalOnly: raw.terminalOnly)
            guard
                id == raw.id, header == raw.header, text == raw.text,
                choices == raw.choices, terminalOnly == raw.terminalOnly
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "The question is not sanitized."))
            }
        }
    }

    /// Bounds in UTF-8 bytes or counts. A value over a bound is cut at a
    /// character boundary.
    public enum Limits {
        public static let commandBytes = 2 * 1_024
        public static let reasonBytes = 512
        public static let cwdBytes = 1_024
        public static let questions = 4
        public static let choices = 6
        public static let identifierBytes = 128
        public static let headerBytes = 128
        public static let questionBytes = 512
        public static let labelBytes = 128
        public static let detailBytes = 256
        public static let permissionLines = 8
        public static let permissionLineBytes = 256
        /// More blank lines in a row than this in a command makes it
        /// terminal-only: the text after them could sit out of view.
        public static let blankLinesInRow = 2
        /// A longer run of spaces and tabs in a command makes it terminal-only,
        /// for the same reason.
        public static let whitespaceRun = 64
    }

    /// The opaque identity the app and the supervisor share. Never the JSON-RPC id.
    public let key: UUID
    public let kind: Kind
    /// A Codex `humanCommand` checkpoint: only accept, decline and cancel.
    public let isHumanCheckpoint: Bool
    public let command: String?
    public let cwd: String?
    public let reason: String?
    /// For a file change: the root the agent asks to write under for the session.
    public let grantRoot: String?
    /// For a permissions request: one short line per requested grant.
    public let permissions: [String]
    public let questions: [Question]
    /// Only the terminal can answer: the request did not fit the bounds
    /// exactly, the command text was changed by sanitizing or could hide text
    /// behind blank space, a question needs free text or a secret, or the
    /// request is a file change (the row cannot show the change itself). The
    /// row then offers only "Open terminal".
    public let terminalOnly: Bool
    /// The agent can grant "allow for this session". False for a Claude Code
    /// request answered through its hook, which has no such answer.
    public let offersSessionAllow: Bool
    public let receivedAt: Date

    /// Builds a sanitized approval. Text over a bound is cut; control
    /// characters (other than line breaks and tabs in long text) and format
    /// characters (bidirectional controls, zero-width characters, soft
    /// hyphens) are removed.
    public init(
        key: UUID = UUID(), kind: Kind, isHumanCheckpoint: Bool = false,
        command: String? = nil, cwd: String? = nil, reason: String? = nil,
        grantRoot: String? = nil, permissions: [String] = [], questions: [Question] = [],
        terminalOnly: Bool = false, offersSessionAllow: Bool = true, receivedAt: Date = Date()
    ) {
        // A file change never shows the change itself, so what the row shows
        // is not all that would happen: only the terminal can answer it.
        var restricted = terminalOnly || kind == .fileChange
        // Only a command request carries a command.
        let cleanCommand = (kind == .command ? command : nil).map {
            Self.clean($0, limit: Limits.commandBytes, keepsLineBreaks: true)
        }
        // What the user reads must be exactly what runs.
        if let cleanCommand,
            cleanCommand.altered || cleanCommand.text.isEmpty
                || Self.hidesText(cleanCommand.text)
        {
            restricted = true
        }
        if kind == .command, cleanCommand == nil { restricted = true }
        var lines: [String] = []
        for line in permissions.prefix(Limits.permissionLines) {
            let clean = Self.clean(line, limit: Limits.permissionLineBytes, keepsLineBreaks: false)
            restricted = restricted || clean.altered || clean.text.isEmpty
            lines.append(clean.text)
        }
        if permissions.count > Limits.permissionLines { restricted = true }
        if kind == .permissions, lines.isEmpty { restricted = true }
        let kept = kind == .userInput ? Array(questions.prefix(Limits.questions)) : []
        if kind == .userInput {
            let ids = Set(kept.map(\.id))
            restricted =
                restricted || questions.isEmpty || questions.count > Limits.questions
                || ids.count != kept.count || kept.contains(where: \.terminalOnly)
        }
        self.key = key
        self.kind = kind
        self.isHumanCheckpoint = kind == .command && isHumanCheckpoint
        self.command = cleanCommand?.text
        self.cwd = cwd.map { Self.clean($0, limit: Limits.cwdBytes, keepsLineBreaks: false).text }
        self.reason = reason.map {
            Self.clean($0, limit: Limits.reasonBytes, keepsLineBreaks: true).text
        }
        self.grantRoot =
            kind == .fileChange
            ? grantRoot.map { Self.clean($0, limit: Limits.cwdBytes, keepsLineBreaks: false).text }
            : nil
        self.permissions = kind == .permissions ? lines : []
        self.questions = kept
        self.terminalOnly = restricted
        self.offersSessionAllow = offersSessionAllow
        self.receivedAt = receivedAt
    }

    // MARK: Options and decisions

    /// The buttons for this request, in display order. Empty when only the
    /// terminal can answer, and for questions (the answer is the choice).
    public var options: [Option] {
        guard !terminalOnly else { return [] }
        switch kind {
        case .command where isHumanCheckpoint:
            return [
                Option(decision: .accept, label: "Run"),
                Option(decision: .decline, label: "Deny"),
                Option(decision: .cancel, label: "Deny and stop"),
            ]
        case .command:
            return withSessionOption([
                Option(decision: .accept, label: "Run"),
                Option(decision: .acceptForSession, label: "Allow for this session"),
                Option(decision: .decline, label: "Deny"),
                Option(decision: .cancel, label: "Deny and stop"),
            ])
        case .fileChange:
            // Always terminal-only; see `terminalOnly`.
            return []
        case .permissions:
            return [
                Option(decision: .accept, label: "Allow for this turn"),
                Option(decision: .acceptForSession, label: "Allow for this session"),
                Option(decision: .decline, label: "Deny"),
            ]
        case .userInput:
            return []
        }
    }

    private func withSessionOption(_ options: [Option]) -> [Option] {
        offersSessionAllow ? options : options.filter { $0.decision != .acceptForSession }
    }

    /// True when `decision` is a valid answer to this request. Answers must
    /// name every question exactly once with one of its choice labels.
    public func permits(_ decision: CanvasAgentRequestDecision) -> Bool {
        guard !terminalOnly else { return false }
        switch decision {
        case .answers(let answers):
            guard kind == .userInput, answers.count == questions.count else { return false }
            return questions.allSatisfy { question in
                guard let label = answers[question.id] else { return false }
                return question.choices.contains { $0.label == label }
            }
        case .accept, .acceptForSession, .decline, .cancel:
            return options.contains { $0.decision == decision }
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case key, kind, isHumanCheckpoint, command, cwd, reason, grantRoot, permissions
        case questions, terminalOnly, offersSessionAllow, receivedAt
    }

    /// Decodes, then re-sanitizes. A value that the sanitizer would change is
    /// rejected, so the app never shows unbounded or unclean text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try Self(
            key: container.decode(UUID.self, forKey: .key),
            kind: container.decode(Kind.self, forKey: .kind),
            isHumanCheckpoint: container.decode(Bool.self, forKey: .isHumanCheckpoint),
            command: container.decodeIfPresent(String.self, forKey: .command),
            cwd: container.decodeIfPresent(String.self, forKey: .cwd),
            reason: container.decodeIfPresent(String.self, forKey: .reason),
            grantRoot: container.decodeIfPresent(String.self, forKey: .grantRoot),
            permissions: container.decode([String].self, forKey: .permissions),
            questions: container.decode([Question].self, forKey: .questions),
            terminalOnly: container.decode(Bool.self, forKey: .terminalOnly),
            // An older peer does not send it; the Codex answers all allow a session.
            offersSessionAllow: container.decodeIfPresent(Bool.self, forKey: .offersSessionAllow)
                ?? true,
            receivedAt: container.decode(Date.self, forKey: .receivedAt),
            unchecked: ()
        )
        let sanitized = Self(
            key: decoded.key, kind: decoded.kind, isHumanCheckpoint: decoded.isHumanCheckpoint,
            command: decoded.command, cwd: decoded.cwd, reason: decoded.reason,
            grantRoot: decoded.grantRoot, permissions: decoded.permissions,
            questions: decoded.questions, terminalOnly: decoded.terminalOnly,
            offersSessionAllow: decoded.offersSessionAllow, receivedAt: decoded.receivedAt)
        guard sanitized == decoded else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The approval is not sanitized."))
        }
        self = sanitized
    }

    /// Stores decoded fields as they are, for the comparison in `init(from:)`.
    private init(
        key: UUID, kind: Kind, isHumanCheckpoint: Bool, command: String?, cwd: String?,
        reason: String?, grantRoot: String?, permissions: [String], questions: [Question],
        terminalOnly: Bool, offersSessionAllow: Bool, receivedAt: Date, unchecked: Void
    ) {
        self.key = key
        self.kind = kind
        self.isHumanCheckpoint = isHumanCheckpoint
        self.command = command
        self.cwd = cwd
        self.reason = reason
        self.grantRoot = grantRoot
        self.permissions = permissions
        self.questions = questions
        self.terminalOnly = terminalOnly
        self.offersSessionAllow = offersSessionAllow
        self.receivedAt = receivedAt
    }

    // MARK: Sanitizing

    /// True when `command` has more than `Limits.blankLinesInRow` blank lines
    /// in a row or a run of more than `Limits.whitespaceRun` spaces and tabs.
    /// Such blank space can push the end of a command out of view, so a
    /// command with it is terminal-only.
    static func hidesText(_ command: String) -> Bool {
        var blankLines = 0
        var lineHasText = false
        var run = 0
        for scalar in command.unicodeScalars {
            if scalar == "\n" {
                blankLines = lineHasText ? 0 : blankLines + 1
                if blankLines > Limits.blankLinesInRow { return true }
                lineHasText = false
                run = 0
            } else if scalar.properties.isWhitespace {
                run += 1
                if run > Limits.whitespaceRun { return true }
            } else {
                lineHasText = true
                run = 0
            }
        }
        return false
    }

    /// Removes control characters and format characters, then cuts the
    /// text to `limit` UTF-8 bytes at a character boundary. `altered` is true
    /// when anything was removed or cut.
    static func clean(_ text: String, limit: Int, keepsLineBreaks: Bool) -> (
        text: String, altered: Bool
    ) {
        var scalars = String.UnicodeScalarView()
        var altered = false
        for scalar in text.unicodeScalars {
            if keepsLineBreaks, scalar == "\n" || scalar == "\t" {
                scalars.append(scalar)
            } else if isUnsafe(scalar) {
                altered = true
            } else {
                scalars.append(scalar)
            }
        }
        let stripped = String(scalars)
        guard stripped.utf8.count > limit else { return (stripped, altered) }
        var result = ""
        var used = 0
        for character in stripped {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return (result, true)
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        // Format characters (Cf) are invisible or change how text displays:
        // bidirectional marks, embeddings, overrides and isolates, zero-width
        // spaces and joiners (U+200B to U+200D, U+2060, U+FEFF), the soft
        // hyphen (U+00AD) and the Arabic letter mark (U+061C).
        case .control, .format: return true
        // Line and paragraph separators break a single-line layout.
        case .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}

/// The user's answer to a `CanvasAgentRequest`.
public nonisolated enum CanvasAgentRequestDecision: Codable, Hashable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
    /// Question id to the chosen choice label, one entry per question.
    case answers([String: String])

    /// The wire name: also the Codex decision value for the four verdicts.
    public var name: String {
        switch self {
        case .accept: "accept"
        case .acceptForSession: "acceptForSession"
        case .decline: "decline"
        case .cancel: "cancel"
        case .answers: "answers"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, answers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "accept": self = .accept
        case "acceptForSession": self = .acceptForSession
        case "decline": self = .decline
        case "cancel": self = .cancel
        case "answers":
            let answers = try container.decode([String: String].self, forKey: .answers)
            guard answers.count <= CanvasAgentRequest.Limits.questions else {
                throw DecodingError.dataCorruptedError(
                    forKey: .answers, in: container, debugDescription: "Too many answers.")
            }
            self = .answers(answers)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown decision.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        if case .answers(let answers) = self {
            try container.encode(answers, forKey: .answers)
        }
    }
}

/// A decision for one pending request, as `approvalPoll` returns it.
public nonisolated struct CanvasAgentRequestAnswer: Codable, Hashable, Sendable {
    public let key: UUID
    public let decision: CanvasAgentRequestDecision

    public init(key: UUID, decision: CanvasAgentRequestDecision) {
        self.key = key
        self.decision = decision
    }
}

// MARK: Codex app-server mapping

extension CanvasAgentRequest {
    /// The bridge operations. The supervisor sends them on its `exchange` path.
    public static let openOperation = "approvalOpen"
    public static let pollOperation = "approvalPoll"
    public static let closeOperation = "approvalClose"
    public static let operations: Set<String> = [openOperation, pollOperation, closeOperation]

    /// Builds a sanitized approval from a Codex app-server request, or nil
    /// when the method is not one Rafu can show. The caller checks the thread.
    public static func parse(
        method: String, params: [String: Any], key: UUID = UUID(), receivedAt: Date = Date()
    ) -> CanvasAgentRequest? {
        switch method {
        case "item/commandExecution/requestApproval":
            let commandKind = params["kind"] as? String ?? "command"
            let knownKind = ["command", "writeStdin", "humanCommand"].contains(commandKind)
            // A network approval asks for more than the command shows (the
            // host and the protocol), so only the terminal can answer it.
            let asksNetwork = params["networkApprovalContext"].map { !($0 is NSNull) } ?? false
            return CanvasAgentRequest(
                key: key, kind: .command, isHumanCheckpoint: commandKind == "humanCommand",
                command: params["command"] as? String, cwd: params["cwd"] as? String,
                reason: params["reason"] as? String, terminalOnly: !knownKind || asksNetwork,
                receivedAt: receivedAt)
        case "item/fileChange/requestApproval":
            // The params carry no diff, so the row cannot show the change.
            return CanvasAgentRequest(
                key: key, kind: .fileChange, reason: params["reason"] as? String,
                grantRoot: params["grantRoot"] as? String, terminalOnly: true,
                receivedAt: receivedAt)
        case "item/permissions/requestApproval":
            let summary = permissionSummary(params["permissions"])
            return CanvasAgentRequest(
                key: key, kind: .permissions, cwd: params["cwd"] as? String,
                reason: params["reason"] as? String, permissions: summary.lines,
                terminalOnly: !summary.complete, receivedAt: receivedAt)
        case "item/tool/requestUserInput":
            let raw = params["questions"] as? [Any] ?? []
            var questions: [Question] = []
            var complete = params["questions"] is [Any]
            for item in raw.prefix(Limits.questions + 1) {
                guard let object = item as? [String: Any], let id = object["id"] as? String,
                    let text = object["question"] as? String
                else {
                    complete = false
                    continue
                }
                let options = object["options"] as? [Any] ?? []
                var choices: [Choice] = []
                for option in options.prefix(Limits.choices + 1) {
                    guard let option = option as? [String: Any],
                        let label = option["label"] as? String
                    else {
                        complete = false
                        continue
                    }
                    choices.append(
                        Choice(label: label, detail: option["description"] as? String ?? ""))
                }
                questions.append(
                    Question(
                        id: id, header: object["header"] as? String ?? "", text: text,
                        choices: choices, isOther: object["isOther"] as? Bool ?? false,
                        isSecret: object["isSecret"] as? Bool ?? false,
                        terminalOnly: choices.count != options.count))
            }
            return CanvasAgentRequest(
                key: key, kind: .userInput, questions: questions,
                terminalOnly: !complete || questions.count != raw.count,
                receivedAt: receivedAt)
        default:
            return nil
        }
    }

    /// The JSON-RPC `result` object that answers this request with
    /// `decision`, or nil when the decision is not valid for it. A
    /// permissions request needs the profile it asked for (`params.permissions`):
    /// accepting grants exactly that profile; declining grants nothing.
    public func result(
        for decision: CanvasAgentRequestDecision, requestedPermissions: Any? = nil
    ) -> [String: Any]? {
        guard permits(decision) else { return nil }
        switch (kind, decision) {
        case (.userInput, .answers(let answers)):
            return ["answers": answers.mapValues { ["answers": [$0]] }]
        case (.permissions, .decline):
            return ["permissions": [String: Any](), "scope": "turn"]
        case (.permissions, .accept), (.permissions, .acceptForSession):
            guard let requested = requestedPermissions as? [String: Any] else { return nil }
            return [
                "permissions": requested,
                "scope": decision == .acceptForSession ? "session" : "turn",
            ]
        case (.command, _), (.fileChange, _):
            return ["decision": decision.name]
        default:
            return nil
        }
    }

    /// One readable line per requested grant. `complete` is false when part
    /// of the profile has a shape Rafu does not know.
    static func permissionSummary(_ value: Any?) -> (lines: [String], complete: Bool) {
        guard let profile = value as? [String: Any] else { return ([], false) }
        var lines: [String] = []
        var complete = Set(profile.keys).isSubset(of: ["fileSystem", "network"])
        if let network = profile["network"] as? [String: Any] {
            if network["enabled"] as? Bool == true { lines.append("Network access") }
        } else if profile["network"] != nil, !(profile["network"] is NSNull) {
            complete = false
        }
        if let fileSystem = profile["fileSystem"] as? [String: Any] {
            for path in fileSystem["read"] as? [String] ?? [] { lines.append("Read \(path)") }
            for path in fileSystem["write"] as? [String] ?? [] { lines.append("Write \(path)") }
            for entry in fileSystem["entries"] as? [Any] ?? [] {
                guard let entry = entry as? [String: Any],
                    let access = entry["access"] as? String,
                    let path = entry["path"] as? [String: Any],
                    let target = path["path"] as? String ?? path["pattern"] as? String
                        ?? (path["value"] as? [String: Any])?["kind"] as? String
                else {
                    complete = false
                    continue
                }
                lines.append("\(access.capitalized) \(target)")
            }
        } else if profile["fileSystem"] != nil, !(profile["fileSystem"] is NSNull) {
            complete = false
        }
        return (lines, complete)
    }
}
