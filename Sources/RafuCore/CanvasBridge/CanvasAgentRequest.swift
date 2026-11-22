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
        /// Use a tool of an MCP server: a Claude Code hook request, or a Codex
        /// `mcpServer/elicitation/request` that asks to run a tool. `command`
        /// holds the arguments as JSON text and `reason` the tool identity
        /// (see `AgentPermissionRequestSummary.toolReason(name:)`). Also a
        /// Claude Code built-in tool that has no card of its own.
        case toolCall
        /// A plan the agent asks the user to approve (Claude Code
        /// `ExitPlanMode`). `reason` holds the plan file path and `text` the
        /// plan. Always terminal-only: the answer payload is not documented.
        case plan
        /// A prompt Rafu can only show: `reason` holds one line that names
        /// the prompt ("Network request", "Claude Code asks to use X") and
        /// `text` the agent's own message, if any. Always terminal-only.
        case notice
    }

    /// One file the agent asks to change, with the whole change: the full new
    /// content of a created or overwritten file, or the full diff (or the
    /// removed and added lines) of an edit. The request keeps it only when it
    /// fits the bounds exactly, so the row can show all of it.
    public struct FileChange: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable {
            case create, overwrite, edit, delete, move
        }

        public let path: String
        public let kind: Kind
        /// The new content (`isDiff` false) or the diff (`isDiff` true).
        public let body: String
        public let isDiff: Bool
        /// The new path of a move.
        public let movePath: String?

        public init(
            path: String, kind: Kind, body: String, isDiff: Bool, movePath: String? = nil
        ) {
            self.path = path
            self.kind = kind
            self.body = body
            self.isDiff = isDiff
            self.movePath = movePath
        }
    }

    /// A button the user can choose. Derived from the kind; never sent.
    public struct Option: Hashable, Sendable {
        public let decision: CanvasAgentRequestDecision
        public let label: String
        /// A stable identifier, unique among the options of one request.
        public var id: String { decision.identifier }
    }

    /// One choice of a question. The `label` is the answer sent back.
    public struct Choice: Codable, Hashable, Sendable {
        public let label: String
        public let detail: String
        /// Plain text the agent shows next to the choice (Claude Code
        /// `preview`). Display only: it is never part of the answer.
        public let preview: String?

        public init(label: String, detail: String, preview: String? = nil) {
            self.label = label
            self.detail = detail
            self.preview = preview
        }
    }

    /// A choice that also tells the agent to remember the grant. Each one
    /// shows its exact effect as its `line`, for example "Always allow
    /// google_calendar.create_event for Codex". `PersistPolicy` decides
    /// which kinds the row offers; see `options(policy:)`.
    public struct PersistChoice: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
            /// Remember for this session only (Codex `persist: "session"`).
            case session
            /// Remember for always (Codex `persist: "always"`).
            case always
            /// Write a permission rule (Claude Code `updatedPermissions`, the
            /// Codex command prefix rule).
            case rule

            /// True for a grant that outlives the session.
            public var isLasting: Bool { self != .session }
        }

        public let kind: Kind
        /// One line that states exactly what is remembered.
        public let line: String

        public init(kind: Kind, line: String) {
            self.kind = kind
            self.line = line
        }
    }

    /// Which remember choices the row may offer. The decision record about
    /// answering agent requests from the Up next row says Rafu never sends
    /// `persist` or `updatedPermissions`, so `current` offers none. The user
    /// has not yet agreed to change that.
    public struct PersistPolicy: Hashable, Sendable {
        public var allowsSession: Bool
        public var allowsLasting: Bool

        public init(allowsSession: Bool, allowsLasting: Bool) {
            self.allowsSession = allowsSession
            self.allowsLasting = allowsLasting
        }

        /// The policy the app uses: both off.
        public static let current = PersistPolicy(allowsSession: false, allowsLasting: false)
        /// Every remember choice on. For tests, and for a later user decision.
        public static let all = PersistPolicy(allowsSession: true, allowsLasting: true)

        public func allows(_ kind: PersistChoice.Kind) -> Bool {
            kind.isLasting ? allowsLasting : allowsSession
        }
    }

    /// One multiple-choice question.
    public struct Question: Codable, Hashable, Sendable {
        public let id: String
        public let header: String
        public let text: String
        public let choices: [Choice]
        /// The user may choose more than one choice (Claude Code
        /// `multiSelect`). Always false for Codex.
        public let allowsMultiple: Bool
        /// The user may type an answer of their own (Claude Code: always;
        /// Codex: `isOther`).
        public let allowsFreeText: Bool
        /// The question is secret, did not fit the bounds exactly, has two
        /// choices with one label, or is a multiple-choice question with a
        /// label that holds `", "` (the joined answer would be ambiguous).
        /// Only the terminal can answer it.
        public let terminalOnly: Bool

        /// Sanitizes one question. `isSecret` makes it terminal-only.
        /// `isOther` allows free text: Codex 0.170.0 sets it on every
        /// question the model asks (the terminal shows "None of the above").
        public init(
            id: String, header: String, text: String, choices: [Choice],
            allowsMultiple: Bool = false, allowsFreeText: Bool = false,
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
                // Claude Code joins the chosen labels with ", ".
                restricted =
                    restricted || (allowsMultiple && label.text.contains(Self.labelSeparator))
                let detail = CanvasAgentRequest.clean(
                    choice.detail, limit: Limits.detailBytes, keepsLineBreaks: false)
                let preview = choice.preview.map {
                    CanvasAgentRequest.clean($0, limit: Limits.previewBytes, keepsLineBreaks: true)
                        .text
                }
                kept.append(
                    Choice(
                        label: label.text, detail: detail.text,
                        preview: preview?.isEmpty == true ? nil : preview))
            }
            // Two choices with one label cannot be told apart in an answer.
            restricted = restricted || Set(kept.map(\.label)).count != kept.count
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
            self.allowsMultiple = allowsMultiple
            self.allowsFreeText = allowsFreeText || isOther
            self.terminalOnly = restricted
        }

        /// What Claude Code puts between two chosen labels of one answer.
        public static let labelSeparator = ", "

        /// True when `answer` is a valid answer to this question: every
        /// label is one of the choices and no label comes twice; a text only
        /// when free text is allowed, within `Limits.freeTextBytes`, on one
        /// line, unchanged by sanitizing and not blank. A single-choice
        /// question takes exactly one label or a text; a multiple-choice
        /// question takes at least one label, a text, or both.
        public func accepts(_ answer: QuestionAnswer) -> Bool {
            guard !terminalOnly, Set(answer.labels).count == answer.labels.count,
                answer.labels.allSatisfy({ label in choices.contains { $0.label == label } })
            else { return false }
            if let text = answer.text {
                let clean = CanvasAgentRequest.clean(
                    text, limit: Limits.freeTextBytes, keepsLineBreaks: false)
                guard allowsFreeText, !clean.altered,
                    !text.trimmingCharacters(in: .whitespaces).isEmpty
                else { return false }
            }
            if allowsMultiple { return !answer.labels.isEmpty || answer.text != nil }
            return (answer.labels.count == 1 && answer.text == nil)
                || (answer.labels.isEmpty && answer.text != nil)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try (
                id: container.decode(String.self, forKey: .id),
                header: container.decode(String.self, forKey: .header),
                text: container.decode(String.self, forKey: .text),
                choices: container.decode([Choice].self, forKey: .choices),
                // An older peer does not send these two.
                allowsMultiple: container.decodeIfPresent(Bool.self, forKey: .allowsMultiple)
                    ?? false,
                allowsFreeText: container.decodeIfPresent(Bool.self, forKey: .allowsFreeText)
                    ?? false,
                terminalOnly: container.decode(Bool.self, forKey: .terminalOnly)
            )
            self.init(
                id: raw.id, header: raw.header, text: raw.text, choices: raw.choices,
                allowsMultiple: raw.allowsMultiple, allowsFreeText: raw.allowsFreeText,
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
        /// The most body text (new content or diff) of one file change.
        public static let fileChangeBodyBytes = 4 * 1_024
        /// The most file changes one request carries. More makes it terminal-only.
        public static let fileChanges = 2
        public static let filePathBytes = 480
        public static let questions = 4
        public static let choices = 6
        public static let identifierBytes = 128
        public static let headerBytes = 128
        public static let questionBytes = 512
        public static let labelBytes = 128
        public static let detailBytes = 256
        /// The most preview text of one choice. Display only.
        public static let previewBytes = 2 * 1_024
        /// The most preview text of all choices of one request together. A
        /// preview past it is dropped (it is display only), so the largest
        /// request stays inside one IPC frame and one spool file.
        public static let previewBytesTotal = 8 * 1_024
        /// The most text the user may type as the answer to one question.
        public static let freeTextBytes = 1_024
        /// The most plan text of a `.plan` request. Longer is cut.
        public static let planBytes = 4 * 1_024
        /// The most agent text of a `.notice` request. Longer is cut.
        public static let noticeBytes = 512
        /// The most remember choices one request carries.
        public static let persistChoices = 3
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
    /// For a permissions request: one short line per requested grant. For a
    /// command: the extra facts the row must show beside it, such as the
    /// network target ("Network: https example.com").
    public let permissions: [String]
    /// For a file change: the whole change of each file.
    public let fileChanges: [FileChange]
    public let questions: [Question]
    /// The agent's own text: the plan of a `.plan` request, the message of
    /// a `.notice` request. Nil for every other kind. Display only.
    public let text: String?
    /// `text` was cut to its bound or changed by sanitizing. The row marks it.
    public let textIsCut: Bool
    /// The remember choices the agent offers, at most one per kind. Only a
    /// command (not a checkpoint) or a tool call carries them.
    public let persistChoices: [PersistChoice]
    /// "Cancel" also stops the agent's turn. False for a Codex tool call,
    /// where cancel only skips the call: the row then says "Cancel tool
    /// call", never "Deny and stop".
    public let stopsTurnOnCancel: Bool
    /// Only the terminal can answer: the request did not fit the bounds
    /// exactly, the command text was changed by sanitizing or could hide text
    /// behind blank space, a question is secret or terminal-only, the request
    /// is a plan or a notice, or the request is a file change that does not carry its whole change (no
    /// change, too many files, a cut or changed path or body). The row then
    /// offers only "Open terminal".
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
        grantRoot: String? = nil, permissions: [String] = [], fileChanges: [FileChange] = [],
        questions: [Question] = [], text: String? = nil, textIsCut: Bool = false,
        persistChoices: [PersistChoice] = [], stopsTurnOnCancel: Bool = true,
        terminalOnly: Bool = false, offersSessionAllow: Bool = true, receivedAt: Date = Date()
    ) {
        // A plan or a notice is only shown: the terminal answers it.
        var restricted = terminalOnly || kind == .plan || kind == .notice
        // A file change is answerable only when the row shows the whole
        // change: what the user reads must be all that would happen.
        var changes: [FileChange] = []
        if kind == .fileChange {
            if fileChanges.isEmpty || fileChanges.count > Limits.fileChanges { restricted = true }
            for change in fileChanges.prefix(Limits.fileChanges) {
                let path = Self.clean(
                    change.path, limit: Limits.filePathBytes, keepsLineBreaks: false)
                let moved = change.movePath.map {
                    Self.clean($0, limit: Limits.filePathBytes, keepsLineBreaks: false)
                }
                let body = Self.clean(
                    change.body, limit: Limits.fileChangeBodyBytes, keepsLineBreaks: true)
                restricted =
                    restricted || path.altered || path.text.isEmpty || body.altered
                    || Self.hidesText(body.text) || moved?.altered == true
                    || moved?.text.isEmpty == true
                    || (change.isDiff && body.text.isEmpty && change.kind == .edit)
                changes.append(
                    FileChange(
                        path: path.text, kind: change.kind, body: body.text,
                        isDiff: change.isDiff, movePath: moved?.text))
            }
        }
        // Only a command or a tool call carries a command (the arguments).
        let cleanCommand = (kind == .command || kind == .toolCall ? command : nil).map {
            Self.clean($0, limit: Limits.commandBytes, keepsLineBreaks: true)
        }
        // What the user reads must be exactly what runs.
        if let cleanCommand,
            cleanCommand.altered || cleanCommand.text.isEmpty
                || Self.hidesText(cleanCommand.text)
        {
            restricted = true
        }
        if kind == .command || kind == .toolCall, cleanCommand == nil { restricted = true }
        // A tool call names its tool in `reason`: no identity, or one the
        // sanitizer changed, means the row would not show what is used.
        if kind == .toolCall {
            let identity = reason.map {
                Self.clean($0, limit: Limits.reasonBytes, keepsLineBreaks: true)
            }
            if identity == nil || identity?.altered == true || identity?.text.isEmpty == true {
                restricted = true
            }
        }
        var lines: [String] = []
        for line in permissions.prefix(Limits.permissionLines) {
            let clean = Self.clean(line, limit: Limits.permissionLineBytes, keepsLineBreaks: false)
            restricted = restricted || clean.altered || clean.text.isEmpty
            lines.append(clean.text)
        }
        if permissions.count > Limits.permissionLines { restricted = true }
        if kind == .permissions, lines.isEmpty { restricted = true }
        let kept =
            kind == .userInput
            ? Self.withinPreviewBudget(Array(questions.prefix(Limits.questions))) : []
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
        self.permissions = kind == .permissions || kind == .command ? lines : []
        self.fileChanges = changes
        self.questions = kept
        let textLimit: Int? =
            switch kind {
            case .plan: Limits.planBytes
            case .notice: Limits.noticeBytes
            default: nil
            }
        let cleanText = textLimit.flatMap { limit in
            text.map { Self.clean($0, limit: limit, keepsLineBreaks: true) }
        }
        self.text = cleanText?.text
        self.textIsCut = cleanText.map { textIsCut || $0.altered } ?? false
        var choices: [PersistChoice] = []
        let carriesPersist = (kind == .command && !isHumanCheckpoint) || kind == .toolCall
        for choice in persistChoices where carriesPersist {
            let line = Self.clean(choice.line, limit: Limits.reasonBytes, keepsLineBreaks: false)
            // A choice that does not show its whole effect is dropped.
            guard !line.altered, !line.text.isEmpty, choices.count < Limits.persistChoices,
                !choices.contains(where: { $0.kind == choice.kind })
            else { continue }
            choices.append(PersistChoice(kind: choice.kind, line: line.text))
        }
        self.persistChoices = choices
        self.stopsTurnOnCancel = stopsTurnOnCancel
        self.terminalOnly = restricted
        self.offersSessionAllow = offersSessionAllow
        self.receivedAt = receivedAt
    }

    // MARK: Options and decisions

    /// The buttons for this request under `PersistPolicy.current`.
    public var options: [Option] { options(policy: .current) }

    /// The buttons for this request, in display order. Empty when only the
    /// terminal can answer, and for questions (the answer is the choice).
    /// A remember choice shows only when `policy` allows its kind, and never
    /// first: the first option is the primary button.
    public func options(policy: PersistPolicy) -> [Option] {
        guard !terminalOnly else { return [] }
        let remember = persistChoices.filter { policy.allows($0.kind) }.map {
            Option(decision: .acceptAndRemember($0.kind), label: $0.line)
        }
        let cancelLabel = stopsTurnOnCancel ? "Deny and stop" : "Cancel tool call"
        switch kind {
        case .command where isHumanCheckpoint:
            return [
                Option(decision: .accept, label: "Run"),
                Option(decision: .decline, label: "Deny"),
                Option(decision: .cancel, label: "Deny and stop"),
            ]
        case .command:
            return withSessionOption(
                [
                    Option(decision: .accept, label: "Run"),
                    Option(decision: .acceptForSession, label: "Allow for this session"),
                ] + remember + [
                    Option(decision: .decline, label: "Deny"),
                    Option(decision: .cancel, label: cancelLabel),
                ])
        case .fileChange:
            return withSessionOption([
                Option(decision: .accept, label: "Allow"),
                Option(decision: .acceptForSession, label: "Allow for this session"),
                Option(decision: .decline, label: "Deny"),
                Option(decision: .cancel, label: "Deny and stop"),
            ])
        case .permissions:
            return [
                Option(decision: .accept, label: "Allow for this turn"),
                Option(decision: .acceptForSession, label: "Allow for this session"),
                Option(decision: .decline, label: "Deny"),
            ]
        case .toolCall:
            // No `acceptForSession`, also when `offersSessionAllow` is true:
            // a Claude Code hook has no such answer for a tool. A Codex
            // session grant is the remember choice `session`, off by policy.
            return [Option(decision: .accept, label: "Allow")] + remember + [
                Option(decision: .decline, label: "Deny"),
                Option(decision: .cancel, label: cancelLabel),
            ]
        case .userInput, .plan, .notice:
            return []
        }
    }

    private func withSessionOption(_ options: [Option]) -> [Option] {
        offersSessionAllow ? options : options.filter { $0.decision != .acceptForSession }
    }

    /// True when `decision` is a valid answer to this request. Answers must
    /// name every question exactly once, and each answer must pass
    /// `Question.accepts(_:)`. A remember choice must be offered under
    /// `policy`.
    public func permits(
        _ decision: CanvasAgentRequestDecision, policy: PersistPolicy = .current
    ) -> Bool {
        guard !terminalOnly else { return false }
        switch decision {
        case .answers(let answers):
            guard kind == .userInput, answers.count == questions.count else { return false }
            return questions.allSatisfy { question in
                guard let answer = answers[question.id] else { return false }
                return question.accepts(answer)
            }
        case .accept, .acceptForSession, .decline, .cancel, .acceptAndRemember:
            return options(policy: policy).contains { $0.decision == decision }
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case key, kind, isHumanCheckpoint, command, cwd, reason, grantRoot, permissions
        case fileChanges, questions, terminalOnly, offersSessionAllow, receivedAt
        case text, textIsCut, persistChoices, stopsTurnOnCancel
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
            // An older peer does not send it.
            fileChanges: container.decodeIfPresent([FileChange].self, forKey: .fileChanges) ?? [],
            questions: container.decode([Question].self, forKey: .questions),
            // An older peer does not send the next four.
            text: container.decodeIfPresent(String.self, forKey: .text),
            textIsCut: container.decodeIfPresent(Bool.self, forKey: .textIsCut) ?? false,
            persistChoices: container.decodeIfPresent(
                [PersistChoice].self, forKey: .persistChoices) ?? [],
            stopsTurnOnCancel: container.decodeIfPresent(Bool.self, forKey: .stopsTurnOnCancel)
                ?? true,
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
            fileChanges: decoded.fileChanges,
            questions: decoded.questions, text: decoded.text, textIsCut: decoded.textIsCut,
            persistChoices: decoded.persistChoices, stopsTurnOnCancel: decoded.stopsTurnOnCancel,
            terminalOnly: decoded.terminalOnly,
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
        reason: String?, grantRoot: String?, permissions: [String], fileChanges: [FileChange],
        questions: [Question], text: String?, textIsCut: Bool, persistChoices: [PersistChoice],
        stopsTurnOnCancel: Bool,
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
        self.fileChanges = fileChanges
        self.questions = questions
        self.text = text
        self.textIsCut = textIsCut
        self.persistChoices = persistChoices
        self.stopsTurnOnCancel = stopsTurnOnCancel
        self.terminalOnly = terminalOnly
        self.offersSessionAllow = offersSessionAllow
        self.receivedAt = receivedAt
    }

    // MARK: Sanitizing

    /// `questions` with every preview past `Limits.previewBytesTotal`
    /// dropped, in order. A question without a dropped preview is unchanged.
    static func withinPreviewBudget(_ questions: [Question]) -> [Question] {
        var budget = Limits.previewBytesTotal
        return questions.map { question in
            var dropped = false
            let choices = question.choices.map { choice -> Choice in
                guard let preview = choice.preview else { return choice }
                let size = preview.utf8.count
                guard size <= budget else {
                    dropped = true
                    return Choice(label: choice.label, detail: choice.detail)
                }
                budget -= size
                return choice
            }
            guard dropped else { return question }
            return Question(
                id: question.id, header: question.header, text: question.text, choices: choices,
                allowsMultiple: question.allowsMultiple, allowsFreeText: question.allowsFreeText,
                terminalOnly: question.terminalOnly)
        }
    }

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

/// The answer to one question: the chosen labels and the text the user
/// typed. `CanvasAgentRequest.Question.accepts(_:)` says which forms are
/// valid. A string literal is one chosen label.
///
/// On the wire, one label and no text is the plain label string (the form an
/// older peer sends and reads); any other answer is `{labels, text}`.
public nonisolated struct QuestionAnswer: Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let labels: [String]
    public let text: String?

    public init(labels: [String] = [], text: String? = nil) {
        self.labels = labels
        self.text = text
    }

    public init(stringLiteral value: String) {
        self.init(labels: [value])
    }

    private enum CodingKeys: String, CodingKey { case labels, text }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let label = try? single.decode(String.self)
        {
            self.init(labels: [label])
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        // Bound what an answer can hold; `accepts(_:)` checks the rest.
        guard labels.count <= CanvasAgentRequest.Limits.choices,
            (text?.utf8.count ?? 0) <= CanvasAgentRequest.Limits.freeTextBytes
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "The answer is too big."))
        }
        self.init(labels: labels, text: text)
    }

    public func encode(to encoder: any Encoder) throws {
        if labels.count == 1, text == nil {
            var single = encoder.singleValueContainer()
            try single.encode(labels[0])
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(labels, forKey: .labels)
        try container.encodeIfPresent(text, forKey: .text)
    }
}

/// The user's answer to a `CanvasAgentRequest`.
public nonisolated enum CanvasAgentRequestDecision: Codable, Hashable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
    /// Accept, and remember the grant as the request's `PersistChoice` of
    /// this kind. Valid only when `PersistPolicy` allows the kind.
    case acceptAndRemember(CanvasAgentRequest.PersistChoice.Kind)
    /// Question id to its answer, one entry per question.
    case answers([String: QuestionAnswer])

    /// Question id to one chosen label each: the answer form of a set of
    /// single-choice questions.
    public static func answers(labels: [String: String]) -> Self {
        .answers(labels.mapValues { QuestionAnswer(labels: [$0]) })
    }

    /// The wire name: also the Codex decision value for the four verdicts.
    public var name: String {
        switch self {
        case .accept: "accept"
        case .acceptForSession: "acceptForSession"
        case .decline: "decline"
        case .cancel: "cancel"
        case .acceptAndRemember: "acceptAndRemember"
        case .answers: "answers"
        }
    }

    /// The name, with the remember kind for `acceptAndRemember`. Unique
    /// among the options of one request.
    public var identifier: String {
        if case .acceptAndRemember(let kind) = self { return name + "." + kind.rawValue }
        return name
    }

    private enum CodingKeys: String, CodingKey { case type, answers, persist }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "accept": self = .accept
        case "acceptForSession": self = .acceptForSession
        case "decline": self = .decline
        case "cancel": self = .cancel
        case "acceptAndRemember":
            self = .acceptAndRemember(
                try container.decode(
                    CanvasAgentRequest.PersistChoice.Kind.self, forKey: .persist))
        case "answers":
            // `QuestionAnswer` also reads the older form, one label string.
            let answers = try container.decode([String: QuestionAnswer].self, forKey: .answers)
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
        switch self {
        case .answers(let answers): try container.encode(answers, forKey: .answers)
        case .acceptAndRemember(let kind): try container.encode(kind, forKey: .persist)
        default: break
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

    /// What a Codex app-server request method asks of the user, by name only.
    public enum CodexRequestClass: String, Hashable, Sendable, CaseIterable {
        case command, fileChange, permissions, userInput
        /// `mcpServer/elicitation/request`: a tool approval, a form, or a URL.
        case elicitation
        /// `applyPatchApproval`, `execCommandApproval`: the older approval API.
        case legacyApproval
        /// A server request that is not a prompt for the user (a dynamic
        /// tool call, a token refresh, an attestation).
        case notUserPrompt
        /// A method this build does not know.
        case unclassified
    }

    /// The class of a Codex server request method. Every method of the Codex
    /// 0.171.0 `ServerRequest` schema has a class other than `unclassified`
    /// (see `AgentPromptCoverageTests`).
    public static func classify(method: String) -> CodexRequestClass {
        switch method {
        case "item/commandExecution/requestApproval": .command
        case "item/fileChange/requestApproval": .fileChange
        case "item/permissions/requestApproval": .permissions
        case "item/tool/requestUserInput": .userInput
        case "mcpServer/elicitation/request": .elicitation
        case "applyPatchApproval", "execCommandApproval": .legacyApproval
        case "item/tool/call", "account/chatgptAuthTokens/refresh", "attestation/generate":
            .notUserPrompt
        default: .unclassified
        }
    }

    /// The label Codex sends for a free-text answer with no chosen label:
    /// the "other" row its terminal adds to every question with `isOther`.
    /// Checked in the Codex 0.171.0 source (`request_user_input`).
    public static let codexOtherLabel = "None of the above"
    /// The prefix Codex puts before a typed note in a question answer.
    public static let codexNotePrefix = "user_note: "

    /// What `parseCodex` found: the request for the row, and, when Rafu could
    /// not fully show it, its shape (key names and value types only, never a
    /// value) for `AgentRequestShape.Recorder`.
    public struct CodexParse: Sendable {
        public let request: CanvasAgentRequest?
        public let shape: String?
    }

    /// The `_meta` keys of a Codex tool approval that Rafu knows. Checked in
    /// the Codex 0.171.0 source (`build_mcp_tool_approval_elicitation_meta`,
    /// tag `rust-v0.171.0`). A key outside this set and outside
    /// `forcingToolApprovalMetaKeys` may mean the request asks for more than
    /// the card shows, so the row then offers "Open terminal" only, and the
    /// shape recorder names the key.
    static let knownToolApprovalMetaKeys: Set<String> = [
        "codex_approval_kind", "persist", "tool_name", "tool_annotations", "tool_title",
        "tool_description", "source", "connector_id", "link_id", "link_is_implicit",
        "connector_name", "connector_description", "tool_params", "tool_params_display",
    ]

    /// The `_meta` keys that change what an approval means
    /// (`mcp_approval_meta.rs`). A request with one of them is terminal-only,
    /// whatever its value.
    static let forcingToolApprovalMetaKeys: Set<String> = [
        "codex_sensitive_action", "codex_requires_user_input", "codex_strict_auto_review",
        "approvals_reviewer",
    ]

    /// The id prefix Codex gives a tool approval that it sends as a question
    /// (`MCP_TOOL_APPROVAL_QUESTION_ID_PREFIX`).
    static let codexToolApprovalQuestionPrefix = "mcp_tool_call_approval"

    /// The network protocols of the Codex 0.171.0 schema
    /// (`NetworkApprovalProtocol`).
    private static let networkProtocols: Set<String> = ["http", "https", "socks5Tcp", "socks5Udp"]

    /// The most words of a command prefix that Rafu offers to remember.
    static let maximumAmendmentWords = 16
    /// The most bytes of the words of a command prefix, joined by spaces.
    static let maximumAmendmentBytes = 256

    /// Builds a sanitized approval from a Codex app-server request, or nil
    /// when the request is not a prompt for the user. The caller checks the
    /// thread. `fileChanges` are the changes the caller knows for a
    /// file-change request: the request params carry no diff, so the caller
    /// passes the patch it saw in an earlier notification. Without them the
    /// request is terminal-only.
    public static func parse(
        method: String, params: [String: Any], key: UUID = UUID(), receivedAt: Date = Date(),
        fileChanges: [FileChange] = []
    ) -> CanvasAgentRequest? {
        parseCodex(
            method: method, params: params, key: key, receivedAt: receivedAt,
            fileChanges: fileChanges
        ).request
    }

    /// Like `parse`, and also the shape of a request that Rafu can only show
    /// as a notice, or cannot answer because of an unknown `_meta` key. The
    /// request is nil only for a method that is not a prompt for the user
    /// (`CodexRequestClass.notUserPrompt`). Every other method gives a row,
    /// so no prompt is dropped without a trace.
    public static func parseCodex(
        method: String, params: [String: Any], key: UUID = UUID(), receivedAt: Date = Date(),
        fileChanges: [FileChange] = []
    ) -> CodexParse {
        func notice(_ reason: String, text: String? = nil) -> CodexParse {
            CodexParse(
                request: CanvasAgentRequest(
                    key: key, kind: .notice, reason: reason, text: text, receivedAt: receivedAt),
                shape: AgentRequestShape.describe(
                    name: method, value: params, keyNames: .recorded))
        }
        let openTerminal = " Open the terminal to answer."
        switch method {
        case "item/commandExecution/requestApproval":
            let commandKind = params["kind"] as? String ?? "command"
            let knownKind = ["command", "writeStdin", "humanCommand"].contains(commandKind)
            // A network approval shows its target and can be accepted or
            // declined. "Allow for this session" stays off for it: what that
            // would cover for a host is not verified.
            let network = networkContext(params["networkApprovalContext"])
            var lines: [String] = []
            var remember: [PersistChoice] = []
            var restricted = !knownKind
            var offersSession = true
            switch network {
            case .none:
                if commandKind == "command",
                    let words = execpolicyAmendment(fromCommandParams: params)
                {
                    remember = [PersistChoice(kind: .rule, line: execpolicyAmendmentLine(words))]
                }
            case .line(let line):
                lines = [line]
                offersSession = false
            case .invalid:
                restricted = true
                offersSession = false
            }
            return CodexParse(
                request: CanvasAgentRequest(
                    key: key, kind: .command, isHumanCheckpoint: commandKind == "humanCommand",
                    command: params["command"] as? String, cwd: params["cwd"] as? String,
                    reason: params["reason"] as? String, permissions: lines,
                    persistChoices: remember, terminalOnly: restricted,
                    offersSessionAllow: offersSession, receivedAt: receivedAt),
                shape: nil)
        case "item/fileChange/requestApproval":
            // The params carry no diff: the change comes from the patch
            // notification the caller saw. No patch, no answer from the row.
            // "Allow for this session" stays off: what a Codex session grant
            // covers for files is not verified.
            return CodexParse(
                request: CanvasAgentRequest(
                    key: key, kind: .fileChange, reason: params["reason"] as? String,
                    grantRoot: params["grantRoot"] as? String, fileChanges: fileChanges,
                    terminalOnly: fileChanges.isEmpty, offersSessionAllow: false,
                    receivedAt: receivedAt),
                shape: nil)
        case "item/permissions/requestApproval":
            let summary = permissionSummary(params["permissions"])
            return CodexParse(
                request: CanvasAgentRequest(
                    key: key, kind: .permissions, cwd: params["cwd"] as? String,
                    reason: params["reason"] as? String, permissions: summary.lines,
                    terminalOnly: !summary.complete, receivedAt: receivedAt),
                shape: nil)
        case "item/tool/requestUserInput":
            let raw = params["questions"] as? [Any] ?? []
            // Codex sends a tool approval as a question when its elicitation
            // feature is off. The question holds no arguments, so Rafu must
            // not offer an answer: the user could not see what runs.
            let approval = raw.lazy.compactMap { $0 as? [String: Any] }.first {
                ($0["id"] as? String)?.hasPrefix(codexToolApprovalQuestionPrefix) == true
            }
            if let approval {
                return notice(
                    "Tool approval: open the terminal to see the arguments.",
                    text: approval["question"] as? String)
            }
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
            return CodexParse(
                request: CanvasAgentRequest(
                    key: key, kind: .userInput, questions: questions,
                    terminalOnly: !complete || questions.count != raw.count,
                    receivedAt: receivedAt),
                shape: nil)
        case "mcpServer/elicitation/request":
            if let call = toolCallRequest(
                fromElicitation: params, key: key, receivedAt: receivedAt)
            {
                let shape = AgentRequestShape.describe(
                    name: method, value: params, keyNames: .recorded)
                return CodexParse(
                    request: call.request, shape: call.hasUnknownMeta ? shape : nil)
            }
            // Not a tool approval Rafu can show: a form that asks for data, a
            // link, a message-only approval, or a tool approval of a shape it
            // does not know. Show what the server says; the terminal answers.
            let meta = params["_meta"] as? [String: Any]
            let reason: String
            switch (meta?["codex_approval_kind"] as? String, params["mode"] as? String) {
            case ("mcp_tool_call", _): reason = "Codex needs your approval for an MCP tool."
            case ("browser_auth", _): reason = "Codex asks you to sign in with a browser."
            case ("tool_suggestion", _): reason = "Codex suggests an app or tool."
            case (_, "url"): reason = "An MCP server asks you to open a link."
            default:
                let schema = params["requestedSchema"] as? [String: Any]
                let properties = schema?["properties"] as? [String: Any]
                reason =
                    properties?.isEmpty == false
                    ? "An MCP server asks for information." : "An MCP server asks for approval."
            }
            return notice(reason + openTerminal, text: params["message"] as? String)
        case "applyPatchApproval", "execCommandApproval":
            // The older approval API. Shown only; the shape tells whether the
            // Codex terminal still sends it.
            let reason =
                method == "applyPatchApproval"
                ? "Codex asks to change files." : "Codex asks to run a command."
            return notice(reason + openTerminal, text: params["reason"] as? String)
        default:
            guard classify(method: method) == .unclassified else {
                return CodexParse(request: nil, shape: nil)
            }
            let word = method.split(separator: "/").last.map(String.init) ?? ""
            let name = AgentRequestShape.safeName(word)
            let reason =
                name == "?"
                ? "Codex sent a request that Rafu does not know."
                : "Codex sent a request named \(name)."
            return notice(reason + openTerminal)
        }
    }

    // MARK: Command approval details

    private enum NetworkContext {
        /// The request has no network context.
        case none
        /// "Network: <protocol> <host>".
        case line(String)
        /// A context Rafu cannot show whole.
        case invalid
    }

    /// The network context of a command approval (`networkApprovalContext`).
    private static func networkContext(_ value: Any?) -> NetworkContext {
        guard let value, !(value is NSNull) else { return .none }
        guard let object = value as? [String: Any], let host = object["host"] as? String,
            !host.isEmpty, let networkProtocol = object["protocol"] as? String,
            networkProtocols.contains(networkProtocol)
        else { return .invalid }
        return .line("Network: \(networkProtocol) \(host)")
    }

    /// The command prefix of `proposedExecpolicyAmendment`, when Rafu can show
    /// it whole: one to `maximumAmendmentWords` words, none empty, none with
    /// white space or a character the sanitizer removes, at most
    /// `maximumAmendmentBytes` bytes joined by spaces. Else nil.
    public static func execpolicyAmendment(fromCommandParams params: [String: Any]) -> [String]? {
        guard let words = params["proposedExecpolicyAmendment"] as? [String],
            (1...maximumAmendmentWords).contains(words.count),
            words.joined(separator: " ").utf8.count <= maximumAmendmentBytes
        else { return nil }
        for word in words {
            let clean = Self.clean(word, limit: maximumAmendmentBytes, keepsLineBreaks: false)
            guard !word.isEmpty, !clean.altered,
                !word.unicodeScalars.contains(where: { $0.properties.isWhitespace })
            else { return nil }
        }
        return words
    }

    /// The line that states what remembering `words` does.
    public static func execpolicyAmendmentLine(_ words: [String]) -> String {
        "Always allow commands that start with " + words.joined(separator: " ")
    }

    // MARK: Tool approval

    /// A Codex `mcpServer/elicitation/request` is a tool approval only when
    /// every check below holds; any other shape gives nil (the caller then
    /// shows a notice). The request fields (mode, `requestedSchema`,
    /// `serverName`) and the `_meta` keys are checked against the Codex
    /// 0.171.0 generated schema and source. `params.message` and the display
    /// fields are free text from Codex and are never read.
    private static func toolCallRequest(
        fromElicitation params: [String: Any], key: UUID, receivedAt: Date
    ) -> (request: CanvasAgentRequest, hasUnknownMeta: Bool)? {
        // A form that asks for no data. A property means the user must type
        // something, which Rafu cannot do.
        guard params["mode"] as? String == "form",
            let schema = params["requestedSchema"] as? [String: Any]
        else { return nil }
        if let properties = schema["properties"], !(properties is NSNull) {
            guard let object = properties as? [String: Any], object.isEmpty else { return nil }
        }
        guard let meta = params["_meta"] as? [String: Any],
            meta["codex_approval_kind"] as? String == "mcp_tool_call",
            let server = params["serverName"] as? String, !server.isEmpty,
            !server.contains("__"),
            let tool = meta["tool_name"] as? String, !tool.isEmpty,
            // Rafu must not let the user approve arguments it did not show.
            let arguments = meta["tool_params"] as? [String: Any]
        else { return nil }
        let name = "mcp__\(server)__\(tool)"
        // The built name must split back into the same server and tool.
        guard let parts = AgentPermissionRequestSummary.mcpParts(of: name),
            parts.server == server, parts.tool == tool,
            let summary = AgentPermissionRequestSummary(toolName: name, toolInput: arguments),
            let call = summary.toolCall
        else { return nil }
        let keys = Set(meta.keys)
        let hasUnknownMeta = !keys.subtracting(forcingToolApprovalMetaKeys).isSubset(
            of: knownToolApprovalMetaKeys)
        let forced = !keys.isDisjoint(with: forcingToolApprovalMetaKeys)
        // What Codex offers to remember: `persist` is absent, a string, or an
        // array of strings. Only the two known words count.
        let offered: Set<String> =
            switch meta["persist"] {
            case let word as String: [word]
            case let words as [String]: Set(words)
            default: []
            }
        var remember: [PersistChoice] = []
        if offered.contains("session") {
            remember.append(
                PersistChoice(
                    kind: .session, line: "Allow \(tool) of \(server) for this Codex session"))
        }
        if offered.contains("always") {
            remember.append(
                PersistChoice(kind: .always, line: "Always allow \(tool) of \(server) in Codex"))
        }
        let request = CanvasAgentRequest(
            key: key, kind: .toolCall, command: call.arguments, reason: call.reasonLine,
            persistChoices: remember, stopsTurnOnCancel: false,
            terminalOnly: !summary.isComplete || hasUnknownMeta || forced,
            offersSessionAllow: false, receivedAt: receivedAt)
        return (request, hasUnknownMeta)
    }

    /// The changes of a Codex `item/fileChange/patchUpdated` notification
    /// (`params.changes`), or nil when a change has a shape Rafu does not
    /// know. At most `Limits.fileChanges + 1` changes are kept: one more than
    /// a request holds, so a request with too many files stays terminal-only.
    /// The bodies are the diffs as Codex sent them; the request sanitizes
    /// them.
    public static func fileChanges(fromPatchUpdated params: [String: Any]) -> [FileChange]? {
        guard let raw = params["changes"] as? [Any] else { return nil }
        var changes: [FileChange] = []
        for item in raw.prefix(Limits.fileChanges + 1) {
            guard let object = item as? [String: Any], let path = object["path"] as? String,
                let diff = object["diff"] as? String
            else { return nil }
            let kind: FileChange.Kind
            var movePath: String?
            if let name = object["kind"] as? String {
                switch name {
                case "add": kind = .create
                case "delete": kind = .delete
                case "update": kind = .edit
                default: return nil
                }
            } else if let object = object["kind"] as? [String: Any],
                let name = object["type"] as? String
            {
                switch name {
                case "add": kind = .create
                case "delete": kind = .delete
                case "update":
                    if let target = object["move_path"] as? String, !target.isEmpty {
                        kind = .move
                        movePath = target
                    } else {
                        kind = .edit
                    }
                default: return nil
                }
            } else {
                return nil
            }
            changes.append(
                FileChange(path: path, kind: kind, body: diff, isDiff: true, movePath: movePath))
        }
        return changes
    }

    /// The JSON-RPC `result` object that answers this request with
    /// `decision`, or nil when the decision is not valid for it. A
    /// permissions request needs the profile it asked for (`params.permissions`):
    /// accepting grants exactly that profile; declining grants nothing. A
    /// remembered command prefix needs the words the request offered
    /// (`execpolicyAmendment(fromCommandParams:)`); they must match the line
    /// the row showed.
    public func result(
        for decision: CanvasAgentRequestDecision, requestedPermissions: Any? = nil,
        execpolicyAmendment: [String]? = nil, policy: PersistPolicy = .current
    ) -> [String: Any]? {
        guard permits(decision, policy: policy) else { return nil }
        switch (kind, decision) {
        case (.userInput, .answers(let answers)):
            // The labels, then the typed text as a note. A text with no
            // label goes with the "other" label, as the Codex terminal sends
            // it: `["None of the above", "user_note: <text>"]`.
            return [
                "answers": answers.mapValues { answer -> [String: Any] in
                    var list = answer.labels
                    if let text = answer.text {
                        if list.isEmpty { list.append(Self.codexOtherLabel) }
                        list.append(Self.codexNotePrefix + text)
                    }
                    return ["answers": list]
                }
            ]
        case (.permissions, .decline):
            return ["permissions": [String: Any](), "scope": "turn"]
        case (.permissions, .accept), (.permissions, .acceptForSession):
            guard let requested = requestedPermissions as? [String: Any] else { return nil }
            return [
                "permissions": requested,
                "scope": decision == .acceptForSession ? "session" : "turn",
            ]
        case (.command, .accept), (.command, .acceptForSession), (.command, .decline),
            (.command, .cancel), (.fileChange, .accept), (.fileChange, .acceptForSession),
            (.fileChange, .decline), (.fileChange, .cancel):
            return ["decision": decision.name]
        case (.command, .acceptAndRemember(.rule)):
            // Checked in the Codex 0.171.0 schema
            // (`CommandExecutionApprovalDecision`). The words must be the
            // ones the row showed.
            guard let words = execpolicyAmendment,
                persistChoices.contains(where: {
                    $0.kind == .rule && $0.line == Self.execpolicyAmendmentLine(words)
                })
            else { return nil }
            return [
                "decision": [
                    "acceptWithExecpolicyAmendment": ["execpolicy_amendment": words]
                ]
            ]
        case (.toolCall, .accept):
            // Codex elicitation answers, checked in the Codex 0.171.0 source
            // (`parse_mcp_tool_approval_elicitation_response`). The form has
            // no property, so the accepted content is null.
            return ["action": "accept", "content": NSNull()]
        case (.toolCall, .acceptAndRemember(let kind)):
            // `persist` says how long Codex remembers the grant. Offered
            // only when the request carried it and `PersistPolicy` allows it.
            guard kind == .session || kind == .always else { return nil }
            return [
                "action": "accept", "content": NSNull(), "_meta": ["persist": kind.rawValue],
            ]
        case (.toolCall, .decline):
            return ["action": "decline"]
        case (.toolCall, .cancel):
            // Cancel skips this tool call; it does not stop the turn.
            return [
                "action": "cancel", "content": NSNull(),
                "_meta": ["codex_approval_cancellation_reason": "user"],
            ]
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
